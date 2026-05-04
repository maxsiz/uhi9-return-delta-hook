# Урегулирование delta в Uniswap v4 и в `InternalSwapPool`

Этот документ объясняет, как именно `PoolManager` ведёт «бухгалтерию долгов» внутри одной транзакции, какие функции эту бухгалтерию двигают, и как она применяется в нашем хуке. Цель — чтобы при правке `_beforeSwap` / `_afterSwap` / `_distributeFees` всегда можно было свести таблицу шагов к нулю по каждой валюте на каждом счёте.

---

## Часть I. Теория

### 1. Модель «unlock + transient deltas»

Точка входа в любой PM-сценарий — `PoolManager.unlock(bytes calldata data)`. Внутри:

1. PM выставляет флаг «unlocked» (`Lock.unlock()`), вызывает `IUnlockCallback(msg.sender).unlockCallback(data)`.
2. Внутри callback'а можно как угодно дёргать `swap`, `modifyLiquidity`, `donate`, `take`, `settle`, `mint`, `burn`, `clear`. Все они защищены модификатором `onlyWhenUnlocked`.
3. Каждый такой вызов меняет **транзитную дельту** на счёте `msg.sender` (в данный момент это caller of the PM-функции, не обязательно тот, кто разлочил пул).
4. На выходе из callback'а PM проверяет: `NonzeroDeltaCount == 0`. Если хотя бы один аккаунт оставил ненулевую дельту хоть в одной валюте — `CurrencyNotSettled()`.

**Транзитная дельта** живёт в EIP-1153 (`tstore`/`tload`) и хранится по слоту `keccak(target, currency)`. Знаковая, `int256`. Семантика:

| знак | смысл | как закрыть |
|------|-------|-------------|
| **+X** на (you, C) | PM «должен тебе» X токенов C → доступен `take` | `take(C, …, X)` или встречная операция, дающая −X |
| **−X** на (you, C) | ты «должен» PM X токенов C → надо `settle` | `settle()` после `transferFrom` (или `settle{value:X}` для ETH) |
| **0** | в расчёте | ничего не делаешь |

Внутренняя функция `_accountDelta(currency, delta, target)` (`PoolManager.sol:368`) только инкрементирует/декрементирует счётчик ненулевых счетов и применяет `delta` к существующему. **Все** дельта-движущие вызовы PM проходят через неё.

### 2. Каталог действий, изменяющих дельту

Подписи слегка упрощены, цель — показать, кому и что начисляется. Все ссылки — `lib/v4-hooks-public/lib/v4-core/src/PoolManager.sol`.

| Вызов | Кому накапливается дельта | На какой валюте | Знак изменения | Физическое движение токенов |
|-------|---------------------------|-----------------|----------------|------------------------------|
| `swap(key, params, hookData)` | `msg.sender` PM-вызова | обе (`cur0`, `cur1`) | по математике AMM | нет |
| `modifyLiquidity(key, params, hookData)` | `msg.sender` | обе | по математике добавления/изъятия ликвидности | нет |
| `donate(key, amount0, amount1, hookData)` | `msg.sender` | обе | `−amount0`, `−amount1` (донор всегда в долгу) | нет |
| `take(currency, to, amount)` | `msg.sender` | `currency` | **−amount** | PM → `to`, реальный transfer/ETH-call |
| `settle()` (native) | `msg.sender` | ETH (`address(0)`) | **+msg.value** | ETH уже пришёл вместе с вызовом |
| `settle()` (ERC-20, после `sync`) | `msg.sender` | синканная currency | **+(balanceOf(PM)now − reservesBefore)** | токены должны быть переведены в PM до `settle` |
| `settleFor(recipient)` | `recipient` | как у `settle` | как у `settle` | как у `settle` |
| `sync(currency)` | — (не трогает delta) | — | — | снапшот `balanceOf(PM)` для последующего settle |
| `mint(to, id, amount)` | `msg.sender` | currency по id | `−amount` | минтит ERC-6909 на `to` (claim) |
| `burn(from, id, amount)` | `msg.sender` | currency по id | `+amount` | сжигает ERC-6909 у `from` |
| `clear(currency, amount)` | `msg.sender` | `currency` | `−amount` (только если текущая дельта = `+amount`) | нет, просто «прощает» долг PM перед собой |

