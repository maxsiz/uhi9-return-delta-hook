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

## Deployment Architecture: Single Hook + CampaignWrapper

> **Why not Factory + EIP-1167?** Uniswap support confirmed: hooks with custom-accounting permissions (`*ReturnDelta`) require **manual allowlisting per hook address**. EIP-1167 would generate a new hook address per launch → each launch waiting weeks for Uniswap approval = unworkable UX. Solution: **one shared hook address per chain, allowlisted once**, with all per-launch state in a `mapping(PoolId => CampaignState)`.

### Two-contract pattern

Two non-upgradeable contracts per chain:

1. **`TokenLaunchHook`** — single hook contract, attached as `key.hooks` for every launch. Manages all per-pool state internally via mapping. Submitted to Uniswap allowlist **once**.

2. **`CampaignWrapper`** — coordinator that takes the full campaign params in **one function call** and atomically deploys everything via `PositionManager.multicall`. Stateless except optional token-deploy factory inside.

A launch happens through the wrapper from our custom Web3 UI (single TX, single signature).

### Component diagram

```
        ┌────────────────────────────────────────────────────────┐
        │  Our Web3 UI (static frontend, e.g. Vercel)            │
        │  • Form: token config, launch params, recipient        │
        │  • Wallet connect (RainbowKit/Wagmi)                   │
        │  • Build & sign ONE TX → CampaignWrapper               │
        └────────────────────────┬───────────────────────────────┘
                                 │ one TX
                                 ▼
        ┌────────────────────────────────────────────────────────┐
        │  CampaignWrapper  (deploy once per chain, immutable)   │
        │  • launchCampaign(params, permitData) atomic:          │
        │    1. (optional) deploy ERC-20 token via TokenFactory  │
        │    2. build PoolKey                                    │
        │    3. encode hookData = abi.encode(LaunchConfig)       │
        │    4. PositionManager.multicall([                      │
        │         initializePool(key, sqrtPrice),                │
        │         modifyLiquidities([MINT_POSITION, ...]         │
        │           with hookData & recipient = params.lpRecipient│
        │         )                                              │
        │       ])                                                │
        │    5. verify hook captured governance NFT              │
        │    6. emit CampaignLaunched                            │
        │  NON-UPGRADEABLE — new version = new deploy + migrate  │
        └────────────────────────┬───────────────────────────────┘
                                 │ atomic multicall
                                 ▼
        ┌────────────────────────────────────────────────────────┐
        │  PositionManager (v4-periphery, canonical)             │
        │  • initializePool(key, sqrtPrice)                      │
        │  • modifyLiquidities(actions, deadline)                │
        └────────────────────────┬───────────────────────────────┘
                                 │ both ops trigger callbacks
                                 ▼
        ┌────────────────────────────────────────────────────────┐
        │  TokenLaunchHook  (deploy once per chain, immutable)   │
        │  • inherits BaseHook (UNCHANGED)                       │
        │  • Storage: mapping(PoolId => CampaignState) campaigns │
        │  • _beforeInitialize: noop (just selector)             │
        │  • _beforeAddLiquidity: on FIRST mint per pool         │
        │       - decode LaunchConfig from hookData              │
        │       - verify expectedFirstLP                         │
        │       - capture governance NFT (salt = tokenId)        │
        │       - store campaign state                           │
        │  • _beforeAddLiquidity: subsequent — apply rules       │
        │  • _beforeSwap: anti-snipe + dynamic tax fee           │
        │  • _afterSwap: tax distribution + volume tracking      │
        │  • _beforeRemoveLiquidity: lock & gov NFT protection   │
        │  • Governance setters (per-PoolId, gated by NFT owner) │
        │  ↓ Submitted to Uniswap allowlist ONCE                 │
        └─────────────────────┬──────────────────────────────────┘
                              │ all launches share this address
                  ┌───────────┼───────────┬───────────┐
                  ▼           ▼           ▼           ▼
              ┌───────┐   ┌───────┐   ┌───────┐   ┌───────┐
              │Pool A │   │Pool B │   │Pool C │   │ ...   │
              │launch_A   │launch_B   │launch_C   │       │
              └───────┘   └───────┘   └───────┘   └───────┘
```

### CampaignWrapper — skeleton

```solidity
contract CampaignWrapper {
    IPositionManager public immutable POSM;
    TokenLaunchHook public immutable HOOK;
    TokenFactory public immutable TOKEN_FACTORY;  // optional minimal-proxy factory
    
    struct CampaignParams {
        // Token side — DEPLOY NEW OR USE EXISTING
        address existingToken;          // if 0 → deploy new via TokenFactory
        TokenDeployConfig tokenConfig;  // for new token (name, symbol, supply, etc.)
        
        // Pool side
        address pairToken;              // typically WETH or 0 (native ETH)
        uint24 fee;                     // dynamic-fee flag (0x800000) recommended
        int24 tickSpacing;              // 60 typical
        uint160 sqrtPriceInit;
        
        // First mint (deployer's seed LP, becomes governance NFT)
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        address lpRecipient;            // ← WHO RECEIVES THE GOV NFT (per user choice)
        
        // Launch config (encoded into hookData)
        LaunchConfig launchConfig;
    }
    
    function launchCampaign(
        CampaignParams calldata params,
        bytes calldata permitData  // Permit2 sig for ERC-20 transfers
    ) external payable returns (PoolKey memory key, uint256 governanceTokenId) {
        // 1. Token side: deploy or use existing
        address tokenAddr = params.existingToken != address(0)
            ? params.existingToken
            : TOKEN_FACTORY.deployToken(params.tokenConfig, params.lpRecipient);
        
        // 2. Build PoolKey (sort by address per V4 convention)
        (address curr0, address curr1) = _sortTokens(tokenAddr, params.pairToken);
        key = PoolKey({
            currency0: Currency.wrap(curr0),
            currency1: Currency.wrap(curr1),
            fee: params.fee,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(address(HOOK))
        });
        
        // 3. Inject deployer + initial price into launchConfig (for hook anti-sandwich)
        LaunchConfig memory cfg = params.launchConfig;
        cfg.deployer = msg.sender;
        cfg.expectedInitialSqrtPrice = params.sqrtPriceInit;
        cfg.tokenAddress = tokenAddr;
        
        // 4. Build atomic multicall
        bytes memory hookData = abi.encode(cfg);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            IPoolInitializer_v4.initializePool, 
            (key, params.sqrtPriceInit)
        );
        calls[1] = abi.encodeCall(
            IPositionManager.modifyLiquidities, 
            (_encodeMintActions(key, params, hookData), block.timestamp + 60)
        );
        
        // 5. Atomic execute (Permit2 approvals are pre-signed via permitData)
        POSM.multicall{value: msg.value}(calls);
        
        // 6. Verify hook captured everything correctly
        governanceTokenId = HOOK.governanceTokenIdOf(key.toId());
        require(governanceTokenId != 0, "Capture failed");
        require(
            IERC721(address(POSM)).ownerOf(governanceTokenId) == params.lpRecipient,
            "NFT not delivered"
        );
        
        emit CampaignLaunched(key, governanceTokenId, msg.sender, params.lpRecipient, cfg);
    }
    
    // ... helper encoding functions
}
```

