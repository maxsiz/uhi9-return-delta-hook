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

## Deployment Architecture: Factory + EIP-1167 Proxy

### Why proxy pattern

Each token launch needs its own hook (per-pool isolated config + state). Naive approach (deploy full hook contract per launch) is ~500K-1.5M gas per deploy — significant on Mainnet (~$30-90 each).

**Solution: EIP-1167 minimal proxy** ([OZ Clones library](https://docs.openzeppelin.com/contracts/4.x/api/proxy#Clones)). Each launch gets a tiny ~50K-gas proxy that delegatecalls to one shared implementation. ~90% deploy gas savings.

### Why no BaseHook refactor needed

`BaseHook` validates `address(this)` in its constructor (permission flag bits). With EIP-1167:
- Constructor of implementation **runs once at impl deploy** with `address(this) = impl address`
- Proxies are NEW contracts at NEW addresses, deployed via CREATE2

**Key insight: mine CREATE2 salt for BOTH implementation and every proxy** so both have the same permission flag bits in their addresses. Then:
- `BaseHook`'s constructor passes for implementation (its address has flags ✓)
- V4 PoolManager validates each proxy when used as `key.hooks` at `_beforeInitialize` (proxy's address has flags ✓)

**BaseHook stays completely unchanged.** No fork, no custom base.

### Component diagram

```
                Mining: CREATE2 salt → address has correct permission flag bits
                                                   │
                                                   ▼
┌──────────────────────────────────────────────────────────────┐
│  TokenLaunchHookImpl  (deployed ONCE per chain)              │
│  • inherits BaseHook (UNCHANGED) + TokenLaunchHookBase       │
│  • constructor(IPoolManager) — runs once at impl deploy      │
│  • setupLaunch(LaunchConfig) — per-proxy init via delegatecall│
│  • All hook callbacks (_beforeSwap, _afterSwap, etc.)        │
│  • All governance functions (setBuyTax, extendUnlock, ...)   │
└────────────────────────┬─────────────────────────────────────┘
                         │
                         │  delegatecall target (immutable in EIP-1167)
                         │
              ┌──────────┴──────────┬─────────────────┬─────────────────┐
              │                     │                 │                 │
       ┌──────▼───────┐      ┌──────▼───────┐  ┌──────▼───────┐  ┌──────▼───────┐
       │ Proxy_Launch1│      │ Proxy_Launch2│  │ Proxy_Launch3│  │ ...          │
       │ ─────────────│      │ ─────────────│  │ ─────────────│  │              │
       │ ~45 bytes    │      │ ~45 bytes    │  │ ~45 bytes    │  │              │
       │ own storage: │      │ own storage: │  │ own storage: │  │              │
       │   config_1   │      │   config_2   │  │   config_3   │  │              │
       │   gov NFT_1  │      │   gov NFT_2  │  │   gov NFT_3  │  │              │
       │   vol_1, ... │      │   vol_2, ... │  │   vol_3, ... │  │              │
       └──────┬───────┘      └──────┬───────┘  └──────┬───────┘  └──────────────┘
              │                     │                 │
              │  key.hooks=proxy    │                 │
              │                     │                 │
        ┌─────▼─────┐         ┌─────▼─────┐    ┌──────▼────┐
        │  Pool A   │         │  Pool B   │    │  Pool C   │
        └───────────┘         └───────────┘    └───────────┘

┌────────────────────────────────────────────────────┐
│  TokenLaunchHookFactory  (deployed ONCE per chain) │
│  • IMPLEMENTATION = TokenLaunchHookImpl            │
│                                                     │
│  function deployLaunch(LaunchConfig) atomic:        │
│    1. mine salt off-chain for proxy flag bits       │
│    2. proxy = Clones.cloneDeterministic(IMPL, salt) │
│    3. TokenLaunchHookImpl(proxy).setupLaunch(cfg)   │
│    4. require(hookFlagBitsValid(proxy))             │
│    5. emit LaunchDeployed(proxy, deployer, cfg)     │
└────────────────────────────────────────────────────┘
```

### setupLaunch pattern (replacing per-proxy constructor)

EIP-1167 proxies don't run implementation's constructor. We use atomic init via factory:

```solidity
contract TokenLaunchHookImpl is BaseHook, TokenLaunchHookBase {
    // BaseHook's constructor runs once at IMPL deploy with valid flag address
    constructor(IPoolManager _pm) BaseHook(_pm) {}

    function setupLaunch(LaunchConfig calldata cfg) external {
        require(!_initialized, "Already set up");
        _initialized = true;
        _config = cfg;
        emit LaunchInitialized(address(this), cfg);
    }
}

contract TokenLaunchHookFactory {
    address public immutable IMPLEMENTATION;

    function deployLaunch(LaunchConfig calldata cfg, bytes32 salt) 
        external returns (address proxy) 
    {
        // Atomic: clone + setup in single TX → no init race
        proxy = Clones.cloneDeterministic(IMPLEMENTATION, salt);
        TokenLaunchHookImpl(proxy).setupLaunch(cfg);
        require(Hooks.isValidHookAddress(proxy, getPermissions()), "Bad flag bits");
        emit LaunchDeployed(proxy, msg.sender, cfg);
    }
}
```

Race window between clone and setup = **0 blocks** (same TX, atomic).

### Multi-chain deployment

Per chain, deploy **once**:
1. Mine salt for `TokenLaunchHookImpl` address (matches permission flag bits)
2. Deploy `TokenLaunchHookImpl` via `CREATE2`
3. Deploy `TokenLaunchHookFactory` with `IMPLEMENTATION = <impl address>`

| Chain | Deploy gas savings per launch | Worth it? |
|-------|-------------------------------|------------|
| **Mainnet** | ~$30-90 (~90% of $50-100 full deploy) | ✅ Significant |
| **Unichain** | ~$0.10-1 | ✅ Cleaner architecture |
| **Base** | ~$0.10-1 | ✅ |
| **Arbitrum** | ~$0.10-1 | ✅ |

Runtime overhead per hook callback: ~700 gas (one delegatecall hop). On L2s negligible; on Mainnet ~$0.02 per swap at 30 gwei — acceptable.

### Fallback if proxy complexity unwanted: thin hook + shared logic (Path E)

If EIP-1167 nuances feel risky for v1, simpler alternative is **full per-launch hook + shared logic contract**:

```solidity
// One per chain
contract TokenLaunchLogic {
    function calculateTax(LaunchConfig cfg, ...) external view returns (uint24);
    function shouldRevertAntiSnipe(...) external view returns (bool);
    // heavy lifting here
}

// Full contract per launch (no proxy)
contract TokenLaunchHook is BaseHook {
    TokenLaunchLogic public immutable LOGIC;
    LaunchConfig public config;

    constructor(IPoolManager pm, TokenLaunchLogic logic, LaunchConfig memory cfg) BaseHook(pm) {
        LOGIC = logic;
        config = cfg;
    }

    // delegate heavy work to LOGIC via external calls
}
```

Trade-off: ~6-10× higher deploy gas vs Path C, but simpler reasoning and zero proxy nuances. **Acceptable for L2-only deployment** if Mainnet deploys are rare.

**Recommended path: C (EIP-1167) for Mainnet + L2 multi-chain target.** Path E is the fallback if v1 audit budget is constrained.

## Critical Files to Create

| File | Purpose |
|------|---------|
| `src/TokenLaunchHookImpl.sol` | Hook implementation; inherits `BaseHook` **unchanged**; has `setupLaunch()` instead of constructor-only config; stores per-launch state in storage (will be each proxy's own slots) |
| `src/TokenLaunchHookFactory.sol` | Deploys EIP-1167 proxies via `Clones.cloneDeterministic` with mined salts; atomic `clone + setupLaunch` to prevent init race |
| `src/lib/LaunchMath.sol` | Tax calculation, decay curves, bonding curve math (pure library) |
| `src/lib/UnlockConditions.sol` | Unlock condition predicates (time, volume, holders, price) |
| `script/MineSalt.s.sol` | Off-chain Foundry helper to compute CREATE2 salts that produce addresses with required permission flag bits — for both implementation and per-launch proxies |
| `script/DeployImpl.s.sol` | One-time per-chain implementation + factory deployment (mainnet, unichain, base, arbitrum) |
| `script/DeployLaunch.s.sol` | Per-launch deployment: calls factory + uses Uniswap UI URL builder for next step |
| `test/TokenLaunchHookImpl.t.sol` | Forge tests covering mechanisms |
| `test/TokenLaunchHookFactory.t.sol` | Tests: deploy proxy with correct flag bits, atomic init, race resistance |

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

## Governance: First-Position NFT Pattern

Each per-launch proxy needs **ongoing parameter management** (decay tax rates, extend lock time, etc.). To avoid centralized admin keys, governance is bound to the **NFT of the first position** created in the pool. Whoever owns that NFT controls launch parameters within bounded scope.

### Mechanism

```solidity
abstract contract TokenLaunchHookBase {
    struct LaunchConfig {
        // — Immutable (baked at setupLaunch) —
        uint64 launchTime;
        uint32 antiSnipeBlocks;
        uint16 maxBuyBpsPerBlock;
        address tokenAddress;
        address expectedFirstLP;        // who is allowed to mint the first NFT
        uint160 expectedInitialSqrtPrice; // freeze initial price (anti-griefing)
        uint64 launchEndTime;           // when governance phase ends (parameters freeze)
        // — Mutable by governance NFT owner (bounded) —
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 baseTaxBps;
        uint32 taxDecayPeriod;
        UnlockMode unlockMode;
        uint256 unlockTime;
        uint256 unlockVolumeThreshold;
        uint32 unlockHolderThreshold;
        // — etc. —
    }

    LaunchConfig internal _config;
    uint256 public governanceTokenId;   // 0 until first-LP mint
    uint256 public cumulativeVolume;
    uint32 public uniqueHolders;
    bool internal _initialized;
    bool internal _governanceCaptured;

    modifier onlyGovernance() {
        require(governanceTokenId != 0, "Governance not yet set");
        require(block.timestamp < _config.launchEndTime, "Launch ended — params frozen");
        require(
            IERC721(POSITION_MANAGER).ownerOf(governanceTokenId) == msg.sender,
            "Not governance NFT owner"
        );
        _;
    }

    // Governance setters (each enforces monotone bounds — see Mutability table)
    function setBuyTax(uint16 newBps) external onlyGovernance {
        require(newBps <= _config.buyTaxBps, "Can only decrease");
        _config.buyTaxBps = newBps;
        emit ParamUpdated("buyTaxBps", newBps);
    }

    function extendUnlockTime(uint256 newTime) external onlyGovernance {
        require(newTime >= _config.unlockTime, "Cannot shorten");
        _config.unlockTime = newTime;
    }
    // ... more setters
}
```

### Capture flow (in hook callbacks)

`_beforeInitialize` records the **expected** first LP (designated at deploy time, baked in immutable config). `_beforeAddLiquidity` captures the **actual** governance NFT tokenId on first mint:

```solidity
function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPrice) 
    internal override returns (bytes4) 
{
    require(sqrtPrice == _config.expectedInitialSqrtPrice, "Wrong initial price");
    return this.beforeInitialize.selector;
}

function _beforeAddLiquidity(
    address sender, 
    PoolKey calldata key,
    ModifyLiquidityParams calldata params,
    bytes calldata
) internal override returns (bytes4) {
    if (!_governanceCaptured) {
        // First-LP capture
        require(sender == POSITION_MANAGER, "First LP must use PositionManager");
        // Salt convention in V4 PosM: salt = bytes32(tokenId) — must verify in PosM source
        governanceTokenId = uint256(params.salt);
        _governanceCaptured = true;
        emit GovernanceEstablished(address(this), governanceTokenId);
    }
    // continue with regular validation
    return this.beforeAddLiquidity.selector;
}
```

### Anti-sandwich protection on first mint

To prevent a sniper from grabbing the governance NFT before the deployer:

**Layer A: `expectedFirstLP` check (basic)**

```solidity
require(tx.origin == _config.expectedFirstLP, "Wrong first LP");
```

`tx.origin` is fragile under Account Abstraction (EIP-7702, ERC-4337). For AA-safe alternative use **Layer B**.

**Layer B: ECDSA signature in hookData (AA-safe, recommended)**

Deployer signs an EIP-712 message off-chain. First-LP submits it via `hookData` of `MINT_POSITION` action. Hook recovers the signer in `_beforeAddLiquidity` and compares to `_config.expectedFirstLP`. Works regardless of which wallet stack the deployer uses.

**Layer C: Atomic deploy via Uniswap UI multicall**

```solidity
// On Uniswap UI for V4, pool creation flow uses PositionManager.multicall:
PositionManager.multicall([
    initializePool(key, sqrtPrice),         // → _beforeInitialize
    modifyLiquidities([MINT_POSITION, ...]) // → _beforeAddLiquidity captures gov NFT
]);
```

Both ops in one TX → race window is **0 blocks**. With Layer A or B as additional defense.

### Salt = tokenId convention

For capture to work, V4 PositionManager must use `salt = bytes32(tokenId)` when calling `PoolManager.modifyLiquidity`. **This needs to be verified in `lib/v4-hooks-public/lib/v4-periphery/src/PositionManager.sol` before relying on it.** If different, alternative capture mechanisms:
- Listen to `Transfer(address(0), recipient, tokenId)` event off-chain → call `hook.designateGovernance(tokenId)` from authorized address
- Use `subscribe(tokenId, hook, "")` from deployer immediately after mint; hook captures tokenId from `notifySubscribe`

## Parameter Mutability & Lifecycle Phases

### Mutability matrix

Principle: governance may only **reduce risk for holders**. Cannot make conditions worse.

| Parameter | Mutable by gov? | Direction allowed |
|-----------|------------------|--------------------|
| `launchTime` | ❌ immutable | — |
| `antiSnipeBlocks` | ❌ immutable | — |
| `tokenAddress` | ❌ immutable | — |
| `expectedFirstLP` | ❌ immutable | — |
| `expectedInitialSqrtPrice` | ❌ immutable | — |
| `launchEndTime` | ❌ immutable | — |
| `buyTaxBps` | ✅ | Only DECREASE |
| `sellTaxBps` | ✅ | Only DECREASE |
| `baseTaxBps` | ❌ immutable | — |
| `taxDecayPeriod` | ✅ | Only DECREASE (faster decay) |
| `unlockMode` | ❌ immutable | — |
| `unlockTime` | ✅ | Only EXTEND |
| `unlockVolumeThreshold` | ✅ | Only DECREASE |
| `unlockHolderThreshold` | ✅ | Only DECREASE |
| `priceFloor` | ✅ | Only DECREASE |
| `taxDistributionSplits` | ✅ | Bounded change (e.g., treasury % can only decrease) |

### Lifecycle phases

| Phase | Window | Governance status | Burn governance NFT? |
|-------|--------|---------------------|------------------------|
| **0: Pre-launch** | Before `setupLaunch` complete | n/a | n/a |
| **1: Launch active** | `0 → launchEndTime` | NFT owner can adjust mutable params | ❌ Hook blocks `_beforeRemoveLiquidity` for gov NFT |
| **2: Frozen post-launch** | `launchEndTime → ∞` | All setters revert; params frozen | ✅ Can burn freely (becomes normal LP NFT) |
| **3: Governance NFT burned** | After phase 2 burn | Forever frozen | n/a |

In Phase 1, governance NFT cannot be burned even at zero liquidity:

```solidity
function _beforeRemoveLiquidity(
    address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata
) internal override returns (bytes4) {
    if (
        uint256(params.salt) == governanceTokenId 
        && block.timestamp < _config.launchEndTime
    ) {
        revert("Cannot burn governance NFT during launch");
    }
    // ... LP lock checks for other positions
    return this.beforeRemoveLiquidity.selector;
}
```

This **forces the deployer's skin in the game** until launch completes — they can't pull their seed liquidity early.

### Transferability of governance

Governance NFT is a **standard ERC-721**. The owner can:
- Transfer to a multisig (Safe) — recommended for serious launches
- Transfer to a DAO governance contract
- Sell on NFT marketplace (rare but possible)
- Hold themselves

This makes the governance model **fluid** — projects can professionalize without redeploying the hook.

### Multisig integration (optional v2 feature)

For projects wanting upfront multisig governance without transferring NFT, the hook can support a designated manager:

```solidity
function setManager(address manager) external onlyGovernance {
    _config.manager = manager;
    emit ManagerSet(manager);
}

modifier onlyManagerOrGov() {
    if (_config.manager != address(0) && msg.sender == _config.manager) { _; return; }
    require(IERC721(POSITION_MANAGER).ownerOf(governanceTokenId) == msg.sender, "Not authorized");
    _;
}
```

Setters then use `onlyManagerOrGov` instead of `onlyGovernance`.

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

- **`BaseHook`** (`lib/v4-hooks-public/src/base/BaseHook.sol`) — standard inheritance, **unchanged** (impl mining solves constructor validation)
- **OpenZeppelin `Clones`** (`@openzeppelin/contracts/proxy/Clones.sol`) — battle-tested EIP-1167 implementation; use `cloneDeterministic` for CREATE2
- **Dynamic fee** via `LPFeeLibrary.DYNAMIC_FEE_FLAG` + `updateDynamicLPFee` — pattern from `SelfLPDirect._afterInitialize`
- **`BeforeSwapDelta`** sign conventions — same as in `InternalSwapPool`
- **`CurrencySettler`** — for tax distribution settlement
- **`StateLibrary`** — for reading pool state (slot0, position) inside callbacks
- **`Hooks.isValidHookAddress`** — for verifying mined addresses post-deploy in factory

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
   - `tx.origin` checks defeatable via contract relayers + broken under AA
   - **Recommendation: ECDSA signature (deployer signs EIP-712 → submitted via hookData) for v1.** Fallback to `tx.origin` for non-AA deployers.

4. **First-LP capture mechanism:**
   - Assumes V4 PosM uses `salt = bytes32(tokenId)` convention — **must verify in source**
   - If not, fallback: deployer registers gov NFT via `subscribe(tokenId, hook, "")` immediately after mint
   - **Recommendation: verify salt convention; pick approach based on actual implementation.**

5. **Multi-position first-LP edge case:**
   - If deployer mints multiple positions in same multicall, which becomes governance?
   - **Recommendation: first by order in multicall (state flag `_governanceCaptured` ensures only first triggers capture).**

6. **Composability with subscribe:**
   - Project's LP NFT could subscribe to LaunchHook for analytics
   - Hook can emit standardized "OrderFilled / Volume" events
   - **Recommendation: yes, support subscribe in v2.**

7. **Bonding curve activation logic:**
   - Always-on hybrid? Or only when liquidity below threshold?
   - **Recommendation: only when below threshold; turn off once mature.**

8. **Per-launch configurability vs preset templates:**
   - Full config = power but complex UX
   - Templates ("memecoin", "RWA-token", "DAO-token", "fair-launch") = simple UX but limiting
   - **Recommendation: templates with override params.**

9. **Path C (EIP-1167) vs Path E (thin hook + shared logic):**
   - C: ~90% deploy gas savings, ~700 gas runtime overhead, proxy nuances
   - E: simpler reasoning, full per-launch deploy gas, identical runtime cost
   - **Recommendation: C for Mainnet+L2 target; E acceptable if v1 audit budget tight or L2-only.**

10. **Multisig governance vs NFT-only governance:**
    - NFT-only: simpler, transferable, default
    - Multisig manager: more professional for serious launches
    - **Recommendation: NFT-only for v1; add `setManager` for v2.**

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Reputation: memecoin scams use our hook | 🔴 High | Position as "fair launch infra"; vet projects via opt-in audit |
| Regulatory: ICO-like mechanisms = securities | 🔴 High | Geofence US users on frontend; legal review of templates |
| MEV: sniper bots adapt to our anti-snipe | 🟡 Medium | Continuous iteration; collaborative testing with searchers |
| Implementation bug = ALL proxies broken | 🔴 High | Comprehensive audit of impl ($50K+); bug bounty; impl is immutable post-deploy |
| Salt mining incorrectness → bad flag bits | 🔴 High | Factory validates `Hooks.isValidHookAddress` post-clone; tests on deploy script |
| Init race on `setupLaunch` (between clone & init) | 🟡 Medium | Atomic factory call (same TX); test with concurrent attempts |
| Governance NFT lost/burned mid-launch | 🟡 Medium | Hook blocks burn in Phase 1 via `_beforeRemoveLiquidity` |
| AA wallets break `tx.origin` checks | 🟡 Medium | ECDSA signature pattern as primary check |
| Tax logic gas cost makes small swaps uneconomical | 🟡 Medium | Optimize gas; consider waiver for swaps below threshold |
| EIP-1167 delegatecall overhead on Mainnet | 🟢 Low | ~$0.02 per swap at 30 gwei; acceptable for launches |
| Salt = tokenId convention assumption wrong | 🟡 Medium | Verify in PosM source pre-coding; fallback via subscribe |
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
forge test --match-path ./test/TokenLaunchHook*.t.sol -vv
```

**Factory & proxy tests:**
- `test_factory_deploysProxyWithCorrectFlagBits` — clone'd address has expected permission bits
- `test_factory_atomicCloneAndSetup_noRaceWindow` — `setupLaunch` cannot be called by anyone else
- `test_factory_setupLaunchTwice_reverts` — double-init protection works
- `test_proxy_delegatecallReadsCorrectState` — storage isolation between proxies
- `test_proxy_immutablePoolManagerReadsFromImpl` — `poolManager` consistent across proxies

**Mechanism tests:**
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

**Governance tests:**
- `test_governance_capturedOnFirstAddLiquidity` — first LP's NFT becomes gov
- `test_governance_wrongFirstLP_reverts` — sniper bot can't capture
- `test_governance_setBuyTax_byOwner_succeeds` — NFT owner can adjust
- `test_governance_setBuyTax_byNonOwner_reverts` — others cannot
- `test_governance_setBuyTax_increaseRejected` — monotone constraint
- `test_governance_extendUnlock_succeeds` — extension allowed
- `test_governance_shortenUnlock_reverts` — shortening forbidden
- `test_governance_NFT_transferGivesNewOwnerControl` — transferability works
- `test_governance_NFT_burnDuringLaunch_reverts` — Phase 1 burn-block
- `test_governance_NFT_burnAfterLaunch_succeeds` — Phase 2 unblocks burn
- `test_governance_postLaunchEnd_settersRevert` — frozen Phase 2

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

1. **Verify `salt = bytes32(tokenId)` convention in V4 PositionManager** — read source, confirm. If different, design subscribe-based capture fallback. *Highest priority before coding.*

2. **Choose anti-sniper auth: ECDSA signature vs `tx.origin`** — which is feasible given target wallet ecosystem? Test with Safe and standard EOA.

3. **Mining tool**: which library/method for off-chain CREATE2 salt mining? Foundry has `vm.computeCreate2Address`. Need to integrate into `script/MineSalt.s.sol` and verify gas/time on commodity hardware.

4. **Permission flag bits for impl vs proxies**: confirm they MUST match (same flag pattern for both). What if we want different permissions per launch type? → would need multiple impl deployments per chain.

5. **Storage layout safety**: ensure no struct packing changes break per-proxy storage. Use explicit slot constants for critical fields.

6. **Cross-chain deploy**: deploy impl + factory once per chain — straightforward. But how to synchronize launches across chains atomically if a token is multi-chain? Postpone to v2.

7. **Sandwich resistance for dynamic tax**: tax changing within block can be exploited; add commit-reveal or rate limiting?

8. **Integration with existing launchpads**: partnership with PinkSale (they integrate our hook as backend) vs competition?

9. **Branding / positioning**: "Fair Launch Infrastructure" vs "Memecoin Pump Tool" — drastically different audiences and risk profiles.

10. **EIP-3448 MetaProxy upgrade** for v2: bake config into proxy bytecode, eliminate `setupLaunch` race entirely. Worth the migration cost?