Ключевые моменты, которые часто ломают:
- **Все вызовы списывают дельту на `msg.sender`** PM-функции. Если `_distributeFees` вызывается из `_afterSwap`, `msg.sender` для `donate`/`settle` — это сам хук, а не оригинальный свопер.
- **`take` и `settle` симметричны**: `take` физически вынимает токены из PM и записывает «должок» на caller; `settle` принимает токены/ETH и закрывает «должок».
- **`donate` не двигает токены**, только дельту — реально перевести в PM нужно отдельным `settle`.
- **`sync` не двигает дельту**, только записывает snapshot. Без `sync` перед `settle` для ERC-20 будет ошибка либо неправильное начисление.

### 3. Протокол settle для ERC-20

Минимальная корректная последовательность для ERC-20:

```text
poolManager.sync(currency);                    // 1. snapshot reservesBefore = balanceOf(PM)
IERC20(token).transfer(address(poolManager),  // 2. реально переводим токены в PM
                       amount);                //    (или transferFrom, или settleUsingBurn ERC-6909)
poolManager.settle();                          // 3. PM считает balanceOf(PM) − reservesBefore
                                               //    и кредитит msg.sender на эту разницу
```

`CurrencySettler` (`v4-core/test/utils/CurrencySettler.sol`) делает это под капотом, давая `currency.settle(manager, payer, amount, burn)`. С `burn=false`:
- ERC-20: `sync` → `transferFrom(payer, manager, amount)` → `settle()` (если payer = caller, иначе через approve).
- native ETH: просто `manager.settle{value: amount}()` — `sync` не нужен (PM проверит и кредитнёт `msg.value`).

**Важно для нативного ETH**: `_settle` отличает «native settle» по тому, что `getSyncedCurrency() == address(0)`. Если перед `settle{value:…}` кто-то сделал `sync(non-eth-currency)`, попытка с `msg.value > 0` ревёртнет (`NonzeroNativeValue`). На практике для ETH достаточно `settle{value: amount}()`; для ERC-20 обязательно `sync` сразу перед transfer.

### 4. Take для native ETH — требование `receive() external payable`

`PoolManager.take(address(0), to, amount)` делает `to.call{value: amount}("")`. Если `to` — контракт без `receive()` или `payable fallback`, вызов ревёртит. **Любой хук, который собирается забирать ETH через `take(currency0, hook, …)`, обязан иметь `receive() external payable {}`** (в нашем случае это и есть строка `src/InternalSwapPool.sol:73`).

### 5. Как PM обрабатывает дельты, возвращённые из хука

Хук-колбэки с возвратом дельты (`beforeSwapReturnDelta`, `afterSwapReturnDelta`, `afterAddLiquidityReturnDelta`, `afterRemoveLiquidityReturnDelta`) **не делают ничего магического** — PM просто:

1. Упаковывает возвращённый `int128`/`BeforeSwapDelta` в `BalanceDelta` `hookDelta` на правильной оси.
2. Делает `callerDelta = callerDelta - hookDelta` (поток между caller и hook).
3. Делает `_accountPoolBalanceDelta(key, hookDelta, hookAddress)` — то есть `hookDelta` буквально начисляется на счёт хука с тем же знаком.

Семантика, как читать «знак» возврата, в обоих местах одинаковая:

> **Положительная компонента → хук НА СЕБЯ берёт эту валюту** (PM кредитует хук, debits caller). Отрицательная → хук **отдаёт** валюту (PM debits хук, credits caller).