### TokenLaunchHook — skeleton (single-contract, mapping-based)

```solidity
contract TokenLaunchHook is BaseHook {
    mapping(PoolId => CampaignState) public campaigns;
    address public immutable POSITION_MANAGER;
    
    struct CampaignState {
        LaunchConfig config;            // includes deployer, taxes, lock, etc.
        uint256 governanceTokenId;      // 0 until first-mint captures it
        uint256 cumulativeVolume;
        uint32 uniqueHolders;
        bool initialized;
    }
    
    constructor(IPoolManager _pm, address _posm) BaseHook(_pm) {
        POSITION_MANAGER = _posm;
    }
    
    function _beforeInitialize(address, PoolKey calldata, uint160) 
        internal pure override returns (bytes4) 
    {
        // Blank pool — config will arrive via hookData on first mint
        return this.beforeInitialize.selector;
    }
    
    function _beforeAddLiquidity(
        address sender, 
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        PoolId pid = key.toId();
        CampaignState storage state = campaigns[pid];
        
        if (!state.initialized) {
            // FIRST mint per pool — bootstrap the campaign
            require(sender == POSITION_MANAGER, "Must mint via PosM");
            
            LaunchConfig memory cfg = abi.decode(hookData, (LaunchConfig));
            
            // Verify pool was just initialized at expected price (anti-griefing)
            (uint160 sqrtPriceNow,,,) = poolManager.getSlot0(pid);
            require(sqrtPriceNow == cfg.expectedInitialSqrtPrice, "Wrong init price");
            
            // Anti-sandwich: only deployer (or his AA wallet) can do first mint
            require(tx.origin == cfg.deployer, "Wrong first LP");
            
            // Capture governance NFT via salt = bytes32(tokenId) convention (verified in PosM)
            state.config = cfg;
            state.governanceTokenId = uint256(params.salt);
            state.initialized = true;
            
            emit CampaignBootstrapped(pid, cfg.deployer, state.governanceTokenId);
        } else {
            // Subsequent mints — apply campaign rules (anti-snipe, whitelist, etc.)
            _applyAddLiquidityRules(state, sender, params);
        }
        
        return this.beforeAddLiquidity.selector;
    }
    
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        CampaignState storage state = campaigns[key.toId()];
        return _processSwap(state, sender, params);  // applies anti-snipe + dynamic tax
    }
    
    // ... afterSwap, beforeRemoveLiquidity, governance setters
    
    // Governance setters keyed by PoolId
    modifier onlyGovernance(PoolId pid) {
        CampaignState storage state = campaigns[pid];
        require(state.governanceTokenId != 0, "Not initialized");
        require(block.timestamp < state.config.launchEndTime, "Launch ended");
        require(
            IERC721(POSITION_MANAGER).ownerOf(state.governanceTokenId) == msg.sender,
            "Not governance NFT owner"
        );
        _;
    }
    
    function setBuyTax(PoolId pid, uint16 newBps) external onlyGovernance(pid) {
        CampaignState storage state = campaigns[pid];
        require(newBps <= state.config.buyTaxBps, "Can only decrease");
        state.config.buyTaxBps = newBps;
    }
    
    function governanceTokenIdOf(PoolId pid) external view returns (uint256) {
        return campaigns[pid].governanceTokenId;
    }
    
    // ... more setters per Mutability matrix
}
```

### TokenFactory — optional minimal-proxy factory

For deployers who don't have their own ERC-20 yet, the wrapper can deploy a standard token via a separate factory using EIP-1167 minimal proxies for cheap deploys. This is **independent of the hook** — token cloning doesn't have hook-allowlist concerns since the token contract is standard ERC-20.

```solidity
contract TokenFactory {
    address public immutable TOKEN_IMPLEMENTATION;  // standard ERC-20 mintable
    
    function deployToken(TokenDeployConfig calldata cfg, address recipient) 
        external returns (address token) 
    {
        token = Clones.clone(TOKEN_IMPLEMENTATION);
        StandardToken(token).initialize(
            cfg.name, cfg.symbol, cfg.totalSupply, 
            recipient                       // initial supply goes to recipient
        );
        emit TokenDeployed(token, recipient, cfg);
    }
}
```

This is **opt-in**. If deployer brings existing ERC-20, this path is skipped. The EIP-1167 minimal-proxy pattern here is purely for ERC-20 deploy cost reduction — has nothing to do with hook architecture.

### Atomic launch flow (full TX)

```
User on our-launch.example.com fills form, clicks "Launch", signs ONE TX:

CampaignWrapper.launchCampaign(params, permitSig)
  │
  ├─ Optional: TokenFactory.deployToken(...)         ← if new token requested
  │
  ├─ POSM.multicall([
  │   initializePool(key, sqrtPriceInit)
  │     └─ TokenLaunchHook._beforeInitialize ← noop
  │   modifyLiquidities([MINT_POSITION, SETTLE_PAIR, SWEEP])
  │     └─ poolManager.modifyLiquidity
  │         └─ TokenLaunchHook._beforeAddLiquidity
  │             ├─ require tx.origin == cfg.deployer
  │             ├─ require sqrtPriceNow == cfg.expectedInitialSqrtPrice
  │             ├─ campaigns[poolId] = state with config
  │             └─ governanceTokenId = uint256(params.salt)
  │         └─ poolManager mints liquidity, returns delta
  │     └─ PosM mints LP NFT to params.lpRecipient ← user-specified
  │     └─ SETTLE_PAIR pulls tokens from msg.sender (via Permit2)
  │     └─ SWEEP returns any dust to user
  ])
  │
  ├─ assert HOOK.governanceTokenIdOf(poolId) != 0
  ├─ assert PosM.ownerOf(govTokenId) == params.lpRecipient
  └─ emit CampaignLaunched
```

**Race window: 0 blocks.** Everything atomic.

### Multi-chain deployment

Per chain (Mainnet, Unichain, Base, Arbitrum), deploy:
1. `TokenLaunchHook` (mine CREATE2 salt for permission flag bits; ~1.5M gas)
2. `CampaignWrapper` (regular deploy; ~500K gas)
3. `TokenFactory` + `StandardToken` impl (regular deploy; ~1M gas total)

**Total per-chain setup cost:** ~$50-200 on Mainnet (one-time), few cents on L2s.

**After setup:** every new launch costs only the storage-write gas in `_beforeAddLiquidity` plus the standard `MINT_POSITION` cost — no extra contract deploys.

### Allowlist strategy

