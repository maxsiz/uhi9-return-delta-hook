# TokenLaunchHook — V4 Hook for Fair Token Launches

> **Status:** Architecture draft. Not implemented.
> **Next:** Resolve open design questions, deploy testnet skeleton with minimal mechanism set.

## Concept

A V4 hook attached to the pool of a newly launched token. The hook enforces fair-launch rules: anti-snipe, buy/sell tax, liquidity locking with conditional unlocks, whitelist phases, and bonding-curve fallback. Replaces today's kludgy "ERC-20 with tax logic baked in" pattern with a clean separation: standard ERC-20 + dedicated launch-economics hook on the pool.

## Value Proposition

**For project creators:**
- Standard ERC-20 (no custom tax logic in token) → easier CEX listing later
- Composable mechanisms (anti-snipe + tax + lock + whitelist) configurable per launch
- Liquidity lock is **technically enforced** (rug pulls become impossible by code, not just by trust)
- Multi-mechanism single deploy: configure via hook params instead of multiple tools

**For traders/holders:**
- Fair access (snipers can't loot the first block)
- Price floor support via sell-tax → buyback mechanism
- Protection against rug pull (LP locked until objective conditions met)

**For us (the protocol):**
- Per-launch fee (e.g., 0.5% of seed liquidity)
- Continuous fee from swap tax allocation
- Memecoin sector revenue: $200M+/year on EVM, mostly captured by V3-era tools

## Why V4 Hook is the Right Fit

| Mechanism | Today's approach | V4 hook approach |
|-----------|-------------------|------------------|
| Buy/sell tax | Embedded in ERC-20 token (rigid, breaks composability) | In pool hook (token stays clean) |
| Anti-snipe | Off-chain via launchpad UI (centralized, gameable) | On-chain in `_beforeSwap` (trustless) |
| LP lock | Separate timelock contract (rigid time-based only) | Hook-driven (volume/holder/price conditions) |
| Whitelist | Token-level allowlist (cross-protocol breakage) | Per-pool restriction (clean separation) |
| Bonding curve | Separate ICO contract | Built into hook's swap routing |

V4's hook architecture is **purpose-built** for this. Cleaner than every existing alternative.

## Architecture Overview

```
Project deploys:
  1. Token contract (standard ERC-20, no special logic)
  2. TokenLaunchHook (with config: anti-snipe blocks, tax rates, lock condition)
  3. Pool: PoolKey(NEWTOKEN, WETH, fee=dynamic, tickSpacing=60, hooks=TokenLaunchHook)
  4. Initial liquidity → LP NFT locked to LiquidityLock contract

Launch goes live (block 0):
  - First N blocks: hook enforces max buy size + rate limits
  - Tax mechanism active on every swap
  - LP NFT locked until condition met

Time passes:
  - Hook tracks: volume, unique holders, time, price history
  - Each swap: _beforeSwap (validation, tax) + _afterSwap (event recording)

Unlock conditions met:
  - LiquidityLock allows LP withdrawal
  - Or graceful transition: lock partially decays over time

Mature launch:
  - Tax rates decay to minimal
  - Anti-snipe windows long past
  - Pool operates as normal V4 pool
```

## Critical Files to Create

| File | Purpose |
|------|---------|
| `src/TokenLaunchHook.sol` | Main hook; implements anti-snipe, tax, whitelist |
| `src/LiquidityLock.sol` | Custodian for LP NFT with conditional unlock logic |
| `src/lib/LaunchMath.sol` | Tax calculation, decay curves, bonding curve math |
| `src/lib/UnlockConditions.sol` | Library of unlock condition predicates (time, volume, holders, price) |
| `src/TokenLaunchFactory.sol` | One-shot deploy: token + hook + pool + lock in single TX |
| `script/DeployLaunch.s.sol` | Configuration-driven launch deployment |
| `test/TokenLaunchHook.t.sol` | Forge tests for each mechanism |

## Mechanisms — Design Specs

### M1: Anti-Snipe Block-Window

**Goal:** Prevent sniper bots from buying entire supply in block 0.

**Spec:**
- `antiSnipeBlocks: uint32` — duration in blocks (default 10)
- `maxBuyBpsPerBlock: uint16` — max % of supply purchasable per block by any address
- `cooldownBlocks: uint8` — min blocks between TX from same address
- Optional: snapshot block 0 buyers, blacklist them from selling for X blocks

```solidity
function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
    internal override returns (bytes4, BeforeSwapDelta, uint24) 
{
    if (block.number < launchBlock + antiSnipeBlocks) {
        require(_isBuy(params), "No sells during anti-snipe");
        require(_buyAmount(params) <= maxBuyAbsolute, "Snipe attempt");
        require(lastBuyBlock[tx.origin] + cooldownBlocks <= block.number, "Cooldown");
        lastBuyBlock[tx.origin] = block.number;
    }
    // continue to tax logic...
}
```

### M2: Buy/Sell Tax

**Goal:** Asymmetric tax — discourage early sells, encourage buys.

**Spec:**
- `buyTaxBps: uint16` — initial buy tax (e.g., 100 = 1%)
- `sellTaxBps: uint16` — initial sell tax (e.g., 500 = 5%)
- `decayPeriod: uint32` — period over which tax decays to base rate
- `baseTaxBps: uint16` — eventual minimum tax (e.g., 30 = 0.3%)

```solidity
function _beforeSwap(...) returns (bytes4, BeforeSwapDelta, uint24) {
    uint24 dynamicFee;
    uint256 elapsed = block.timestamp - launchTime;
    
    if (_isBuy(params)) {
        dynamicFee = uint24(_decay(buyTaxBps, baseTaxBps, elapsed, decayPeriod));
    } else {
        dynamicFee = uint24(_decay(sellTaxBps, baseTaxBps, elapsed, decayPeriod));
    }
    return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), dynamicFee);
}
```

**Tax distribution** (via `_afterSwap`):
- 50% to LP holders proportional
- 30% to project treasury
- 20% to buyback & burn

### M3: Liquidity Lock with Conditional Unlock

**Goal:** Prevent rug pulls by locking LP until objective milestones met.

**Spec — conditions:**
- `unlockMode: enum { TIME_ONLY, VOLUME, HOLDERS, PRICE_FLOOR, COMBINED }`
- `timeUnlock: uint256` — unix timestamp of guaranteed unlock
- `volumeThreshold: uint256` — cumulative ETH volume required (e.g., 500 ETH)
- `holderThreshold: uint32` — minimum unique holders (e.g., 1000)
- `priceFloor: uint256` — minimum price; must hold for `priceFloorDays`

Each condition trackable via hook callbacks:
- Volume: increment in `_afterSwap`
- Holders: bloom-filter approximate count (gas-friendly) or `Transfer` events
- Price: read `slot0` periodically, track time-above-floor

```solidity
function tryUnlock() external {
    require(_conditionsMet(), "Conditions not met");
    LP_NFT.transferFrom(address(this), projectOwner, lockedTokenId);
    emit Unlocked(block.timestamp, projectOwner);
}
```

### M4: Whitelist Phases

**Goal:** KYC'd early access, then progressive opening.

**Spec:**
- Phase 1 (0-7 days): Only whitelist; max buy = X
- Phase 2 (7-30 days): Open buy, max sell = Y/day per address
- Phase 3 (30+): Fully open

Whitelist source: external contract (e.g., Verax attestation, Sismo, simple Merkle root).

### M5: Bonding Curve Fallback

**Goal:** Handle launches with thin initial liquidity gracefully.

**Spec:**
- If pool liquidity < `minLiquidity`, swap routed through bonding curve in hook
- Bonding curve formula: `priceN = basePrice * (1 + supplyN / supplyTotal)^exponent`
- Reserves from sells go to LP, increasing liquidity over time

Implemented via `BeforeSwapDelta` adjustments in `_beforeSwap`.

### M6: Sell-Pressure Auto-Buyback (advanced)

**Goal:** Automatic price support during sell-offs.

**Spec:**
- Hook tracks sell volume in recent window
- If sell pressure > threshold, hook taps treasury reserves
- Atomic buyback inside the sell TX (counter-buy)
- Stabilizes price during panic dumps

## Required Hook Permissions

```solidity
Hooks.Permissions({
    beforeInitialize: true,                       // validate pool config
    afterInitialize: true,                        // set dynamic fee
    beforeAddLiquidity: true,                     // restrict who can add (only project + LP lock)
    beforeRemoveLiquidity: true,                  // route through LiquidityLock
    beforeSwap: true,                             // anti-snipe + tax + whitelist
    afterSwap: true,                              // tax distribution + state tracking
    beforeSwapReturnDelta: true,                  // dynamic tax / bonding curve
    afterSwapReturnDelta: true,                   // redirect tax to treasury
    afterAddLiquidityReturnDelta: false,
    afterRemoveLiquidityReturnDelta: false,
    beforeDonate: false,
    afterDonate: false
});
```

## Reused Patterns

- **`BaseHook`** (`lib/v4-hooks-public/src/base/BaseHook.sol`) — standard inheritance
- **Dynamic fee** via `LPFeeLibrary.DYNAMIC_FEE_FLAG` + `updateDynamicLPFee` — pattern from `SelfLPDirect._afterInitialize`
- **`BeforeSwapDelta`** sign conventions — same as we use in `InternalSwapPool`
- **`CurrencySettler`** — for tax distribution settlement

## Open Design Decisions

1. **Tax distribution recipient model:**
   - Option A: hook auto-distributes (more gas, more trustless)
   - Option B: hook accrues, anyone can `harvest()` (less gas, requires keeper)
   - **Recommendation: B with batched harvest.**

2. **Holder counting:**
   - Exact count requires event indexing → off-chain
   - Approximate via Bloom filter → on-chain but lossy
   - Token contract's `balanceOf` snapshot → expensive
   - **Recommendation: external `IHolderCounter` interface; projects can wire to subgraph or oracle.**

3. **Anti-snipe robustness:**
   - `tx.origin` checks defeatable via contract relayers
   - Add nonce/commit-reveal? Adds friction.
   - **Recommendation: combine tx.origin + first-block snapshot blacklist for v1.**

4. **Composability with subscribe:**
   - Project's LP NFT could subscribe to LaunchHook for analytics
   - Hook can emit standardized "OrderFilled / Volume" events
   - **Recommendation: yes, support subscribe in v2.**

5. **Bonding curve activation logic:**
   - Always-on hybrid? Or only when liquidity below threshold?
   - **Recommendation: only when below threshold; turn off once mature.**

6. **Per-launch configurability vs preset templates:**
   - Full config = power but complex UX
   - Templates ("memecoin", "RWA-token", "DAO-token", "fair-launch") = simple UX but limiting
   - **Recommendation: templates with override params.**

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Reputation: memecoin scams use our hook | 🔴 High | Position as "fair launch infra"; vet projects via opt-in audit |
| Regulatory: ICO-like mechanisms = securities | 🔴 High | Geofence US users on frontend; legal review of templates |
| MEV: sniper bots adapt to our anti-snipe | 🟡 Medium | Continuous iteration; collaborative testing with searchers |
| Hook code bugs in production = catastrophic | 🔴 High | Comprehensive audit (~$50K); bug bounty |
| Tax logic gas cost makes small swaps uneconomical | 🟡 Medium | Optimize gas; consider waiver for swaps below threshold |
| Competition from PinkSale/DxSale moves to V4 | 🟡 Medium | First-mover advantage; better tech moat |

## Market & Revenue Model

**TAM:**
- ~500K token launches/year on EVM
- ~50K reach actual trading
- ~5K cross $1M market cap
- Existing infra revenue: $200M+/year (PinkSale, DxSale, Maestro, Banana Gun, others)

**Capture strategy:**
- 5% of EVM launches → ~25K launches/year using our hook
- Average revenue per launch: $200-2000 (one-time launch fee + ongoing tax cut)
- Realistic year 1: $5M revenue

**Pricing model options:**
- Flat launch fee: 0.1 ETH per pool deployment
- % of seed liquidity: 0.5% taken from initial LP
- % of ongoing tax: 10% of tax volume routed to our treasury
- Combination of above

## Verification Plan

### Phase 1: Local Forge tests
```bash
forge test --match-path ./test/TokenLaunchHook.t.sol -vv
```

Test cases:
- `test_antiSnipe_largeBuy_reverts` — block 0 buy > limit reverts
- `test_antiSnipe_cooldown_reverts` — same address two TX same block reverts
- `test_antiSnipe_passesAfterWindow` — after N blocks restrictions lift
- `test_tax_buyAndSell_correctRates` — verify asymmetric tax applied
- `test_tax_decay_overTime` — tax decreases per schedule
- `test_taxDistribution_correctSplits` — 50/30/20 verified
- `test_liquidityLock_timeOnly_unlocks` — time-based unlock works
- `test_liquidityLock_volumeCondition_unlocks` — volume-based unlock
- `test_liquidityLock_combined_unlocks` — combined conditions
- `test_whitelist_phase1_restricts` — non-whitelisted reverts in phase 1
- `test_bondingCurve_lowLiquidity_routes` — fallback activates
- `test_buybackTrigger_sellPressure` — auto-buyback fires correctly

### Phase 2: Mainnet fork tests
```bash
forge test --fork-url $BASE_RPC --match-path ./test/TokenLaunchHook.fork.t.sol
```
Test against live Uniswap V4 PoolManager on Base.

### Phase 3: Testnet deployment
- Deploy on Base Sepolia with mock token
- Launch full scenario: anti-snipe → tax → unlock
- Verify with sample sniper bot, retail trader, sell-pressure simulator

### Phase 4: Audit + mainnet
- External audit (Spearbit, Trail of Bits, or specialized launchpad auditor)
- Bug bounty on Immunefi pre-mainnet (~$50K)
- Mainnet deploy on Base or Unichain (cheaper gas for launches)

## Out of Scope (v1)

- Cross-chain launches (single chain per launch in v1)
- Dynamic re-configuration (config locked at deploy)
- IDO-style price discovery auctions (consider for v2)
- Vesting cliff schedules for project team (deploy separate vesting contract)
- Governance over hook config (add later as v2 feature)

## Roadmap

| Phase | Duration | Deliverable |
|-------|----------|-------------|
| Spec & design | 2 weeks | This doc finalized + interfaces |
| Core hook + tests | 6 weeks | M1-M3 implemented, 90% test coverage |
| Extended mechanisms | 4 weeks | M4-M5 implemented |
| Audit | 4-6 weeks | External audit, fixes |
| Testnet launch + beta | 4 weeks | 3-5 beta launches |
| Mainnet | — | Public launch with partner project |

**Total to mainnet: ~5-6 months.**

## Open Questions for Future Sessions

1. **Permission model for hook config**: who can update parameters post-deploy? Immutable safer; upgradeable more flexible.
2. **Cross-chain deploy**: same hook code on Base + Arbitrum + Unichain — separate deployments or shared via LayerZero?
3. **Sandwich resistance for tax logic**: dynamic fee changes within block can be exploited; add EIP-3074-style batching?
4. **Integration with existing launchpads**: partnership with PinkSale (they integrate our hook as backend) vs competition?
5. **Tax distribution governance**: hard-coded splits or DAO-governed per launch?
6. **Branding / positioning**: "Fair Launch Infrastructure" vs "Memecoin Pump Tool" — drastically different audiences and risk profiles.