Это значит, что если хук **физически забрал** через `take()` (минусовая дельта на хуке) X токенов — он должен вернуть **+X**, чтобы PM сам положил +X на его счёт обратно и сошёлся в ноль. И наоборот: если хук **отдал** через `settle()` X токенов поверх требуемого, чтобы покрыть кого-то — он возвращает **−X**.

Проверьте в `Hooks.sol:285-314` — это ровно та логика, что мы применяли при расчёте знака в `_afterSwap`.

### 6. `BeforeSwapDelta` (две оси) vs `int128` из afterSwap (одна ось)

| что возвращает | где живёт | оси |
|----------------|-----------|-----|
| `_beforeSwap` | `BeforeSwapDelta beforeSwapDelta_` | (specified, unspecified) — **обе** компоненты |
| `_afterSwap` | `int128 hookDeltaUnspecified_` | только **unspecified** (specified-смещение из beforeSwap пробрасывается дальше внутри `Hooks.afterSwap`) |

Specified — это та валюта, которую юзер зафиксировал в `params.amountSpecified` (вход для exact-in, выход для exact-out). Unspecified — другая. В `Hooks.afterSwap:307-309` ось выбирается так:

```solidity
hookDelta = (params.amountSpecified < 0 == params.zeroForOne)
    ? toBalanceDelta(hookDeltaSpecified, hookDeltaUnspecified)   // specified=cur0
    : toBalanceDelta(hookDeltaUnspecified, hookDeltaSpecified);  // specified=cur1
```

Отсюда же выражение `(amountSpecified < 0) == zeroForOne` в нашем `swapFeeCurrency` — мы выбираем именно **unspecified** для удержания комиссии, потому что только эта ось доступна `afterSwap`.

### 7. Что значит «свести дельту к нулю»

PM не различает «полезные» и «вредные» движения. Алгоритм проверки прост: счётчик `NonzeroDeltaCount` (`PoolManager.sol:373-377`) при каждом `_accountDelta`, который превращает 0 → ненулевое, инкрементируется; обратное — декрементируется. На выходе из `unlock` он должен быть 0. Поэтому:

- Складывать «свои» долги и долги юзеру в одну строку нельзя — каждая пара (account, currency) считается отдельно.
- Дельта хука и дельта свопера **разные счета** в `_accountDelta`. Хук обязан закрыть **свою**, swapper — **свою**.
- Закрытие через возврат из колбэка (опция 5 выше) — это просто синтаксический сахар над «PM сам сделает `_accountDelta(currency, +X, hook)`».

---

## Часть II. Применение в `InternalSwapPool`

В этом хуке три блока, где двигаются дельты: `_beforeSwap` (внутренний внеcwap-fees свап), `_afterSwap` (комиссия + триггер раздачи), `_distributeFees` (donate + settle). Разберём каждый шаг с детальной таблицей бухгалтерии.

Обозначения в таблицах:
- `S` — `swapper` (тот, кто разлочил пул, обычно `PoolSwapTest`).
- `H` — наш хук (`address(this)` внутри хук-функций).
- `cur0`, `cur1` — соответственно `key.currency0` (ETH в нашем случае) и `key.currency1` (token1).

### А. `_afterSwap` для exact-in zeroForOne (`test_1`)

Сценарий: юзер платит 1e16 ETH, получает ~9.999e15 token1. Unspecified = `cur1`. После моих фиксов:

