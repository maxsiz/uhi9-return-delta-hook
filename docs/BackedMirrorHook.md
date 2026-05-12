# BackedMirrorHook — V4 Limit Order via Mirror Pool

> **Status:** Architecture draft. Not implemented.
> **Next:** Resolve open design questions, then create `src/BackedMirrorHook.sol` skeleton.

## Idea

Build a V4 pool whose hook intercepts standard `Add Liquidity` calls and creates the actual position in an **existing fat pool** (e.g. canonical WETH/USDC 0.3% on Base/Mainnet). The user-facing flow goes through `app.uniswap.org` — zero custom frontend needed — but semantically it's a **limit order**, not a yield-bearing LP.

The user thinks they're providing liquidity. The hook silently redirects to the fat pool with `salt = tokenId`. When the user later clicks "Remove Liquidity", the hook unwinds the backing position and settles whatever it became (USDC if filled, ETH if not, mix if partial).

## Why this design wins

- **Zero frontend cost** — piggybacks on Uniswap's UI / wallet / indexer ecosystem.
- **Real liquidity venue** — orders live in the fat pool with real volume. No bootstrap problem.
- **Trustless** — hook has no custody; all settlement atomic via V4 PoolManager unlock.
- **Composable** — limit orders are standard ERC-721 NFTs from `PositionManager`. Transferable, stakeable, indexable.
- **Distribution solved** — users discover via existing Uniswap pool search; no marketing of a new domain.

## Architecture Overview

```
User opens app.uniswap.org → finds OurPool (ETH/USDC, custom hook)
  ↓ "Add Liquidity" with range above current price + single-sided ETH
PositionManager.modifyLiquidities(MINT, ourPoolKey, range, amount)
  ↓
PoolManager.modifyLiquidity(ourPool, ...)
  ↓
OurHook._beforeAddLiquidity():
  1. Read user's intent (range, amount)
  2. Open backing position in fat pool:
     poolManager.modifyLiquidity(fatPoolKey, sameRange, +L, salt=ourTokenId)
  3. Record mapping: ourTokenId → fatPoolSalt
  ↓
OurHook._afterAddLiquidityReturnDelta():
  - Return delta cancelling our-pool accounting
  - Net: user paid once, real position lives in fat pool
  ↓
User receives LP NFT for OurPool — acts as claim ticket
Real concentrated position lives in fat pool, owner = hook
```

**Mirror semantics on Remove:**

- User clicks "Remove Liquidity" in Uniswap UI → `BURN_POSITION` on OurPool NFT.
- Hook in `_beforeRemoveLiquidity` burns the backing fat-pool position via `salt`.
- Settles proceeds to user: USDC if filled, ETH if not filled, mix if partial.

## Critical Files to Create

| File | Purpose |
|------|---------|
| `src/BackedMirrorHook.sol` | Main hook; intercepts add/remove, manages backing positions in fat pool |
| `src/lib/MirrorAccounting.sol` | Library for delta math between our pool and fat pool |
| `src/LimitOrderExecutor.sol` | Permissionless `executeOrder(tokenId)` for keeper market (un-fill protection) |
| `script/DeployMirror.s.sol` | Deploy mirror pool, initialize with fat pool's current `sqrtPriceX96` |
| `test/BackedMirrorHook.t.sol` | Forge tests: place, fill, cancel, partial fill, keeper exec |

## Required Hook Permissions

```solidity
Hooks.Permissions({
    beforeInitialize: true,                       // enforce mirror semantics (paired fat pool)
    afterInitialize: true,                        // sync initial price from fat pool
    beforeAddLiquidity: true,                     // create backing position
    afterAddLiquidity: true,
    afterAddLiquidityReturnDelta: true,           // cancel our-pool accounting
    beforeRemoveLiquidity: true,                  // burn backing position
    afterRemoveLiquidity: true,
    afterRemoveLiquidityReturnDelta: true,        // mirror remove accounting
    beforeSwap: true,                             // reject swaps OR route to fat pool
    ...
});
```

