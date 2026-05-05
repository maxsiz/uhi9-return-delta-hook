# План — Self-LP auto-compound hook (workshop demo для custom accounting)

## Context

Учебный V4-хук для этого репо. Хук **сам владеет** концентрированной LP-позицией в пуле, к которому подключён. На каждом `afterSwap` он смотрит на накопленный yield своей позиции; когда тот переваливает порог, клеймит фи и реинвестирует в новый диапазон, центрированный вокруг текущей цены (concentrated, follows-price). Position принадлежит хуку напрямую через `(hookAddress, tickLower, tickUpper, salt)` — никакого PositionManager / NFT.

Главная цель — **показать разные приёмы custom accounting в V4 на одной механике (auto-compound)**. Поэтому делаем **три варианта хука** в виде отдельных контрактов, каждый изолирует один приём, остальное — общее.

В этом же репо уже лежит `src/InternalSwapPool.sol` — workshop-хук с закомментированной `beforeSwapReturnDelta`/`afterSwapReturnDelta`-логикой; новые контракты живут параллельно, не трогая его.

---

## Финальные решения по scope

| Параметр                       | Решение                                                                   |
| ------------------------------ | ------------------------------------------------------------------------- |
| Демо-формат                    | Несколько вариантов хука (по одному приёму на контракт)                   |
| Funding первой позиции         | External `seedPosition()` от owner                                        |
| Yield-порог                    | Абсолютный по ETH (immutable, аналог `DONATE_THRESHOLD_MIN = 0.0001 ETH`) |
| Стратегия range                | Фиксированный `halfWidthTicks`, снэп на `tickSpacing`                     |

---

## Архитектура — три варианта