| # | Действие | S.cur0 | S.cur1 | H.cur0 | H.cur1 | Комментарий |
|---|----------|-------:|-------:|-------:|-------:|-------------|
| 0 | вход в `unlock` | 0 | 0 | 0 | 0 | стартовое состояние |
| 1 | `_swap`: `−1e16 / +9.999e15` | −1e16 | +9.999e15 | 0 | 0 | дельты только у swapper'а |
| 2 | `take(cur1, H, 9.999e13)` (1% fee) | −1e16 | +9.999e15 | 0 | **−9.999e13** | хук физически получает token1, в долгу перед PM |
| 3 | `_distributeFees`: `amount1 = 9.999e13 < threshold` | — | — | — | — | возврат, donate не вызывается |
| 4 | возврат `hookDeltaUnspecified_ = +9.999e13` | — | — | — | — | PM применит на шаге 5 |
| 5а | PM: `swapDelta -= hookDelta` на ось cur1 | −1e16 | +9.999e15 − 9.999e13 = **+9.9e15** | 0 | −9.999e13 | юзер получит на 1% меньше |
| 5б | PM: `_accountPoolBalanceDelta(key, hookDelta, H)` | — | — | 0 | −9.999e13 + 9.999e13 = **0** | хук бухгалтерски в нуле |
| 6 | swapper: `settle{value:1e16}()` + `take(cur1, …, 9.9e15)` | 0 | 0 | 0 | 0 | swapper закрылся |
| 7 | конец `unlock`: счётчик = 0 ✓ | | | | | |

Корзина хука: `_poolFees[poolId].amount1 += 9.999e13` (физически token1 лежат на `address(this)` хука).

### Б. `_afterSwap` + `_distributeFees` для exact-out zeroForOne (`test_zeroForOne_exactOut`)

Сценарий: юзер хочет точно 1e16 token1, платит немного больше 1e16 ETH (~1.0001e16). Unspecified = `cur0` (вход), specified = `cur1` (выход). Сейчас комиссия в `cur0`, и она **превышает** `DONATE_THRESHOLD_MIN` → срабатывает `donate`.

| # | Действие | S.cur0 | S.cur1 | H.cur0 | H.cur1 |
|---|----------|-------:|-------:|-------:|-------:|
| 0 | вход в `unlock` | 0 | 0 | 0 | 0 |
| 1 | `_swap`: `−1.0001e16 / +1e16` | **−1.0001e16** | **+1e16** | 0 | 0 |
| 2 | `take(cur0, H, 1.0001e14)` (1% от input) | −1.0001e16 | +1e16 | **−1.0001e14** | 0 |
| 3 | `_distributeFees`: `donate(key, 1.0001e14, 0)` | −1.0001e16 | +1e16 | **−2.0002e14** | 0 |
| 4 | `cur0.settle{value:1.0001e14}()` (хук шлёт ETH из своего баланса) | −1.0001e16 | +1e16 | −2.0002e14 + 1.0001e14 = **−1.0001e14** | 0 |
| 5 | возврат `hookDeltaUnspecified_ = +1.0001e14` | — | — | — | — |
| 6а | PM: `swapDelta -= hookDelta` на ось cur0 | −1.0001e16 − 1.0001e14 = **−1.0102e16** | +1e16 | −1.0001e14 | 0 |
| 6б | PM: `_accountPoolBalanceDelta(hookDelta, H)` | — | — | −1.0001e14 + 1.0001e14 = **0** | 0 |
| 7 | swapper: `settle{value:1.0102e16}()` + `take(cur1, …, 1e16)` | 0 | 0 | 0 | 0 |
| 8 | счётчик = 0 ✓ | | | | |

Что важно про шаг 4: `settle` для нативного ETH тратит `address(this).balance` хука. Шаг 2 (`take(cur0)`) перед этим положил 1.0001e14 ETH на хук через `address.call{value:…}` → шаг 4 шлёт обратно эти же ETH в виде `msg.value`. Чистое движение реального ETH у хука = 0. Поэтому хук-баланс ETH не «утекает» в LP при `donate(amount0)` — наоборот, потоки замыкаются.

Если бы шаг 2 (`take`) был на token1, а donate на cur0 (то есть рассогласование валют — то, что было в баге, который мы починили), хук бы остался без ETH-источника на шаг 4 и развалился бы либо здесь, либо при «лишнем долге» к концу `unlock`.