## Reused Patterns (from existing codebase)

- **`CurrencySettler`** (`lib/v4-hooks-public/lib/v4-core/test/utils/CurrencySettler.sol`) — settle/take patterns already used in `SelfLPDirect._settleDelta`.
- **`SelfLPLib.computeRange`** (`src/lib/SelfLPLib.sol`) — tick-spacing-aware range snapping.
- **`StateLibrary`** — reading fat pool's `slot0`, position state — already used in `SelfLPLib.previewFeesETH`.
- **`BaseHook`** (`lib/v4-hooks-public/src/base/BaseHook.sol`) — same base as `SelfLPDirect`.
- **`IUnlockCallback`** — pattern from `SelfLPDirect.unlockCallback` if placing backing position from outside an open unlock.

## Open Design Decisions (resolve before coding)

1. **Pool initialization price** — deploy OurPool at fat pool's current `sqrtPriceX96`. Re-sync periodically? Probably no — restrict swaps to keep price frozen.
2. **Swap policy on OurPool** — `_beforeSwap` reverts (clean) vs route-through-fat-pool (adds complexity). **Recommendation: revert for v1.**
3. **Backing position ownership** — `salt = bytes32(ourTokenId)`, owner = hook contract address. All limit orders flow through PM-storage slots `keccak(hook, lower, upper, salt)`.
4. **Fee accounting from fat pool**:
   - Option A: hook periodically collects + distributes via subscriber pattern.
   - Option B: collect on remove only.
   **Recommendation: Option B for v1.**
5. **Un-fill protection** — still need keeper market. `LimitOrderExecutor.executeOrder(tokenId)` callable by anyone, takes 0.5% keeper fee. Reused pattern from earlier design discussion.
6. **Fee tier of OurPool** — must equal fee tier of paired fat pool so backing position semantics match. Probably 0.3% for ETH/USDC mainnet.

## Key Technical Challenges (to investigate)

### Challenge 1: `afterAddLiquidityReturnDelta` accounting math

Hook must in `_afterAddLiquidity` return a delta that cancels the user→ourPool transfer and routes funds to fatPool instead. The signs and amounts must net to zero in our pool while charging the user exactly once. This is the central accounting puzzle of the design.

### Challenge 2: Uniswap UI shows OurPool state

UI reads OurPool's current price for slippage hints. If OurPool is empty and frozen, the price needs to be:
- Initialized at fat-pool's current `sqrtPriceX96` at deploy time
- Kept frozen by reverting all swaps in `_beforeSwap`

This means OurPool's displayed price will drift from fat pool over time. Need to accept this as v1 limitation or add a periodic re-init mechanism.

### Challenge 3: Single-sided deposit UX

Standard Uniswap UI defaults to two-sided deposit. For limit orders we need single-sided. This works naturally if the user picks a range above (sell ETH) or below (buy ETH) the current price — one side becomes zero automatically. But user education needed: a simple landing page explaining "select range above market, deposit ETH only = sell limit order".

### Challenge 4: Risk of Uniswap UI blacklisting

Uniswap Labs moderates the pool list in app.uniswap.org. A pool with `afterAddLiquidityReturnDelta` permission might trigger warnings or filtering. Mitigation:
- Open-source audit
- Documentation
- Engage with Uniswap Labs / Foundation early

### Challenge 5: Un-fill problem persists

Even with mirror flow, the un-fill problem remains: if user is offline when filled and price reverses, backing position reverts to ETH. Solution remains the same: permissionless `LimitOrderExecutor.executeOrder(tokenId)` with keeper market.

## Verification Plan

### Phase 1: Local Forge tests

```bash
forge test --match-path ./test/BackedMirrorHook.t.sol -vv
```