1. **Submit `TokenLaunchHook` address for Uniswap allowlist** (the only hook address ever used)
2. While waiting, all launches still work — pool creation goes through `CampaignWrapper` directly, not Uniswap UI
3. Once allowlisted: trades through Uniswap UI route to our pools automatically — no per-launch friction
4. Until allowlisted: traders use **1inch, 0x, ParaSwap** (aggregators don't require Uniswap allowlist), or our own swap UI

Allowlist is a **nice-to-have, not a blocker**. See "Fallback Distribution Strategy" below.

### Why non-upgradeable

`CampaignWrapper` and `TokenLaunchHook` are both deployed **without admin / proxy / upgrade mechanism**. If we need a new version:
- Deploy `CampaignWrapper_v2` at new address; UI swaps to it
- Deploy `TokenLaunchHook_v2`; submit new allowlist application; future launches use it
- Old `_v1` keeps running for existing launches forever (no forced migration)

This eliminates:
- Admin key risk
- Proxy upgrade exploits
- Storage-collision bugs from upgrades
- Trust issues for users ("can the deployer drain my pool?")

The price: a hook bug found post-deploy means migrate-or-live-with-it. Mitigated via thorough audit + bug bounty pre-launch.

## Modular Mechanism Architecture

Inside `TokenLaunchHook`, individual launch mechanics (anti-snipe, tax, liquidity-lock, whitelist, etc.) are isolated as **abstract Solidity contracts** ("mechanism modules"). The main hook inherits the modules it supports; **per-launch config** specifies which are active.

### Pattern: Abstract inheritance + enable flags

```solidity
// ─── Each mechanism is a separate abstract contract ───

abstract contract AntiSnipeMechanism {
    struct AntiSnipeConfig { /* immutable + mutable params */ }
    struct AntiSnipeState  { /* runtime tracking */ }
    
    mapping(PoolId => AntiSnipeConfig) internal _antiSnipeConfigs;
    mapping(PoolId => AntiSnipeState)  internal _antiSnipeStates;
    
    function _initAntiSnipe(PoolId pid, bytes calldata data) internal { ... }
    function _checkAntiSnipe(PoolId pid, address trader, uint256 amount, bool isBuy) 
        internal returns (bool) { ... }
    
    // governance setter for mutable params
    function setAntiSnipeMaxBuy(PoolId pid, uint16 newBps) external virtual;
    
    event AntiSnipeInitialized(PoolId indexed pid, AntiSnipeConfig cfg);
    event AntiSnipeRejected(PoolId indexed pid, address indexed trader, string reason);
}

abstract contract BuySellTaxMechanism { /* same pattern */ }
abstract contract LiquidityLockMechanism { /* same pattern */ }
// ... more

// ─── TokenLaunchHook inherits all supported mechanisms ───

contract TokenLaunchHook is
    BaseHook,
    AntiSnipeMechanism,
    BuySellTaxMechanism,
    LiquidityLockMechanism,
    WhitelistPhaseMechanism,
    SniperBlacklistMechanism,
    GovernanceModule
{
    struct EnabledMechanisms {
        bool antiSnipe;
        bool tax;
        bool lock;
        bool whitelist;
        bool sniperBlacklist;
        // future v2: bondingCurve, autoBuyback, treasuryRoute
    }
    
    mapping(PoolId => EnabledMechanisms) public enabled;
    
    // Hook orchestrates which modules to invoke per callback
    function _beforeSwap(...) returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId pid = key.toId();
        EnabledMechanisms memory en = enabled[pid];
        
        if (en.whitelist) {
            require(_isWhitelisted(pid, tx.origin, params), "Not whitelisted");
        }
        if (en.antiSnipe) {
            require(_checkAntiSnipe(pid, tx.origin, _amount(params), _isBuy(params)), "Snipe");
        }
        if (en.sniperBlacklist) {
            require(!_isSniperBlacklisted(pid, tx.origin), "Blacklisted");
        }
        
        uint24 fee = en.tax 
            ? _calculateTax(pid, _isBuy(params), block.timestamp - _launchTime(pid)) 
            : 0;
        
        return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), fee);
    }
    
    function _beforeAddLiquidity(...) returns (bytes4) {
        // bootstrap on first mint — dispatch _init* for each enabled module
    }
    
    function _beforeRemoveLiquidity(...) returns (bytes4) {
        if (enabled[pid].lock) {
            require(_canRemoveLiquidity(pid, params), "Locked");
        }
    }
}
```

### Storage isolation

Each mechanism declares **its own state variables with unique names** — no slot collision under Solidity's default storage layout. Example:

```solidity
abstract contract AntiSnipeMechanism {
    mapping(PoolId => AntiSnipeConfig) internal _antiSnipeConfigs;
    mapping(PoolId => mapping(address => uint64)) internal _lastBuyBlock;
}

abstract contract BuySellTaxMechanism {
    mapping(PoolId => TaxConfig) internal _taxConfigs;
}
// Different storage slots, no conflict.
```

**Future-proofing:** if mechanisms get added/removed across versions, consider ERC-7201 namespaced storage (per-module fixed slot via `keccak256`). Overkill for v1 but recommended for v2+.

### Mechanism module template

Every module follows the same shape for predictability:

```solidity
abstract contract <Name>Mechanism {
    struct <Name>Config { /* immutable + mutable params */ }
    struct <Name>State  { /* runtime tracking */ }
    
    mapping(PoolId => <Name>Config) internal _<name>Configs;
    mapping(PoolId => <Name>State)  internal _<name>States;
    
    // Init (called from _beforeAddLiquidity bootstrap)
    function _init<Name>(PoolId pid, bytes calldata data) internal;
    
    // Predicate/check (called from hook callbacks, modifies state if needed)
    function _<predicate>(PoolId pid, ...) internal returns (bool);
    
    // View functions (external readers)
    function get<Name>Config(PoolId pid) external view returns (<Name>Config memory);
    
    // Governance setters (mutable params, must be virtual + override-able)
    function set<Mutable>(PoolId pid, ...) external virtual;
    
    // Events
    event <Name>Initialized(PoolId indexed pid, <Name>Config cfg);
    event <Name>Rejected(PoolId indexed pid, address indexed who, string reason);
    event <Name>ParamUpdated(PoolId indexed pid, string param, bytes newValue);
}
```

### Why not external plugins / dynamic dispatch

We considered:
- **External plugin contracts** with `IMechanismPlugin` interface — rejected because external calls cost gas, security review per plugin needed, reentrancy concerns.
- **Library pattern** (stateless libs, storage in hook) — rejected because it doesn't give true encapsulation; main hook ends up with all state declarations directly.
- **Solidity Diamond standard (EIP-2535)** — rejected as overkill for non-upgradeable contract.

Abstract inheritance is the **right level of modularity** for our problem: code organization + isolated testing + audit-friendly boundaries, with zero runtime overhead.

### Module catalog (v1 + planned v2)

| ID | Module | Hook permissions used | v1 / v2 | Status |
|----|--------|------------------------|---------|--------|
| **M1** | `AntiSnipeMechanism` | `_beforeSwap` (revert) | **v1** | Mandatory |
| **M2** | `BuySellTaxMechanism` (dynamic LP fee) | `_beforeSwap` (fee override) | **v1** | Mandatory |
| **M3** | `LiquidityLockMechanism` (incl. vesting) | `_beforeRemoveLiquidity` (revert) | **v1** | Mandatory (was M3+M4 merged) |
| **M5** | `WhitelistPhaseMechanism` | `_beforeSwap` + `_beforeAddLiquidity` (revert) | **v1** | Optional per-launch |
| **M10** | `MinHoldTimeMechanism` (anti-flip) | `_beforeSwap` (track + revert) | **v1** | Optional |
| **M12** | `InsiderRulesMechanism` (different tax/lock for whitelisted addresses) | `_beforeSwap` | **v1** | Optional |
| **M13** | `SniperBlacklistMechanism` (block-0 buyer snapshot) | `_afterSwap` (track) + `_beforeSwap` (check) | **v1** | Optional, complements M1 |
| **M14** | `TradeVolumeCapMechanism` (max % per address) | `_beforeSwap` (track + limit) | **v1** | Optional |
| **M8** | `TreasuryFeeRoutingMechanism` | `_afterSwap` + `afterSwapReturnDelta` | **v2** | Requires custom accounting; post-allowlist |
| **M6** | `BondingCurveFallbackMechanism` | `_beforeSwap` + `beforeSwapReturnDelta` | **v2** | Complex math; post-allowlist |
| **M7** | `AutoBuybackMechanism` | `_afterSwap` + atomic swap | **v2** | Defer to v2 |
| **M9** | `HolderCapMechanism` | `_afterSwap` (track) + `_beforeSwap` (limit) | **v2** | Deferred — exact holder counting is gas-expensive on-chain; v2 may use off-chain oracle |
| **M11** | `AutoBurnMechanism` (% of volume) | `_afterSwap` | **v2** | Deferred — interaction with M2 needs design with M8 in scope |

**Merged / dropped:**
- M4 (Vesting) → merged into M3 (LiquidityLock supports vesting schedule as one of its unlock modes)
- ~~M6, M7, M8~~ → deferred to v2 (custom-accounting permissions, more design needed)
- ~~M9, M11~~ → deferred to v2 (M9 gas concerns, M11 cross-module design with M8)

### Per-launch enable flags + presets

Custom UI can offer **presets** that pre-select sensible flag combinations:

| Preset | Enabled mechanisms |
|--------|--------------------|
| **Memecoin** | M1 + M2 + M3 + M13 + M14 |
| **Fair Launch** | M1 + M2 + M3 + M14 |
| **RWA / Permissioned** | M3 + M5 + M12 |
| **DAO Token** | M2 + M3 |
| **Custom** | Full toggle UI for all modules |

Implementation note: `EnabledMechanisms` is set once at bootstrap (in `_beforeAddLiquidity` from hookData). It's part of the immutable config — cannot be changed post-launch. Within enabled modules, **mutable params** are still adjustable by governance NFT owner.

## Critical Files to Create

### Core on-chain contracts (one deploy per chain)

| File | Purpose |
|------|---------|
| `src/TokenLaunchHook.sol` | Main hook. Inherits `BaseHook` **unchanged** + all mechanism modules. Storage: `mapping(PoolId => CampaignState)` + `enabled` flags. Orchestrates module dispatch in callbacks. Submitted to Uniswap allowlist once. |
| `src/CampaignWrapper.sol` | Non-upgradeable coordinator. `launchCampaign(params, permitSig)` does everything atomically via PosM multicall. Optionally invokes TokenFactory. |
| `src/TokenFactory.sol` | Deploys cheap ERC-20 tokens via EIP-1167 minimal proxies. Independent of hook. |
| `src/StandardToken.sol` | Initializable ERC-20 implementation cloned by TokenFactory. |

### Mechanism modules (abstract contracts in `src/mechanisms/`)

| File | Module | Status |
|------|--------|--------|
| `src/mechanisms/GovernanceModule.sol` | Governance NFT capture + setters (common to all) | v1 mandatory |
| `src/mechanisms/AntiSnipeMechanism.sol` | M1 — block-window anti-snipe | v1 mandatory |
| `src/mechanisms/BuySellTaxMechanism.sol` | M2 — asymmetric tax via dynamic LP fee | v1 mandatory |
| `src/mechanisms/LiquidityLockMechanism.sol` | M3 — conditional + vesting unlock | v1 mandatory |
| `src/mechanisms/WhitelistPhaseMechanism.sol` | M5 — phased KYC/allowlist access | v1 optional |
| `src/mechanisms/MinHoldTimeMechanism.sol` | M10 — anti-flip cool-down | v1 optional |
| `src/mechanisms/InsiderRulesMechanism.sol` | M12 — separate rules for whitelisted insiders | v1 optional |
| `src/mechanisms/SniperBlacklistMechanism.sol` | M13 — block-0 buyer blacklist | v1 optional |
| `src/mechanisms/TradeVolumeCapMechanism.sol` | M14 — max % supply per address | v1 optional |
| `src/mechanisms/TreasuryFeeRoutingMechanism.sol` | M8 — fees to treasury via afterSwapReturnDelta | v2 (post-allowlist) |
| `src/mechanisms/BondingCurveMechanism.sol` | M6 — fallback for thin-liquidity launches | v2 |
| `src/mechanisms/AutoBuybackMechanism.sol` | M7 — atomic counter-buy on sell pressure | v2 |
| `src/mechanisms/HolderCapMechanism.sol` | M9 — max-N-holders enforcement | v2 (deferred) |
| `src/mechanisms/AutoBurnMechanism.sol` | M11 — % of volume burned | v2 (deferred) |

Each mechanism file is a self-contained abstract contract following the [module template](#mechanism-module-template). One test file per module: `test/mechanisms/<Name>Mechanism.t.sol`.

### Libraries

| File | Purpose |
|------|---------|
| `src/lib/LaunchMath.sol` | Tax decay curves, time math (pure library shared across modules) |
| `src/lib/UnlockConditions.sol` | Unlock condition predicates (time, volume, holders, price) |
| `src/lib/MechanismConfig.sol` | Encoding/decoding helpers for hookData → per-module configs |

### Deploy scripts

| File | Purpose |
|------|---------|
| `script/MineSalt.s.sol` | Off-chain Foundry helper to compute CREATE2 salt for `TokenLaunchHook` address (correct permission flag bits) |
| `script/DeployStack.s.sol` | One-time per-chain deploy: mine salt → deploy hook → deploy wrapper → deploy factory → deploy token impl |

### Off-chain components

| Component | Purpose |
|-----------|---------|
| `web/` (static frontend) | Vercel-hosted Web3 UI. Form for campaign params + preset selector. Wallet connect via RainbowKit. Builds and signs single TX to `CampaignWrapper`. |
| `web/lib/launchURL.ts` | URL builder for deep-linking + sharing on Twitter/Telegram |
| `web/lib/presets.ts` | Pre-baked enable-flag combinations: Memecoin / Fair Launch / RWA / DAO / Custom |
| (optional) `keeper/` | Auto-harvest for tax distribution (v2 / post-allowlist) — Cloudflare Workers bot |

### Tests

| File | Purpose |
|------|---------|
| `test/CampaignWrapper.t.sol` | Atomic launch flow, edge cases (existing token vs new, native ETH vs ERC-20 pair) |
| `test/TokenLaunchHook.integration.t.sol` | End-to-end: deploy + launch via wrapper + multi-mechanism interaction |
| `test/TokenLaunchHook.governance.t.sol` | Governance NFT capture, mutability constraints, lifecycle phases |
| `test/TokenLaunchHook.race.t.sol` | Anti-sandwich resistance (try to mint first as attacker) |
| `test/mechanisms/AntiSnipeMechanism.t.sol` | Unit tests for M1 in isolation (mock hook fixture) |
| `test/mechanisms/BuySellTaxMechanism.t.sol` | Unit tests for M2 |
| `test/mechanisms/LiquidityLockMechanism.t.sol` | Unit tests for M3 |
| `test/mechanisms/*.t.sol` | One file per mechanism for isolated unit testing |
| `test/TokenFactory.t.sol` | Token deploy via clones, initialization correctness |
| `test/TokenLaunchHook.fork.t.sol` | Mainnet fork tests against real PoolManager/PosM |

## Mechanisms — Design Specs

> **Status:** the specs below are the **initial draft** captured before the modular-architecture refactor. Each mechanism will be **re-spec'd individually** in upcoming sessions to:
> - Lock down exact storage layout (`<Name>Config` / `<Name>State` structs)
> - Decide v1 vs v2 placement (some may be deferred or merged)
> - Define module interface (init, predicates, governance setters, events)
> - Capture variants and open questions
>
> See [Module catalog](#module-catalog-v1--planned-v2) for the current set with their v1/v2 designation. Refactor will follow the [Mechanism module template](#mechanism-module-template) shape.

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

## Governance: First-Position NFT Pattern (per-PoolId)

Each launch needs **ongoing parameter management** (decay tax rates, extend lock time, etc.). To avoid centralized admin keys, governance is bound to the **NFT of the first position** in each pool. Whoever owns that NFT controls **that launch's** parameters within bounded scope.

Since one `TokenLaunchHook` serves many pools, governance state is **per-PoolId** in storage:

```solidity
struct CampaignState {
    LaunchConfig config;
    uint256 governanceTokenId;
    uint256 cumulativeVolume;
    uint32 uniqueHolders;
    bool initialized;
}

mapping(PoolId => CampaignState) public campaigns;

struct LaunchConfig {
    // — Immutable (set at first-mint bootstrap) —
    address deployer;                  // who launched (msg.sender of CampaignWrapper)
    address tokenAddress;
    uint160 expectedInitialSqrtPrice;
    uint64 launchTime;
    uint64 launchEndTime;              // governance freeze time
    uint32 antiSnipeBlocks;
    uint16 maxBuyBpsPerBlock;
    // — Mutable by governance NFT owner (bounded) —
    uint16 buyTaxBps;
    uint16 sellTaxBps;
    uint16 baseTaxBps;
    uint32 taxDecayPeriod;
    UnlockMode unlockMode;
    uint256 unlockTime;
    uint256 unlockVolumeThreshold;
    uint32 unlockHolderThreshold;
    // ... etc
}
```

### Capture flow

Because pool initialization doesn't accept hookData, all setup happens at the **first add-liquidity** call. `CampaignWrapper`'s atomic multicall ensures init and first-mint are in the same TX → no race window.

```solidity
function _beforeInitialize(address, PoolKey calldata, uint160) 
    internal pure override returns (bytes4) 
{
    // Blank — wait for hookData on first mint
    return this.beforeInitialize.selector;
}

function _beforeAddLiquidity(
    address sender, 
    PoolKey calldata key,
    ModifyLiquidityParams calldata params,
    bytes calldata hookData
) internal override returns (bytes4) {
    PoolId pid = key.toId();
    CampaignState storage state = campaigns[pid];
    
    if (!state.initialized) {
        // FIRST mint — bootstrap campaign
        require(sender == POSITION_MANAGER, "Must mint via PositionManager");
        
        LaunchConfig memory cfg = abi.decode(hookData, (LaunchConfig));
        
        // Anti-griefing: verify init price matches what wrapper declared
        (uint160 sqrtNow,,,) = poolManager.getSlot0(pid);
        require(sqrtNow == cfg.expectedInitialSqrtPrice, "Wrong init price");
        
        // Anti-sandwich: only deployer's wallet can do first mint
        require(tx.origin == cfg.deployer, "Wrong first LP");
        
        // Capture governance NFT via salt = bytes32(tokenId) convention (verified in PosM)
        state.config = cfg;
        state.governanceTokenId = uint256(params.salt);
        state.initialized = true;
        
        emit CampaignBootstrapped(pid, cfg.deployer, state.governanceTokenId);
    } else {
        // Subsequent — apply launch rules
        _applyAddLiquidityRules(state, sender, params);
    }
    
    return this.beforeAddLiquidity.selector;
}

modifier onlyGovernance(PoolId pid) {
    CampaignState storage state = campaigns[pid];
    require(state.initialized, "No campaign");
    require(block.timestamp < state.config.launchEndTime, "Launch ended — params frozen");
    require(
        IERC721(POSITION_MANAGER).ownerOf(state.governanceTokenId) == msg.sender,
        "Not governance NFT owner"
    );
    _;
}

function setBuyTax(PoolId pid, uint16 newBps) external onlyGovernance(pid) {
    CampaignState storage state = campaigns[pid];
    require(newBps <= state.config.buyTaxBps, "Can only decrease");
    state.config.buyTaxBps = newBps;
    emit ParamUpdated(pid, "buyTaxBps", newBps);
}

// ... more setters per Mutability matrix
```

### Anti-sandwich protection on first mint

Because the entire launch happens in one atomic `CampaignWrapper.launchCampaign` TX, the race window between init and first-mint is **0 blocks**. But defense in depth:

**Layer A: `tx.origin == cfg.deployer` (basic)**

Simple, works for EOA deployers. Breaks under EIP-7702 / ERC-4337 AA wallets (where `tx.origin` ≠ effective signer).

**Layer B: ECDSA signature in hookData (AA-safe, recommended for v2)**

Deployer signs EIP-712 message off-chain. Submitted via hookData. Hook recovers signer and compares to `cfg.deployer`. Works under any wallet stack.

**Layer C: Atomic multicall via CampaignWrapper**

The primary defense. Wrapper bundles `initializePool + modifyLiquidities` in one TX → no in-flight state for attackers to exploit. `msg.sender` is the wrapper, `tx.origin` is the human deployer.

### Salt = tokenId convention ✅ VERIFIED

Verified in `lib/v4-hooks-public/lib/v4-periphery/src/PositionManager.sol`. **All** liquidity actions pass `salt = bytes32(tokenId)` to `poolManager.modifyLiquidity`:

| Action | PositionManager.sol line | Salt value |
|--------|--------------------------|------------|
| `_mint` (MINT_POSITION) | 379 | `bytes32(tokenId)` |
| `_increase` | 298 | `bytes32(tokenId)` |
| `_decrease` | 343 | `bytes32(tokenId)` |
| `_burn` | 431 | `bytes32(tokenId)` |
| `_increaseFromDeltas` | 326 | `bytes32(tokenId)` |

So `uint256(params.salt)` in our hook callbacks reliably gives the corresponding NFT tokenId. Capture logic works as designed; no fallback mechanisms needed.

**Bonus:** `nextTokenId` is a public state variable on PositionManager — readable off-chain by our Web3 UI before signing TX. Useful for:
- Pre-rendering NFT preview ("your order will be #1247")
- Sandwich-detection (verify `nextTokenId` didn't shift between TX preparation and submission)
- Anti-griefing checks inside `CampaignWrapper`

### LP NFT recipient flexibility

`CampaignParams.lpRecipient` lets the deployer choose who receives the governance NFT:
- Deployer themselves (default)
- A multisig (Safe) for team-controlled launches
- A DAO governance contract for community-controlled launches
- A timelock contract for additional rug-pull protection

The hook only checks **ownership** of the gov NFT — not who minted it. So transferring/holding via any of the above works seamlessly. The recipient address is passed as `recipient` argument inside the `MINT_POSITION` action.

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
| **0: Pre-launch** | Before `CampaignWrapper.launchCampaign` | n/a | n/a |
| **1: Launch active** | `0 → launchEndTime` | NFT owner can adjust mutable params | ❌ Hook blocks burn in `_beforeRemoveLiquidity` |
| **2: Frozen post-launch** | `launchEndTime → ∞` | All setters revert; params frozen | ✅ Can burn freely (becomes normal LP NFT) |
| **3: Governance NFT burned** | After phase 2 burn | Forever frozen | n/a |

In Phase 1, governance NFT cannot be burned even at zero liquidity:

```solidity
function _beforeRemoveLiquidity(
    address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata
) internal override returns (bytes4) {
    PoolId pid = key.toId();
    CampaignState storage state = campaigns[pid];
    if (
        uint256(params.salt) == state.governanceTokenId 
        && block.timestamp < state.config.launchEndTime
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

`CampaignParams.lpRecipient` lets deployer set the initial holder directly at launch — no separate transfer step needed. Common patterns:
- Self (default): `lpRecipient = msg.sender`
- Team multisig: `lpRecipient = <Safe address>`
- Timelock for extra rug protection: `lpRecipient = <Timelock address>`

This makes the governance model **fluid** — projects can professionalize without redeploying the hook.

### Multisig integration (optional v2 feature)

For projects wanting upfront multisig governance without transferring NFT, the hook can support a designated manager per pool:

```solidity
function setManager(PoolId pid, address manager) external onlyGovernance(pid) {
    campaigns[pid].config.manager = manager;
    emit ManagerSet(pid, manager);
}

modifier onlyManagerOrGov(PoolId pid) {
    CampaignState storage state = campaigns[pid];
    if (state.config.manager != address(0) && msg.sender == state.config.manager) { _; return; }
    require(
        IERC721(POSITION_MANAGER).ownerOf(state.governanceTokenId) == msg.sender, 
        "Not authorized"
    );
    _;
}
```

Setters then use `onlyManagerOrGov(pid)` instead of `onlyGovernance(pid)`.

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

- **`BaseHook`** (`lib/v4-hooks-public/src/base/BaseHook.sol`) — standard inheritance, **unchanged**. CREATE2 salt mining for `TokenLaunchHook` deploy address handles permission flag bits.
- **OpenZeppelin `Clones`** (`@openzeppelin/contracts/proxy/Clones.sol`) — battle-tested EIP-1167. Used **only in `TokenFactory`** for cheap ERC-20 deploys (NOT for the hook itself).
- **`Multicall_v4`** in PositionManager — atomic batching of `initializePool + modifyLiquidities`; forwards `msg.value` across calls
- **`Permit2`** approval flow — pre-signed token approval, used inside `CampaignWrapper` for ERC-20 transfers
- **Dynamic fee** via `LPFeeLibrary.DYNAMIC_FEE_FLAG` + per-swap fee in `_beforeSwap` return — pattern from `SelfLPDirect._afterInitialize`
- **`BeforeSwapDelta`** sign conventions — same as in `InternalSwapPool`
- **`CurrencySettler`** — for tax distribution settlement (when allowlist secured + custom accounting enabled)
- **`StateLibrary`** — for reading pool state (slot0, position) inside callbacks
- **`Hooks.isValidHookAddress`** — for verifying mined hook deploy address has correct flag bits

## Open Design Decisions

1. **Tax distribution recipient model:**
   - Option A: hook auto-distributes via `afterSwapReturnDelta` (atomic but more gas + custom-accounting permission)
   - Option B: tax goes to LP holders proportionally via dynamic fee (standard permission, simpler)
   - Option C: hook accrues, separate `harvest()` keeper batches distribution
   - **Recommendation: B for v1 if avoiding allowlist. A or C for v2 once allowlisted.**

2. **Holder counting:**
   - Exact count requires event indexing → off-chain
   - Approximate via Bloom filter → on-chain but lossy
   - Token contract's `balanceOf` snapshot → expensive
   - **Recommendation: external `IHolderCounter` interface; projects can wire to subgraph or oracle.**

3. **Anti-sandwich auth: `tx.origin` vs ECDSA signature:**
   - `tx.origin` simple, works for EOA, breaks under EIP-7702 / ERC-4337 AA
   - ECDSA signature in hookData works under any wallet
   - **Recommendation: `tx.origin` for v1 (most launchers use Metamask EOA); ECDSA for v2.**

4. **First-LP capture: `salt = tokenId` convention** ✅ RESOLVED
   - **Verified** in PosM source (line 379 for mint, similar for increase/decrease/burn): all liquidity actions pass `salt = bytes32(tokenId)`
   - Hook reads `uint256(params.salt)` to get tokenId — reliable
   - No fallback needed

5. **Multi-position first-LP edge case:**
   - If deployer mints multiple positions in same multicall, which becomes governance?
   - **Recommendation: first by order in multicall (state flag `state.initialized` ensures only first triggers capture).**

6. **Token deploy: inside wrapper or separate?**
   - **A. Inside wrapper** (via `TokenFactory` minimal proxy): one-stop-shop, atomic
   - **B. Separate step**: deployer brings existing token
   - **Recommendation: support both via `params.existingToken == 0 ? deploy : use`.** UI defaults to "new" but allows "existing".

7. **Composability with subscribe:**
   - Project's LP NFT could subscribe to LaunchHook for analytics
   - Hook can emit standardized "Volume / Holders / Phase" events
   - **Recommendation: yes, support subscribe in v2 once base mechanism stable.**

8. **Bonding curve activation logic:**
   - Always-on hybrid? Or only when liquidity below threshold?
   - Requires `beforeSwapReturnDelta` → custom-accounting → allowlist
   - **Recommendation: drop from v1; v2 after allowlist secured.**

9. **Per-launch configurability vs preset templates:**
   - Full config = power but complex UX
   - Templates ("memecoin", "RWA-token", "DAO-token", "fair-launch") = simple UX but limiting
   - **Recommendation: templates with override params in our UI.**

10. **Multisig governance vs NFT-only governance:**
    - NFT-only: simpler, transferable, default
    - Multisig manager: more professional for serious launches
    - **Recommendation: NFT-only for v1 + `lpRecipient` flexibility (deployer can specify multisig as recipient); add `setManager` for v2.**

11. **Custom accounting (`*ReturnDelta`) — include or exclude?** ✅ **DECIDED: include (strategy β)**
    - Deploy `TokenLaunchHook` with **full permission set up-front** including `beforeSwapReturnDelta` + `afterSwapReturnDelta`
    - One audit cycle, one Uniswap allowlist application
    - Same hook contract serves both v1 (no ReturnDelta usage) and v2 (M6 bonding curve, M7 auto-buyback, M8 treasury routing) features
    - Trade-off accepted: allowlist wait (4-12 weeks) before pool routes via Uniswap UI. Ship via [Fallback Distribution Strategy](#fallback-distribution-strategy) (Phase A — aggregators + own UI) until approval.

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| **Uniswap allowlist rejection or long delay** | 🔴 **CRITICAL** | Use fallback distribution (aggregators + own swap UI) until approved; build product NOT dependent on Uniswap UI |
| Reputation: memecoin scams use our hook | 🔴 High | Position as "fair launch infra"; vet projects via opt-in audit |
| Regulatory: ICO-like mechanisms = securities | 🔴 High | Geofence US users on frontend; legal review of templates |
| MEV: sniper bots adapt to our anti-snipe | 🟡 Medium | Continuous iteration; collaborative testing with searchers |
| Hook contract bug → ALL launches affected (blast radius) | 🔴 High | Single hook = one comprehensive audit (~$130K for full ReturnDelta scope); bug bounty pre-launch; hook is immutable post-deploy |
| Wrapper bug breaks new launches | 🟡 Medium | Old launches still work (only `_beforeAddLiquidity` runs through hook). Deploy new wrapper version, UI updates |
| Salt mining incorrectness for hook → bad flag bits | 🟡 Medium | Deploy script validates `Hooks.isValidHookAddress` post-deploy |
| Init race in multi-step deploy (before atomic multicall) | 🟢 Low | `CampaignWrapper` uses atomic multicall — race window = 0 |
| Governance NFT lost/burned mid-launch | 🟡 Medium | Hook blocks burn in Phase 1 via `_beforeRemoveLiquidity` |
| AA wallets break `tx.origin` checks | 🟡 Medium | ECDSA signature pattern in v2; document v1 limitation |
| Tax logic gas cost makes small swaps uneconomical | 🟡 Medium | Optimize gas; consider waiver for swaps below threshold |
| `salt = tokenId` convention assumption wrong | 🟢 Low | **VERIFIED in PosM source** (lines 298/343/379/431 — all use `bytes32(tokenId)`); risk only if PosM updates this convention in future release |
| `tx.origin == cfg.deployer` fails if deployer uses Safe | 🟡 Medium | Detect at wrapper level; offer ECDSA path or warn user |
| Cross-pool storage contamination if PoolId computed wrong | 🟡 Medium | Use canonical `key.toId()`; test edge cases |
| Competition from PinkSale/DxSale moves to V4 | 🟡 Medium | First-mover advantage; better tech moat |

## Fallback Distribution Strategy

Because Uniswap allowlist is uncertain (timing, possible rejection), the product **must not depend on Uniswap UI routing**. Plan:

### Phase A: Pre-allowlist (Day 1)

| Flow | Channel |
|------|---------|
| **Launch (create pool + first LP)** | Our custom Web3 UI → `CampaignWrapper` — no Uniswap UI needed |
| **Swap** for retail users | Aggregators (1inch, 0x, ParaSwap) automatically pick up V4 pools regardless of allowlist; also our own minimal swap UI |
| **Add/remove liquidity** (secondary LPs) | Our custom UI (PosM direct interaction); or wait for allowlist |
| **Discovery** | Our launch directory + Twitter / Telegram sharing; URL deep-links |

**Our UI does all the work.** Uniswap UI becomes optional.

### Phase B: Post-allowlist (after Uniswap approves)

| Flow | Channel |
|------|---------|
| Launch | Our UI (unchanged — UI superior for launch params) |
| Swap | Uniswap UI (primary) + aggregators (continued) + our UI (fallback) |
| Add/remove liquidity | Uniswap UI primary; our UI optional |
| Discovery | Uniswap UI shows our pools; our directory remains |

### Phase B alternative: Uniswap rejection

If allowlist denied:
- Continue with Phase A indefinitely
- Aggregators are the primary routing layer for traders
- We retain control of launch UX
- Many memecoin launchpads (Pump.fun on Solana, etc.) operate this way successfully

Either outcome — **product works**. Allowlist is a nice-to-have, not load-bearing.

### What we control vs what depends on Uniswap

| Component | Controlled by us | Depends on Uniswap |
|-----------|-------------------|----------------------|
| `CampaignWrapper` contract | ✅ | ❌ |
| `TokenLaunchHook` contract logic | ✅ | ❌ (just contract code) |
| Pool creation | ✅ (via PosM, public API) | ❌ |
| Hook permissions allowlist | ❌ | ✅ |
| Uniswap UI routing visibility | ❌ | ✅ |
| Aggregator support | ❌ | Each aggregator independently |
| Our launch UI | ✅ | ❌ |
| Our swap fallback UI | ✅ | ❌ |

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
- Dynamic re-configuration (config locked post-launch except via governance NFT)
- IDO-style price discovery auctions (consider for v2)
- Vesting cliff schedules for project team (deploy separate vesting contract; pass as `lpRecipient`)
- Token mechanics beyond standard ERC-20 (taxable transfer, blacklist, etc.) — use existingToken path
- Cross-pool atomic operations (e.g., multi-token launches)

## Roadmap

| Phase | Duration | Deliverable |
|-------|----------|-------------|
| **Pre-coding research** | 1 week | ~~Verify salt convention~~ ✅; salt mining feasibility; Uniswap allowlist process |
| **Architectural spec lock** | 1 week | Modular structure agreed; main hook skeleton + module template proven |
| **Per-mechanism specs** | 2-3 weeks | Iterative deep-dive on each v1 module (Governance, M1, M2, M3, M5, M10, M12, M13, M14). Each: design doc + interface + open questions resolved |
| **Mandatory modules** (M1-M3) + Governance + Wrapper | 5 weeks | Anti-snipe, tax, lock, governance NFT, atomic launch flow; 90% test coverage |
| **Optional modules** (M5, M10, M12, M13, M14) | 3 weeks | Each module ~3-4 days incl. tests |
| **Token deployment** (TokenFactory + StandardToken) | 1 week | Cheap ERC-20 clones; integration with Wrapper |
| **Web3 UI MVP** | 3 weeks | Static Vercel-hosted; campaign form with presets; wallet connect; deep links |
| **Submit Uniswap allowlist application** | parallel | Submit ASAP after testnet artifact exists — covers full permission set (incl. `*ReturnDelta`); review typically 4-12 weeks |
| **Audit** | 4-6 weeks | External audit of hook + wrapper + factory + each module (~$130K — full permission scope incl. ReturnDelta surfaces); fixes; bug bounty |
| **Testnet launch + beta** | 4 weeks | Base Sepolia + Unichain Sepolia; 3-5 beta launches with friendly projects; use Phase A fallback distribution |
| **Mainnet ship (via Phase A)** | — | Deploy on Base/Unichain first (cheap), Arbitrum (good liquidity), Mainnet last. **Launches operational via aggregators + our UI** even before Uniswap allowlist resolves |
| **Allowlist approval** | TBD (parallel) | Once approved, pools auto-route via Uniswap UI (Phase B) — no contract changes |
| **(v2)** Custom-accounting modules | TBD | M8 (Treasury), M6 (Bonding curve), M7 (Auto-buyback) — code-only additions to existing hook (permissions already enabled) |

**Total to v1 mainnet: ~5-6 months.** Allowlist approval is parallel — product ships via Phase A regardless. Phase B begins automatically when Uniswap approves.

## Open Questions for Future Sessions

### ✅ Resolved

- ~~`salt = bytes32(tokenId)` in V4 PositionManager~~ — verified at `PositionManager.sol` lines 298, 343, 379, 431. All liquidity actions use this convention. `nextTokenId` is publicly readable for off-chain prediction.

- ~~**Hook permission scope**~~ → **Decision: β (Full permission set upfront)**. Deploy `TokenLaunchHook` with all permissions including `beforeSwapReturnDelta` + `afterSwapReturnDelta` from day 1. Trade-off accepted: wait for Uniswap allowlist before pool routing via Uniswap UI; ship via Fallback Distribution (Phase A) until approved. **Reasoning:** single contract serves v1 + v2 features → one audit cycle, one allowlist application, no migration story for existing launches when v2 modules ship. Higher upfront cost (allowlist wait + bigger audit scope) buys long-term operational simplicity.

### 🔴 Critical architectural decisions

1. **Per-module deep-dive specs** — each module in [Module catalog](#module-catalog-v1--planned-v2) requires its own session covering:
   - Storage struct layout (immutable vs mutable fields, slot packing)
   - Callback invocation order (which module runs first when multiple are enabled)
   - Governance setter scope (which params mutable, monotone bounds, who can call)
   - Events for indexer consumption
   - Per-module test fixtures (mock hook for isolated unit tests)

2. **Cross-module interaction rules** — concrete cases to nail down before coding:
   - **Whitelist (M5) + Anti-snipe (M1)**: order in `_beforeSwap`? Likely whitelist first (cheaper revert path).
   - **Insider rules (M12) + Tax (M2)**: does insider rule override the tax decay schedule for whitelisted addresses?
   - **Insider (M12) + Anti-snipe (M1)**: are insiders exempt from anti-snipe limits in block 0?
   - **Trade Volume Cap (M14) + Insider (M12)**: insider addresses exempt from per-address cap?
   - **Sniper blacklist (M13) + Lock (M3)**: blacklisted seller can't sell but tries to remove liquidity — block via `_beforeRemoveLiquidity` too, or allow withdrawal of principal only?
   - **Min Hold Time (M10) + Sniper blacklist (M13)**: do these compose or are they alternative anti-flip strategies?

### 🔵 v2 architectural decisions (post-v1)

3. **AA wallet support** — ECDSA signature pattern (EIP-712) to replace `tx.origin` check for first-LP authentication. Required for Safe / Argent / Biconomy deployers. Decide signing flow: does wrapper recover signature, does hook recover signature, or off-chain ceremony with on-chain nonce?

4. **Sandwich resistance for dynamic tax** (post-allowlist) — fee changing within block can be exploited. Pick approach: commit-reveal scheme? per-block fee freeze? rate limiting? Trade-off between latency and protection.

5. **v2 module rollout strategy** — adding M6/M7/M8 to existing hook is impossible (immutable). Options when v2 modules are ready:
   - Deploy entirely new hook with same permissions + new modules → existing pools stay on old hook
   - Or: design v1 hook with all v2 modules already inherited but disabled via enable flags (only flip on for new launches once Uniswap re-approves) — requires forecasting v2 modules during v1 development

### 📋 Operational / process (not architectural — track separately)

These are **not architectural blockers** but need to be done at the right time in the project lifecycle:

| # | Item | When |
|---|------|------|
| O1 | Allowlist process research — get application form URL from Uniswap support response; identify required materials (code repo, audit report, testnet deployment, technical writeup) | Before submitting application |
| O2 | Submit allowlist application | Once testable artifact exists (mid-development) |
| O3 | Reference PR review — study WETHHook, aggregator hooks PR history in `v4-hooks-public` for clues on review criteria | Anytime before submission |
| O4 | `PositionManager.multicall` behavioral verification — `initializePool + modifyLiquidities` in one call, `msg.value` forwarded, `hookData` propagation | Before wrapper coding |
| O5 | Salt mining benchmark — `vm.computeCreate2Address` time on commodity hardware for permission flag bits | Before deploy script |
| O6 | External audit selection (Spearbit, Trail of Bits, OpenZeppelin, specialized launchpad auditor) | Pre-mainnet |
| O7 | Testnet deployments (Base Sepolia, Unichain Sepolia) + integration testing | After core code + tests |

### Not tracked here (out of scope or already decided)

- Branding / product positioning → product/marketing concern
- UI tech stack → frontend project, separate doc
- Launchpad partnerships → business development
- Token deployment options → decided: strictly minimal ERC-20 via TokenFactory; custom tokens via `existingToken`
- Wrapper failure modes → decided: deploy token only after multicall succeeds (or use try/catch in wrapper)
- `tx.origin` vs ECDSA — decided: `tx.origin` for v1, ECDSA in v2 (see Open Design Decisions)
- EnabledMechanisms storage layout, inheritance ordering — implementation-time details