### В. `_afterSwap` + `_distributeFees` для exact-out !zeroForOne (`test_oneForZero_exactOut`)

Зеркало случая Б, но валюты поменяны: юзер хочет 1e16 ETH, платит ~1.0001e16 token1. Unspecified = `cur1` (вход). Комиссия копится и сразу донэйтится на `cur1`.

| # | Действие | S.cur0 | S.cur1 | H.cur0 | H.cur1 |
|---|----------|-------:|-------:|-------:|-------:|
| 1 | `_swap`: `+1e16 / −1.0001e16` | **+1e16** | **−1.0001e16** | 0 | 0 |
| 2 | `take(cur1, H, 1.0001e14)` | +1e16 | −1.0001e16 | 0 | **−1.0001e14** |
| 3 | `donate(key, 0, 1.0001e14)` | +1e16 | −1.0001e16 | 0 | **−2.0002e14** |
| 4 | `cur1.settle(PM, H, 1.0001e14, false)` (sync + transfer + settle) | +1e16 | −1.0001e16 | 0 | −2.0002e14 + 1.0001e14 = **−1.0001e14** |
| 5 | возврат `hookDeltaUnspecified_ = +1.0001e14` | | | | |
| 6а | `swapDelta -= hookDelta` на cur1 | +1e16 | −1.0001e16 − 1.0001e14 = **−1.0102e16** | 0 | −1.0001e14 |
| 6б | hook account += hookDelta | | | 0 | **0** |
| 7 | swapper: `take(cur0, …, 1e16)` + `sync(cur1)` + transferFrom 1.0102e16 token1 + `settle()` | 0 | 0 | 0 | 0 |

В шаге 4 для ERC-20 protocol требует `sync` → `transfer` → `settle`. У хука для этого должно быть **физическое** количество token1 на `address(this)` ≥ 1.0001e14. Шаг 2 (`take`) ровно это и обеспечил. Если кто-то снимет/удалит `take` (или поставит сначала `donate`, потом `take`), settle развалится с недостатком token1.

### Г. Внутренний свап в `_beforeSwap` (сейчас не покрыт тестами)

Логика в `src/InternalSwapPool.sol:149-237` срабатывает только при `params.zeroForOne && _poolFees[poolId].amount1 != 0` — то есть когда у хука уже есть накопленная комиссия в token1 и кто-то заходит со свопом ETH→token1. Идея: «продать накопленный token1 swapper'у напрямую перед AMM», получив за него ETH.

Ключевые шаги для exact-output ветки (`amountSpecified >= 0`, схематично):

| # | Действие | S.cur0 | S.cur1 | H.cur0 | H.cur1 |
|---|----------|-------:|-------:|-------:|-------:|
| 0 | старт: пусть `_poolFees.amount1 = F1` физически у хука | 0 | 0 | 0 | 0 |
| 1 | `take(cur0, H, ethOut)` — забираем ETH у PM в счёт продажи | 0 | 0 | **−ethOut** | 0 |
| 2 | `cur1.settle(PM, H, tokenIn, false)` — отдаём в PM token1 | 0 | 0 | −ethOut | **+tokenIn** (settle → +) |
| 3 | возврат `BeforeSwapDelta(-tokenIn, ethOut)` (specified=cur1, unspec=cur0) | | | | |
| 4а | PM: `amountToSwap += hookDeltaSpecified = -tokenIn` | (S.cur1 будет уменьшен на abs(tokenIn) после AMM-свапа) | | | |
| 4б | PM: для unspecified — упаковка в `BalanceDelta(specified, unspecified)` и `swapDelta -= hookDelta`, hook-account += hookDelta | | | **−ethOut + ethOut = 0** | **+tokenIn − tokenIn = 0** |