Required test cases:
- `test_placeOrder_createsBackingPosition` — user adds liquidity to OurPool, verify fat-pool position exists with matching range
- `test_swap_inFatPool_fillsBackingPosition` — simulate swap on fat pool, verify backing position becomes single-sided
- `test_remove_filledOrder_paysCorrectToken` — Remove after fill returns USDC (not ETH)
- `test_remove_unfilledOrder_returnsOriginal` — Remove before fill returns ETH
- `test_executeOrder_keeperFlow` — third party calls executor, gets keeper fee, user gets remainder
- `test_swap_inOurPool_reverts` — ensure no swap path through our pool (v1 policy)
- `test_partialFill_proportionalReturn` — swap halfway through range, verify mix on remove

### Phase 2: Testnet deployment

- Deploy on Base Sepolia or Sepolia with testnet WETH/USDC pool as backing
- Verify standard Uniswap UI (testnet.app.uniswap.org) discovers and renders OurPool
- Manual end-to-end: place order via UI → trigger fill via testnet swap → remove via UI

### Phase 3: Mainnet/L2 deployment

- External audit (Trail of Bits, OpenZeppelin, or similar)
- Deploy to Base or Unichain (lower gas for keeper economics)
- Engage Uniswap Labs to whitelist pool in app.uniswap.org

## Out of Scope (v1)

- Partial-fill granular accounting (handle at burn time only)
- Subscribe-pattern integration (additional safety, but not core; add in v2)
- Cross-chain limit orders
- Order transferability via NFT marketplaces (works for free as ERC-721; no marketing focus)
- Stop-loss / take-profit semantics (different range strategy, postpone)

## Related Design Background

Earlier in the design exploration we considered:
1. **Direct PosM mint (DIY)** — works but no auto-execution, requires custom UI
2. **Manager + Executor pattern** — adds keeper market but still needs custom UI
3. **Native pool with LO hook (Variant C)** — beautiful but suffers from same bootstrap problem as any new pool
4. **Backed-position mirror pool (this doc)** — combines best of all: trustless, standard UI, real liquidity venue

The decisive insight: don't try to *replace* Uniswap's fat pool — *redirect* user intent from a thin shadow pool to the fat pool while keeping the standard "Add Liquidity" UX.

## Uniswap Deep-Link Integration

Uniswap supports URL parameters that pre-fill the "Create Position" flow, **including the `hook` parameter**. This means we can drive users straight to our pool's add-liquidity page without any wallet integration on our side.

### URL Structure

Base URL: `https://app.uniswap.org/positions/create`

| Parameter | Value |
|-----------|-------|
| `chain` | `base`, `ethereum`, `arbitrum`, `unichain`, etc. |
| `currencyA` | Token address or `NATIVE` for ETH |
| `currencyB` | Token address |
| `fee` | JSON: `{"feeAmount":3000,"tickSpacing":60,"isDynamic":false}` |
| `hook` | **Our hook address** ← key for this design |
| `priceRangeState` | JSON: `{"priceInverted":false,"fullRange":false,"minPrice":"3500","maxPrice":"3521","initialPrice":"","inputMode":"price"}` |
| `depositState` | JSON: `{"exactField":"TOKEN0","exactAmounts":{"TOKEN0":"1.0"}}` |
| `step` | `1` |

URL-encoding: only `"` → `%22`. Do **not** encode `{}` or `:` or `,`.

### Example URL (sell 1 ETH at $3500 on Base)

```
https://app.uniswap.org/positions/create?chain=base&currencyA=NATIVE
&currencyB=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
&fee={%22feeAmount%22:3000,%22tickSpacing%22:60,%22isDynamic%22:false}
&hook=0xOUR_HOOK_ADDRESS
&priceRangeState={%22priceInverted%22:false,%22fullRange%22:false,%22minPrice%22:%223500%22,%22maxPrice%22:%223521%22,%22initialPrice%22:%22%22,%22inputMode%22:%22price%22}
&depositState={%22exactField%22:%22TOKEN0%22,%22exactAmounts%22:{%22TOKEN0%22:%221.0%22}}
&step=1
```

### Product architecture simplifies