| Вариант                          | Hook permissions                                                                | Демонстрируемый приём custom accounting                                                                  |
| -------------------------------- | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `SelfLPDirect` (**baseline**)    | `BEFORE_INITIALIZE \| AFTER_SWAP`                                               | Direct `poolManager.modifyLiquidity` от имени хука, **view-side threshold** через `StateLibrary.getFeeGrowthInside`+`getPositionInfo`, `sync`/`take`/`CurrencySettler.settle`, poke с `liquidityDelta=0` для клейма фи |
| `SelfLPAfterDelta`               | `BEFORE_INITIALIZE \| AFTER_SWAP \| AFTER_SWAP_RETURNS_DELTA`                    | Всё от baseline + **`afterSwapReturnDelta`**: skim фиксированных bps от unspecified-side output → buffer; при реинвесте buffer добавляется в позицию. Демо: возврат `int128 hookDeltaUnspecified > 0`, `poolManager.take` на хук |
| `SelfLPBeforeInternalize`        | `BEFORE_INITIALIZE \| BEFORE_SWAP \| BEFORE_SWAP_RETURNS_DELTA \| AFTER_SWAP`   | Всё от baseline + **`beforeSwapReturnDelta`**: idle-инвентарь хука (не-LP'd токены между реинвестами) частично гасит свопы по текущей цене через `SwapMath.computeSwapStep`, остальное идёт в AMM. Паттерн — близкий к закомментированному в `src/InternalSwapPool._beforeSwap` |

Опциональный **четвёртый вариант** `SelfLPDonate` (`poolManager.donate` для возврата фи всем LP пула, в т.ч. себе) — оставляем как future, не пишем сейчас.

---

## Общее ядро — `src/lib/SelfLPLib.sol`

Stateless helpers (внутренняя library), переиспользуется всеми тремя вариантами:

- `computeRange(currentTick, halfWidthTicks, tickSpacing) → (tickLower, tickUpper)` — снэпает границы на сетку.
- `previewFeesETH(IPoolManager, PoolId, address owner, tickLower, tickUpper, salt, sqrtPriceX96) → uint256` — view-only оценка accrued fees, конвертированных в ETH-эквивалент через текущую цену пула. Использует `StateLibrary.getFeeGrowthInside` + `StateLibrary.getPositionInfo`.
- `computeReinvestSwap(currentSqrtPriceX96, newTickLower, newTickUpper, balance0, balance1) → (zeroForOne, amountSpecified)` — какой части баланса нужен ratio-swap, чтобы вписаться в новый range.

Конвенция salt — `bytes32(0)` (одна позиция на хук).

---

## Каждый вариант — точки входа

### Общее у всех трёх

**`_beforeInitialize(sender, key, sqrtPriceX96)`** — копия паттерна `src/InternalSwapPool.sol:108-125`:
- `key.fee == 0x800000` иначе `MustUseDynamicFee()`.
- Один из currencies = ETH (`address(0)`) иначе `PoolShouldBeWithEth()`.
- Дополнительно: запоминаем `poolKey`, `poolId`, `tickSpacing` в storage.

**`seedPosition(uint256 amount0, uint256 amount1)`** external `payable`, `onlyOwner`:
- Проверка `position.liquidity == 0` (один раз).
- Read current tick → `computeRange` → новый `(tickLower, tickUpper)`.
- `LiquidityAmounts.getLiquidityForAmounts(...)` → liquidity.
- `poolManager.unlock(...)` → callback делает `modifyLiquidity(+liquidity, salt=0)` → settle через `sync`/`settle`.

**`_afterSwap` happy-path (под порогом)**:
1. Вызвать `SelfLPLib.previewFeesETH(...)` — pure view, не мутирует state.
2. Если меньше порога — вернуть `(this.afterSwap.selector, 0)`. Дешёвая ветка.

**`_afterSwap` reinvest-path (превышен порог)**:
1. Poke: `poolManager.modifyLiquidity(liquidityDelta=0, salt=0)` → `(callerDelta, feesAccrued)`. Берём через `poolManager.take(...)`.
2. Burn: `modifyLiquidity(-liquidity, salt=0)` → весь principal на хук, settle deltas.
3. Compute new range вокруг текущего tick.
4. Если ratio балансов не подходит — `poolManager.swap(poolKey, ...)` напрямую, settle `sync`/`take`/`CurrencySettler.settle` (паттерн из `src/InternalSwapPool.sol:235-241`).
5. Mint: `modifyLiquidity(+newLiquidity, salt=0, range=newRange)`, settle.
6. Emit `PositionRebalanced(oldLower, oldUpper, newLower, newUpper, newLiquidity)`.
7. Вернуть `(this.afterSwap.selector, hookDeltaUnspecified)`. У baseline `hookDeltaUnspecified = 0`.

Всё — **внутри открытого `unlock`** свопера. Re-entrant `unlock` не нужен. Дельты хука занулятся к выходу из `_afterSwap`.

### Дополнения по вариантам

**`SelfLPAfterDelta`** — поверх baseline:
- Storage: `skimBuffer0`, `skimBuffer1`.
- В `_afterSwap` ДО threshold-check: `skimAmount = abs(unspecifiedDelta) * SKIM_BPS / 10_000`, прибавляем к buffer.
- Возвращаем `hookDeltaUnspecified = int128(skimAmount)` (positive = хук берёт).
- В reinvest-path: добавляем `skimBuffer*` к балансам хука перед `computeReinvestSwap`. Buffer обнуляем.

**`SelfLPBeforeInternalize`** — поверх baseline:
- В `_beforeSwap`: если у хука есть idle-инвентарь нужной стороны, считаем partial fill через `SwapMath.computeSwapStep` от `sqrtPriceX96` до `sqrtPriceLimitX96`. Возвращаем `BeforeSwapDelta`.
- Паттерн и sign-конвенция: те же, что в закомментированном `src/InternalSwapPool._beforeSwap`.
- `_afterSwap` остаётся идентичен baseline.

---

## Файлы

**Новые:**
- `src/SelfLPDirect.sol`
- `src/SelfLPAfterDelta.sol`
- `src/SelfLPBeforeInternalize.sol`
- `src/lib/SelfLPLib.sol`
- `test/SelfLPDirect.t.sol`
- `test/SelfLPAfterDelta.t.sol`
- `test/SelfLPBeforeInternalize.t.sol`

**Без изменений (читаем как референс):**
- `src/InternalSwapPool.sol:108-125` — `_beforeInitialize` template.
- `src/InternalSwapPool.sol:144-244` — закомментированная `_beforeSwap` логика.
- `src/InternalSwapPool.sol:235-241` — `sync`/`take`/`settle` pattern.
- `test/InternalSwapPool.t.sol:48-110` — `Deployers` setup + `deployCodeTo`.
- `test/hlpEnvelopTest.sol` — `_formatEther`/`_padLeft`.
- `remappings.txt:1-40` — все пути уже подключены.

---

## Implementation order

1. ✅ **`src/lib/SelfLPLib.sol`** — COMPLETED. Pure helpers: `computeRange`, `previewFeesETH`, `computeReinvestSwap`.
2. ✅ **`src/SelfLPDirect.sol`** + `test/SelfLPDirect.t.sol` — COMPLETED. Baseline: `seedPosition`, `_beforeInitialize` (dynamic fee + ETH guard), `_afterInitialize` (updateDynamicLPFee), `_afterSwap` (view-side threshold + flash-accounting reinvest). All 8 tests passing; `forge build --sizes` succeeds.
3. **`src/SelfLPAfterDelta.sol`** + тесты — skim buffer + return-delta.
4. **`src/SelfLPBeforeInternalize.sol`** + тесты — internalize + before-delta.

---

## Tests — общая структура

```solidity
function setUp() public {
    deployFreshManagerAndRouters();
    deployMintAndApprove2Currencies();

    address hookAddr = address(uint160(/* permission bitfield для варианта */));
    deployCodeTo("SelfLPVariant.sol:SelfLPVariant", abi.encode(manager, /* config */), hookAddr);
    hook = SelfLPVariant(payable(hookAddr));

    (key,) = initPool(ethCurrency, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
    hook.seedPosition{value: 1 ether}(1 ether, 5000e6);
}
```

Кейсы (все варианты):
- `test_seedPosition_idempotent` — второй вызов revert.
- `test_swap_belowThreshold_noReinvest` — нет события `PositionRebalanced`.
- `test_swap_aboveThreshold_reinvests` — событие есть; tickLower/Upper изменились; native balance PoolManager = 0.
- `test_followsPrice` — несколько свопов в одну сторону → каждый реинвест центрирует range на новом tick.
- `test_native_dustHandling` — после реинвеста на хуке только rounding-dust.

Variant-specific:
- `SelfLPAfterDelta`: `test_skim_accumulates`, `test_skim_consumedAtReinvest`, `test_returnDelta_sign`.
- `SelfLPBeforeInternalize`: `test_internalize_partialFill`, `test_internalize_emptyInventory_fallthrough`, `test_beforeDelta_sign`.

---

## Verification

1. `forge build` (CI: `FOUNDRY_PROFILE=ci forge build --sizes`).
2. `forge test -vvv`.
3. Гас-снэпшот: no-op-путь (`afterSwap` под порогом) vs reinvest-путь для каждого варианта.
4. Sanity-trace: `forge test --match-test test_swap_aboveThreshold_reinvests -vvvv` — в трейсе: `modifyLiquidity(0)` → `modifyLiquidity(-)` → опциональный `swap(...)` → `modifyLiquidity(+)` → deltas = 0.

---

## Критические файлы

- `lib/v4-hooks-public/lib/v4-core/src/interfaces/IPoolManager.sol:133-135` — сигнатура `modifyLiquidity`.
- `lib/v4-hooks-public/lib/v4-core/src/PoolManager.sol:145-184` — `callerDelta = principalDelta + feesAccrued`.
- `lib/v4-hooks-public/lib/v4-core/src/libraries/StateLibrary.sol:230-242` — `getPositionInfo`.
- `lib/v4-hooks-public/lib/v4-core/src/libraries/StateLibrary.sol:298-322` — `getFeeGrowthInside`.
- `lib/v4-hooks-public/lib/v4-core/src/libraries/Hooks.sol:29-45` — flag constants.
- `@uniswap/v4-core/test/utils/CurrencySettler.sol:19` — `settle(currency, manager, payer, amount, burn)`.
- `lib/v4-hooks-public/src/base/BaseHook.sol` — родитель.
- `src/InternalSwapPool.sol:108-125, 235-241` — паттерны для копирования.
- `test/InternalSwapPool.t.sol:48-110` — тестовый setup.