Тут важная тонкость — `_beforeSwap` использует **`BeforeSwapDelta`** и обе оси, в отличие от `_afterSwap`. Знаки выбраны симметрично:
- `−int128(tokenIn)` на specified-оси (cur1 для exact-out): PM «вычтет» этот долг из суммы свапа, юзеру нужно будет получить меньше через AMM (хук уже отдал ему `tokenIn` со своих запасов).
- `+int128(ethOut)` на unspecified-оси (cur0): обратный знак — хук берёт ETH у юзера в обмен.

После применения в PM хук должен оказаться в нуле по обеим валютам.

### Карта вызовов в текущей кодовой базе

| место | вызов | эффект на дельту хука | физическое движение |
|-------|-------|----------------------|---------------------|
| `_beforeSwap:235` | `poolManager.take(cur0, H, ethOut)` | `H.cur0 −= ethOut` | ETH из PM → хук |
| `_beforeSwap:236` | `cur1.settle(PM, H, tokenIn, false)` | `H.cur1 += tokenIn` | sync(cur1) + transferFrom(H, PM, tokenIn) + settle() |
| `_beforeSwap:end` | `return BeforeSwapDelta(-tokenIn, ethOut)` | PM: hook account += `(specified, unspec)` пакет → итог 0 | — |
| `_afterSwap:283` | `swapFeeCurrency.take(PM, H, swapFee, false)` | `H.<unspec> −= swapFee` | take of unspec currency |
| `_afterSwap:end` | `return hookDeltaUnspecified_ = +swapFee` | PM: `H.<unspec> += swapFee` → 0 | — |
| `_distributeFees` | `poolManager.donate(key, a0, a1, "")` | `H.cur0 −= a0`, `H.cur1 −= a1` | — |
| `_distributeFees` | `cur0.settle(PM, H, |delta.amount0|, false)` | `H.cur0 += amount` | settle{value: amount}() (ETH из баланса хука) |
| `_distributeFees` | `cur1.settle(PM, H, |delta.amount1|, false)` | `H.cur1 += amount` | sync + transfer + settle |

### Как читать ошибку `CurrencyNotSettled()` в трассе

`forge test -vvvv` показывает суммарные дельты в виде BalanceDelta-чисел в логах PM-вызовов. Алгоритм диагностики:

1. Найти финальную BalanceDelta, возвращённую из `unlockCallback`.
2. Распаковать на пары (cur0, cur1) и сравнить с тем, что физически получил/заплатил swapper. Если расходится — расхождение = чья-то непогашенная дельта.
3. Дальше идти по трассе сверху вниз, проверяя каждый `take` (двигает на −), `settle` (+), `donate` (на обе оси: −), `sync` (ничего не меняет), `swap` (по математике).
4. Особое внимание — на ось, на которой висит остаток: ошибка обычно в той функции, где последним был ненулевой shift.

Например, в нашем недавнем баге (`hookDeltaUnspecified_ = -swapFee` вместо `+swapFee`) трасса показывала `take(cur1, …, 1.989e16)` для swapper'а вместо ожидаемых `9.999e15`. Превышение ровно равно двум фи-fee — типичный сигнал «знак возврата хук-дельты перевернут».

---

## Шпаргалка: 4 правила, чтобы не получать `CurrencyNotSettled`

1. **Каждый `take` и каждое уменьшение через `donate` — это долг.** Закрывайте либо реальным `settle`, либо положительной hook-return-дельтой на той же валюте.
2. **`sync` обязателен перед `settle` для ERC-20.** Для нативного ETH `sync` не нужен и недопустим.
3. **`take(currency0=address(0), …)` шлёт ETH в caller — нужен `receive() external payable`.**
4. **Возврат хука кредитует хука и одновременно дебетует свопера** на ту же сумму. Если физически вы взяли (`take`), верните **+**; если отдали лишнее (`settle` за свопера), верните **−**.

Если таблица шагов сходится по каждой паре `(account, currency)` к 0 — `unlock` пройдёт. Если нет — точка несхождения и есть ваш баг.