```
landing.our-domain.com (static HTML+JS on Vercel, free tier)
  → user inputs target price + amount
  → JS computes tickLower/tickUpper, builds deep-link URL
  → click "Place Order"
  ↓
app.uniswap.org/positions/create?... (everything pre-filled, our hook selected)
  → user signs in their wallet
  ↓
PositionManager.modifyLiquidities → our BackedMirrorHook
  → backing position created in fat pool
  → user receives LP NFT (claim ticket)
```

**Stack:** static frontend (Vercel free tier) + hook contracts + keeper bot on Cloudflare Workers. Total infra ≈ $0–20/month.

### Caveat 1: Flag-encoded hook address

Hook address must have low bits encoding enabled permissions. Must deploy via `CREATE2` with mined salt so deployed address matches expected flag pattern. Uniswap UI verifies this and rejects mismatched addresses.

### Caveat 2: UI shows custom-hook warning

Every pool with a non-zero `hooks` address triggers a "This pool uses a custom hook" warning that users must click through. Normal V4 friction, but adds onboarding cost. Mitigation: detailed landing-page docs explaining the warning is expected.

### Caveat 3 (CRITICAL): UI may render our positions as worthless

This is the **biggest open risk** in the design.

The Uniswap UI reads position state from PoolManager directly via `StateLibrary` — it does **not** call our custom view functions. With `afterAddLiquidityReturnDelta` canceling our-pool accounting, the position stored under our PoolKey will have `liquidity = 0` (or near-zero). When user opens their position page in Uniswap UI later:
- Shows 0 fees
- Shows 0 value
- Shows "out of range" or N/A

The actual backing position in the fat pool is invisible to the UI because it's stored under a different PoolKey + salt.

User opens UI → sees worthless position → assumes they were scammed → panic.

**Possible mitigations (need testing):**

1. **Symbolic liquidity in our pool** — mint minimal `liquidity = 1` so position isn't "empty" in UI; but UI still shows tiny value, not the real backing value.
2. **No `afterAddLiquidityReturnDelta`** — let position genuinely form in our pool, then perform internal swap to fat pool. Complex accounting, fragile.
3. **Custom dashboard for monitoring** — accept UI piggyback for *placement only*, build our own dashboard for *viewing/managing* positions. This breaks the "pure piggyback" promise but is realistic.
4. **Wait for Uniswap UI hook-awareness** — Foundation has discussed adding view-fn dispatch for custom pools. No ETA.

**Realistic v1 plan:**
- Use Uniswap deep-link for **placement** (no wallet integration on our side)
- Build small custom **dashboard** for **monitoring** orders (status, time to fill, accumulated fees)
- Honest landing-page disclaimer: "View your orders at dashboard.our-domain.com, not in Uniswap UI"
- This is **hybrid** — not as clean as full piggyback, but solves the main distribution problem (no wallet integration code) while keeping monitoring honest.

## Open Questions for Tomorrow's Session

1. What's the exact `BalanceDelta` math in `_afterAddLiquidityReturnDelta` to cancel our-pool accounting?
2. How to handle the case where backing-position mint reverts (e.g., fat pool MEV-locked or non-existent tick)?
3. Should we use a single OurPool per fat-pool fee tier, or one OurPool per token pair (selecting fat pool dynamically)?
4. What's the keeper fee structure? Flat 0.5% or dynamic based on order size?
5. Migration story if Uniswap deploys V5 — how does the hook handle backing pool upgrades?
6. **NEW — UI rendering**: deploy testnet skeleton ASAP and empirically check what Uniswap testnet UI shows for our positions. This determines whether full piggyback or hybrid dashboard is the realistic path.
7. **NEW — hook address mining**: which `CREATE2` salt-mining tool to use? Need `BEFORE_INITIALIZE | AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | AFTER_ADD_LIQUIDITY_RETURN_DELTA | BEFORE_REMOVE_LIQUIDITY | AFTER_REMOVE_LIQUIDITY_RETURN_DELTA | BEFORE_SWAP` flags. Test on Anvil first.
8. **NEW — deep-link UX testing**: empirically check whether Uniswap UI on testnet correctly parses our pre-filled URL with `hook=` parameter, or rejects/warns on custom hooks.
