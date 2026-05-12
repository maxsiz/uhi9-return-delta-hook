# PositionManagerService — Self-Custody Auto-Rebalance for Fat-Pool LPs

> **Status:** Architecture draft. Not implemented.
> **Next:** Resolve strategy interface design, deploy MVP with single "follow-price" strategy.

## Concept

A non-custodial service for managing concentrated LP positions in **existing fat pools** (Uniswap V4 canonical pools — WETH/USDC, etc.). Users keep their LP NFTs in their own wallets; our `PositionManager` operates on positions via `setApprovalForAll` + `subscribe` patterns. The service applies rebalancing strategies (follow-price, volatility-adaptive, profit-taking, IL-stop) triggered by keepers.

## Value Proposition

**For users (LPs):**
- Keep NFT in own wallet — no custody risk
- Pluggable strategies (start with one, swap later)
- Composable: NFT can be subscribed to our service AND used as collateral elsewhere
- Exit anytime (revoke approval = stop auto-management; still own NFT)

**For us (the protocol):**
- Per-rebalance fee (e.g., 1% of fees harvested + small spread on rebalance swap)
- Optional management fee (small annualized %)
- Strategy marketplace: third parties contribute strategies, share revenue

**Compared to existing solutions:**

| Property | Gamma | Arrakis | **Us** |
|----------|-------|---------|--------|
| Custody | vault | vault | **user (NFT in own wallet)** |
| Share token | ERC-20 LP-shares | ERC-20 LP-shares | **original ERC-721 NFT** |
| Composability | vault-share only | vault-share only | **full DeFi (NFT-native)** |
| Strategy choice | preset per vault | preset per vault | **per-position via subscribe** |
| Exit | withdraw from vault | withdraw from vault | **revoke approval, keep NFT** |
| Trust model | trust vault contract | trust vault contract | **trust narrow approval scope** |

**Why this is NOT a V4 hook play:**
Hooks fire on swaps in their own pool. We want to react to events in the **fat pool** (which we don't control). So we use:
- **PosM Subscriber pattern** — get callbacks on our subscribed positions
- **ERC-721 `setApprovalForAll`** — allow our Manager to operate on user's positions
- **Keeper bot** — monitors fat-pool tick crossings off-chain, calls `rebalance(tokenId)` on Manager

This is a **PositionManager-level integration**, not a V4 hook.

## Architecture Overview

```
User onboarding (one-time):
  1. User already holds (or mints) LP NFT in fat pool via Uniswap UI
  2. User → PositionManager.setApprovalForAll(OurManager, true)
  3. User → PositionManager.subscribe(tokenId, OurManager, abi.encode(strategyParams))
     → OurManager.notifySubscribe records strategy config

Continuous operation:
  Keeper bot (off-chain):
    - Monitors all subscribed positions (state via StateLibrary)
    - Compares against strategy thresholds
    - When rebalance needed: TX → OurManager.rebalance(tokenId, newParams)
  
  OurManager.rebalance(tokenId):
    - Decode strategy + current state
    - Compute new range based on strategy
    - Via PosM (using approval):
      a. modifyLiquidities([DECREASE_LIQUIDITY -100%, BURN])  ← burn old
      b. modifyLiquidities([MINT_POSITION new])               ← mint new
      c. subscribe(newTokenId, OurManager, sameParams)        ← re-subscribe
    - Skim small fee from harvested fees
    - Emit event for indexers

User cancel:
  - Either: setApprovalForAll(OurManager, false) → no more rebalance
  - Or: unsubscribe(tokenId) → drop subscription
  - User keeps NFT either way; can still manage manually via Uniswap UI
```

## Critical Files to Create

| File | Purpose |
|------|---------|
| `src/PositionManagerService.sol` | Main contract; entry points for rebalance, subscriber callbacks |
| `src/strategies/IStrategy.sol` | Strategy interface (computeRange, shouldRebalance) |
| `src/strategies/FollowPriceStrategy.sol` | Default: keep position centered on current tick |
| `src/strategies/VolatilityAdaptiveStrategy.sol` | Range width adapts to vol |
| `src/strategies/ProfitTakeStrategy.sol` | Convert to spot when out of range, re-enter on retracement |
| `src/strategies/ILStopStrategy.sol` | Close position when IL exceeds threshold |
| `src/lib/PositionMath.sol` | Helpers for tick-spacing snapping, range computation, fee accounting |
| `src/FeeDistributor.sol` | Handles fee skimming and distribution to keeper/protocol/user |
| `script/DeployService.s.sol` | Deploy Manager + initial strategies |
| `test/PositionManagerService.t.sol` | Forge tests covering all strategies |
| `keeper/index.ts` | Off-chain keeper bot (TypeScript) — monitors positions, triggers rebalance |

## Strategy Specifications

### Strategy A: Follow Price (default, simplest)

**Goal:** Keep position centered around current tick. Re-center when drift exceeds threshold.

**Params:**
```solidity
struct FollowPriceParams {
    int24 halfWidth;             // e.g., 600 ticks → ±0.6% (at tickSpacing=60)
    int24 driftThreshold;        // e.g., 200 ticks → triggers rebalance when center drifts
    uint256 minTimeBetween;      // anti-thrash: min 1 hour between rebalances
    uint16 keeperFeeBps;         // e.g., 50 = 0.5% of harvested fees
}
```

**Trigger:**
```solidity
function shouldRebalance(uint256 tokenId, bytes memory params) public view returns (bool) {
    FollowPriceParams memory p = abi.decode(params, (FollowPriceParams));
    (int24 currentTick) = _readPoolTick(tokenId);
    (int24 lower, int24 upper) = _readPositionRange(tokenId);
    int24 center = (lower + upper) / 2;
    int24 drift = currentTick > center ? currentTick - center : center - currentTick;
    return drift >= p.driftThreshold 
        && block.timestamp >= lastRebalance[tokenId] + p.minTimeBetween;
}
```

**Execute:** Burn old, mint at `[currentTick - halfWidth, currentTick + halfWidth]` snapped to tickSpacing.

### Strategy B: Volatility Adaptive

**Goal:** Wide range during high vol (reduce IL), narrow during low vol (maximize fees).

**Params:**
```solidity
struct VolAdaptiveParams {
    int24 baseHalfWidth;         // e.g., 600 ticks (low-vol default)
    int24 maxHalfWidth;          // e.g., 6000 ticks (high-vol cap)
    uint32 lookbackPeriod;       // e.g., 1 hour for vol calculation
    address volOracle;           // RedStone / Chainlink / custom TWAP
}
```

**Trigger & execute:** Read vol from oracle, scale halfWidth proportionally. Rebalance when realized vol significantly differs from current width.

### Strategy C: Profit Take

**Goal:** When pool tick fully exits range (position 100% in one token), convert and re-enter.

**Params:**
```solidity
struct ProfitTakeParams {
    int24 reEnterHalfWidth;
    uint16 conversionRate;       // % of one-sided amount to convert back (50% = keep half profit)
    uint16 keeperFeeBps;
}
```

**Trigger:** Position fully out of range.

**Execute:**
1. Burn position (now 100% USDC after pump)
2. Sell `conversionRate%` of USDC back to ETH via fat-pool swap
3. Mint new position centered around new current price

### Strategy D: IL Stop

**Goal:** Close position when impermanent loss exceeds threshold.

**Params:**
```solidity
struct ILStopParams {
    uint16 ilThresholdBps;       // e.g., 500 = 5% IL triggers exit
    address pricePeg;            // baseline asset for comparison (e.g., 50/50 ETH/USDC hold)
}
```

**Trigger:** Computed IL > threshold.

**Execute:** Burn position, transfer proceeds to user (no re-entry). User can manually re-engage when comfortable.

### Strategy E: Yield Boost (advanced)

**Goal:** Deploy idle out-of-range liquidity to Aave for additional yield.

**Mechanism:**
- When position is one-sided (price out of range), the "depleted" token side sits idle
- Strategy withdraws the in-range portion, deposits to Aave
- When price re-enters range, withdraws from Aave to be ready for swap-through

**Risk:** Aave withdraw delay if price moves fast. Requires careful design.

## Required Approvals & Subscriptions

User must give to our PositionManagerService:
1. `PositionManager.setApprovalForAll(OurService, true)` — allows decrease/increase/burn on user's NFTs
2. `PositionManager.subscribe(tokenId, OurService, strategyParams)` — per-position activation

We do NOT need:
- Token approvals (ERC-20) — all token movement is via PoolManager flash-accounting
- ETH custody — settlement is atomic per rebalance
- Authority over other NFTs — approvalForAll is scoped to PositionManager only

## Keeper Bot Design

**Stack:** Node.js / TypeScript on Cloudflare Workers (cheap, scales).

**Monitoring loop (every block on L2, every minute on L1):**
```ts
for each subscribed tokenId:
  const state = await readPositionState(tokenId);  // via multicall to PoolManager
  const strategy = strategies[positionConfig[tokenId].strategyId];
  if (strategy.shouldRebalance(state)) {
    enqueueRebalance(tokenId);
  }
```

**Execution queue:**
- Batch up to 5 rebalances per TX (via multicall)
- Submit with 25% above base gas to ensure inclusion
- Monitor TX status; retry on failure

**Economics:**
- Keeper earns 0.5% of harvested fees per rebalance
- Gas cost on L2: ~$0.10-0.50 per rebalance
- Profitable per rebalance if position generates > ~$100 in fees since last rebalance

**Decentralization plan:**
- v1: single keeper run by us
- v2: open keeper API + reward — anyone can run keeper
- v3: keeper-as-service marketplace

## Reused Patterns from Existing Codebase

- **`StateLibrary`** — reading position state, slot0 (already used in `SelfLPLib.previewFeesETH`)
- **`SelfLPLib.computeRange`** (`src/lib/SelfLPLib.sol`) — tick-spacing-aware range computation
- **`SelfLPDirect._reinvest`** — pattern of burn + mint within callback (here we're outside unlock, but math is similar)
- **`CurrencySettler`** — for any token movement needed
- **Subscriber pattern** — to be implemented via `ISubscriber` from v4-periphery

## Open Design Decisions

1. **Strategy upgrade path:**
   - Option A: each position locked to one strategy contract at subscribe
   - Option B: strategy can be updated by user via `setStrategy(tokenId, newParams)`
   - **Recommendation: B for flexibility, with on-chain strategy registry to prevent malicious strategies.**

2. **Keeper trust model:**
   - Option A: only whitelisted keepers can call `rebalance` (centralized but safer)
   - Option B: permissionless — anyone can trigger rebalance + earn fee (decentralized but MEV-prone)
   - **Recommendation: B with rate limiting per tokenId (min time between rebalances).**

3. **Strategy malicious code prevention:**
   - User could be tricked into subscribing to malicious strategy → rebalance rugs them
   - **Mitigation: only whitelist audited strategies via on-chain registry; user can pick from approved list.**

4. **Fee accounting precision:**
   - PosM doesn't expose fee delta directly — need to read `feeGrowthInside` and compute manually
   - **Recommendation: use `StateLibrary.getPositionInfo` pattern from `SelfLPLib.previewFeesETH`.**

5. **Cross-pool support:**
   - v1: support only V4 PositionManager-issued positions
   - v2: extend to V3 positions via separate adapter
   - **Recommendation: v1 V4-only; explicit scope.**

6. **Strategy parameter validation:**
   - Some params can be unsafe (e.g., halfWidth=1 → constant rebalance thrashing)
   - **Recommendation: enforce min/max bounds in strategy contract.**

## Verification Plan

### Phase 1: Local Forge tests
```bash
forge test --match-path ./test/PositionManagerService.t.sol -vv
```

Test cases:
- `test_subscribe_recordsStrategy` — subscription stores config
- `test_unsubscribe_clearsState` — clean unsubscribe
- `test_followPrice_drift_triggersRebalance` — drift > threshold → rebalance
- `test_followPrice_smallDrift_noRebalance` — within threshold → no-op
- `test_followPrice_antiThrash_respectsMinTime` — rapid drifts don't cause thrashing
- `test_rebalance_emitsCorrectEvent` — proper events for indexers
- `test_volAdaptive_widensOnHighVol` — vol oracle high → wider range
- `test_profitTake_outOfRange_converts` — fully out-of-range triggers conversion
- `test_ilStop_threshold_exits` — IL > threshold → position closed
- `test_userRevokesApproval_cannotRebalance` — approval revocation works
- `test_keeperFee_paidCorrectly` — keeper earns expected fee
- `test_maliciousStrategy_rejected` — only whitelisted strategies accepted

### Phase 2: Mainnet fork tests
```bash
forge test --fork-url $BASE_RPC --match-path ./test/PositionManagerService.fork.t.sol
```
Use real fat-pool state on Base. Test against actual PositionManager + PoolManager.

### Phase 3: Keeper bot integration test
- Deploy on Base Sepolia
- Run keeper bot for 7 days against simulated price oscillations
- Verify rebalances happen at expected times with correct economics

### Phase 4: Audit + mainnet
- External audit (focus on approval scope correctness, strategy registry security)
- Deploy on Base with 1-2 sample strategies
- Onboard 10-20 beta users from DeFi communities
- Monitor for 30 days before opening publicly

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Approval scope misunderstood by user → unintended rebalances | 🔴 High | Clear UI + revoke-anytime guarantee |
| Malicious strategy contract drains positions | 🔴 High | Whitelist-only strategy registry; audit each |
| Keeper centralization | 🟡 Medium | v2: open keeper API; eventually keeper marketplace |
| Race conditions between user manual action and keeper | 🟡 Medium | Subscriber gates with reverts on inconsistent state |
| Gas costs make small positions uneconomical | 🟡 Medium | Minimum position size enforced; L2-first deployment |
| Competing with Gamma's brand + TVL | 🔴 High | Self-custody differentiation; B2B integration with wallets |
| Subscribe-pattern breaks if user transfers NFT | 🟢 Low (auto-unsubscribe) | Documented behavior; UI warns |

## Market & Revenue Model

**TAM:**
- Gamma: ~$200M TVL → ~$2M revenue/year
- Arrakis: ~$150M TVL → similar
- Total auto-LP market: ~$700M TVL on V3+V4
- Growing with V4 adoption

**Capture strategy:**
- Differentiation: self-custody NFT, composability
- B2B distribution: integrate with wallet UIs (Rabby, Frame, MetaMask Snap)
- Realistic year 1 TVL: $20-50M
- Revenue: ~$200K-500K (mix of rebalance fee + management fee)

**Pricing model:**
- Per-rebalance: 0.5% of fees harvested
- Optional: 1%/year management fee for premium strategies
- Keeper API fee: charge protocol integrators (e.g., $0.01 per monitored position)

## Out of Scope (v1)

- Multi-position portfolios (per-position v1; portfolio composer in v2)
- Cross-pool routing during rebalance (just burn-and-mint same pool v1)
- Limit orders / stop-losses (separate product; potentially Token Launch Hook integration)
- V3 position support
- Cross-chain positions

## Roadmap

| Phase | Duration | Deliverable |
|-------|----------|-------------|
| Spec & interfaces | 2 weeks | Strategy interface, registry pattern locked |
| Core Manager + FollowPrice strategy | 6 weeks | Single-strategy MVP working on testnet |
| Additional strategies (Vol, ProfitTake, ILStop) | 6 weeks | 4 strategies in registry |
| Keeper bot + monitoring | 4 weeks | Production-grade keeper |
| Audit | 6 weeks | External audit |
| Testnet beta | 4 weeks | 20 beta users, 30 days observation |
| Mainnet launch | — | Public release |

**Total to mainnet: ~7 months.**

## Open Questions for Future Sessions

1. **Strategy interface design**: should strategies be pure (deterministic given state) or have their own keeper logic?
2. **Position composability**: can the LP-NFT be subscribed to OUR Manager AND another protocol's subscriber simultaneously? (Subscriber is exclusive per NFT in current V4 spec.)
3. **Strategy marketplace economics**: do strategy authors share rebalance fee? If so, how to split between author / keeper / protocol?
4. **Migration story**: if Uniswap V5 changes PositionManager interface, how does our service adapt?
5. **Wallet integration**: target one wallet (Rabby?) for v1 deep integration or stay wallet-agnostic with custom UI?
6. **TWAP-aware rebalancing**: instead of single-block rebalance, split across multiple blocks to reduce MEV exposure?
