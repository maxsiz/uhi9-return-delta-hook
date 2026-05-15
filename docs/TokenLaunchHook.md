# TokenLaunchHook — Coding Spec

> **Status:** Architecture finalized. Ready for implementation.
> v1 scope: 5 modules — GovernanceModule, M1 AntiSnipe, M2 BuySellTax, M3 LiquidityLock (mandatory) + M5 WhitelistPhase (optional).

V4 hook attached to a newly launched token's pool. Enforces fair-launch rules (anti-snipe, dynamic LP fee tax, conditional liquidity lock, whitelist phase) without modifying the ERC-20 token contract. Single hook deployment per chain serves all launches.

## Architecture Overview

Three on-chain components deployed **once per chain**:
- `TokenLaunchHook` — single shared hook, all launches use it
- `CampaignWrapper` — non-upgradeable coordinator; entry point from Web3 UI
- `TokenFactory` (+ `StandardToken` impl) — optional ERC-20 cloner

Per launch (one atomic TX via `CampaignWrapper.launchCampaign`):
1. Optionally deploy ERC-20 via `TokenFactory` (or BYO existing token)
2. `PositionManager.multicall([initializePool, modifyLiquidities([MINT_POSITION])])` with `hookData` carrying module configs
3. Hook's `_beforeAddLiquidity` (first call per pool) decodes hookData, captures governance NFT via `salt = bytes32(tokenId)` convention
4. Subsequent swaps trigger enabled modules: anti-snipe check, dynamic LP fee from tax decay, etc.
5. Governance NFT owner can relax mutable params (lower taxes, shorten lock, add to whitelist)
6. At `launchEndTime`, governance phase freezes; M3 unlock conditions determine when LP can exit

State lives in `mapping(PoolId => ...)` per module — single hook serves many concurrent launches.

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

### Non-upgradeable design

Both `CampaignWrapper` and `TokenLaunchHook` are deployed without admin / proxy / upgrade mechanism. New versions deploy at new addresses; old versions keep running for existing launches. Eliminates admin key risk, proxy upgrade exploits, storage-collision bugs. Hook bugs require migration to new deployment.

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
    GovernanceModule
{
    struct EnabledMechanisms {
        bool antiSnipe;
        bool tax;
        bool lock;
        bool whitelist;
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

### v1 Module catalog

| ID | Module | Hook permissions used | Status |
|----|--------|------------------------|--------|
| **Governance** | `GovernanceModule` | `_beforeAddLiquidity` (bootstrap) + `_beforeRemoveLiquidity` (burn protection) | Mandatory |
| **M1** | `AntiSnipeMechanism` | `_beforeSwap` (revert) | Mandatory |
| **M2** | `BuySellTaxMechanism` (dynamic LP fee) | `_beforeSwap` (fee override) | Mandatory |
| **M3** | `LiquidityLockMechanism` | `_beforeRemoveLiquidity` (revert) + `_afterSwap` (volume tracking) | Mandatory |
| **M5** | `WhitelistPhaseMechanism` | `_beforeSwap` + `_beforeAddLiquidity` (revert) | Optional per-launch |

### Per-launch enable flags + presets

Custom UI can offer **presets** that pre-select sensible flag combinations:

| Preset | Enabled mechanisms |
|--------|--------------------|
| **Memecoin** | M1 + M2 + M3 |
| **Fair Launch** | M1 + M2 + M3 |
| **RWA / Permissioned** | M3 + M5 |
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

| File | Module |
|------|--------|
| `src/mechanisms/GovernanceModule.sol` | Governance NFT capture + onlyGovernance modifier |
| `src/mechanisms/AntiSnipeMechanism.sol` | M1 — time-window anti-snipe |
| `src/mechanisms/BuySellTaxMechanism.sol` | M2 — asymmetric tax via dynamic LP fee |
| `src/mechanisms/LiquidityLockMechanism.sol` | M3 — conditional unlock (time + volume) |
| `src/mechanisms/WhitelistPhaseMechanism.sol` | M5 — phased KYC/allowlist access |

Each mechanism file is a self-contained abstract contract following the [module template](#mechanism-module-template). One test file per module: `test/mechanisms/<Name>Mechanism.t.sol`.

### Libraries

| File | Purpose |
|------|---------|
| `src/lib/LaunchMath.sol` | Tax linear decay formula (pure library used by M2) |
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

## GovernanceModule — Finalized Spec

### Purpose

Cross-cutting infrastructure that:
1. **Captures** the first LP NFT in each pool as the governance NFT (in `_beforeAddLiquidity`)
2. **Provides** `onlyGovernance(pid)` modifier for all other modules' setters
3. **Enforces** lifecycle phases (Pre / Active / Frozen)
4. **Protects** governance NFT from `decreaseLiquidity` and `burn` during active phase

### Storage layout (3 slots per pool)

```solidity
struct GovernanceState {
    // slot 0 (32 bytes)
    uint256 tokenId;                  // captured at first-mint; salt = bytes32(tokenId)
    
    // slot 1 (19 bytes used of 32)
    uint64 launchTime;                // bootstrap timestamp
    uint64 launchEndTime;             // governance freeze deadline (immutable)
    bool   initialized;               // bootstrap flag (per G5: only first mint flips this)
    bool   tokenIsCurrency0;          // orientation: is launched token currency0 in PoolKey?
    
    // slot 2 (20 bytes of 32)
    address deployer;                 // metadata only — not used for authorization (per G2)
}

mapping(PoolId => GovernanceState) internal _governance;
```

`tokenIsCurrency0` is cross-cutting metadata used by other modules (M1 AntiSnipe, M2 BuySellTax, etc.) to determine swap direction (BUY vs SELL of the launched token).

### Bootstrap config (encoded into hookData on first mint)

```solidity
struct GovernanceInitConfig {
    address deployer;            // metadata; set by CampaignWrapper = msg.sender
    uint64  launchDuration;      // seconds; must be in [MIN_DURATION, MAX_DURATION]
    bool    tokenIsCurrency0;    // set by CampaignWrapper based on PoolKey sorting
}
```

Constants:
```solidity
uint64 internal constant MIN_LAUNCH_DURATION = 1 days;
uint64 internal constant MAX_LAUNCH_DURATION = 365 days;
```

### Skeleton

```solidity
abstract contract GovernanceModule {
    address public immutable POSITION_MANAGER;
    mapping(PoolId => GovernanceState) internal _governance;
    
    error NotInitialized();
    error AlreadyInitialized();
    error LaunchEnded();
    error NotGovernanceOwner();
    error MustUsePositionManager();
    error CannotBurnGovernanceNFT();
    error InvalidLaunchDuration();
    
    event CampaignBootstrapped(
        PoolId indexed pid,
        address indexed deployer,
        uint256 governanceTokenId,
        uint64 launchTime,
        uint64 launchEndTime
    );
    
    constructor(address _posm) {
        POSITION_MANAGER = _posm;
    }
    
    modifier onlyGovernance(PoolId pid) {
        GovernanceState storage state = _governance[pid];
        if (!state.initialized) revert NotInitialized();
        if (block.timestamp >= state.launchEndTime) revert LaunchEnded();
        if (IERC721(POSITION_MANAGER).ownerOf(state.tokenId) != msg.sender) {
            revert NotGovernanceOwner();
        }
        _;
    }
    
    // Called from main hook's _beforeAddLiquidity on FIRST mint per pool
    function _initGovernance(
        PoolId pid, 
        ModifyLiquidityParams calldata params,
        GovernanceInitConfig memory cfg,
        address sender
    ) internal {
        GovernanceState storage state = _governance[pid];
        if (state.initialized) revert AlreadyInitialized();
        if (sender != POSITION_MANAGER) revert MustUsePositionManager();
        if (cfg.launchDuration < MIN_LAUNCH_DURATION || cfg.launchDuration > MAX_LAUNCH_DURATION) {
            revert InvalidLaunchDuration();
        }
        
        // Salt = bytes32(tokenId) — verified PosM convention
        state.tokenId = uint256(params.salt);
        state.deployer = cfg.deployer;                  // metadata, no auth
        state.tokenIsCurrency0 = cfg.tokenIsCurrency0;  // orientation for other modules
        state.launchTime = uint64(block.timestamp);
        state.launchEndTime = uint64(block.timestamp) + cfg.launchDuration;
        state.initialized = true;
        
        emit CampaignBootstrapped(
            pid, cfg.deployer, state.tokenId, state.launchTime, state.launchEndTime
        );
    }
    
    // Called from main hook's _beforeRemoveLiquidity (G3: block decrease AND burn)
    function _checkBurnProtection(PoolId pid, ModifyLiquidityParams calldata params) 
        internal view 
    {
        GovernanceState storage state = _governance[pid];
        if (
            state.initialized &&
            uint256(params.salt) == state.tokenId &&
            block.timestamp < state.launchEndTime
        ) {
            revert CannotBurnGovernanceNFT();
        }
    }
    
    // Views
    function governanceTokenIdOf(PoolId pid) external view returns (uint256) {
        return _governance[pid].tokenId;
    }
    
    function governanceOwnerOf(PoolId pid) external view returns (address) {
        GovernanceState storage state = _governance[pid];
        return state.initialized 
            ? IERC721(POSITION_MANAGER).ownerOf(state.tokenId) 
            : address(0);
    }
    
    function launchPhaseOf(PoolId pid) external view returns (uint8) {
        // 0 = Pre-launch, 1 = Active, 2 = Frozen
        GovernanceState storage state = _governance[pid];
        if (!state.initialized) return 0;
        if (block.timestamp < state.launchEndTime) return 1;
        return 2;
    }
}
```

### Integration in main hook callbacks

```solidity
contract TokenLaunchHook is BaseHook, GovernanceModule, /* other modules */ {
    
    function _beforeInitialize(address, PoolKey calldata, uint160) 
        internal pure override returns (bytes4) 
    {
        // No-op: V4 protocol enforces first-init-wins; config arrives via hookData on first mint
        return this.beforeInitialize.selector;
    }
    
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        PoolId pid = key.toId();
        
        if (!_governance[pid].initialized) {
            // First mint — bootstrap (G5: first-by-order)
            (GovernanceInitConfig memory govCfg, /* other module configs */) = 
                abi.decode(hookData, (GovernanceInitConfig /*, ...*/));
            _initGovernance(pid, params, govCfg, sender);
            // ... initialize other enabled modules
        } else {
            // Subsequent mints — apply launch rules from each enabled module
            // ...
        }
        
        return this.beforeAddLiquidity.selector;
    }
    
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId pid = key.toId();
        _checkBurnProtection(pid, params);  // G3
        // ... dispatch to M3 LiquidityLock check for other LP NFTs
        return this.beforeRemoveLiquidity.selector;
    }
}
```

### Test cases (15 tests in `test/mechanisms/GovernanceModule.t.sol`)

```
test_init_bootstrap_capturesGovNFT_emitsEvent
test_init_nonPosM_reverts                          (MustUsePositionManager)
test_init_duplicate_reverts                        (AlreadyInitialized)
test_init_durationTooShort_reverts                 (InvalidLaunchDuration)
test_init_durationTooLong_reverts                  (InvalidLaunchDuration)
test_onlyGovernance_correctOwner_passes
test_onlyGovernance_wrongCaller_reverts            (NotGovernanceOwner)
test_onlyGovernance_uninitialized_reverts          (NotInitialized)
test_onlyGovernance_postLaunchEnd_reverts          (LaunchEnded)
test_onlyGovernance_afterNFTTransfer_newOwnerHasAccess
test_burnProtection_govNFT_inPhase1_reverts        (CannotBurnGovernanceNFT)
test_burnProtection_govNFT_inPhase2_allows
test_burnProtection_nonGovNFT_inPhase1_allows
test_launchPhaseOf_returnsCorrectPhase
test_multiplePositionsFirstMulticall_onlyFirstCapturesGov
```

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

### LP NFT recipient

`CampaignParams.lpRecipient` (passed as `recipient` in `MINT_POSITION` action) determines who receives the governance NFT. Can be deployer EOA, Safe multisig, DAO governance contract, or timelock. The hook only checks NFT ownership, not who minted it.

## M1 AntiSnipeMechanism — Finalized Spec

### Purpose

Prevent sniper bots from grabbing huge portions of token supply in the first N seconds after launch by capping per-TX buy size during a configurable time window. Sells are unrestricted.

### Configuration (1 slot per pool, immutable post-bootstrap)

```solidity
struct AntiSnipeConfig {
    uint32  antiSnipeDuration;     // seconds (0 = disabled), MAX = 1 day
    uint128 maxBuyAmountIn;        // max input per buy TX, in pair-currency wei (0 = effective ban)
    // 32 + 128 = 160 bits = 20 bytes → fits in 1 slot
}

mapping(PoolId => AntiSnipeConfig) internal _antiSnipeConfigs;
// NO runtime state — module is stateless (A6 drop removed per-EOA cooldown)
```

### Constants

```solidity
uint32 internal constant MAX_ANTISNIPE_DURATION = 1 days;
```

### Skeleton

```solidity
abstract contract AntiSnipeMechanism {
    mapping(PoolId => AntiSnipeConfig) internal _antiSnipeConfigs;
    
    error InvalidAntiSnipeDuration();
    error ExactOutNotAllowedDuringAntiSnipe();
    error BuyTooLarge();
    
    event AntiSnipeInitialized(PoolId indexed pid, AntiSnipeConfig cfg);
    
    function _initAntiSnipe(PoolId pid, AntiSnipeConfig memory cfg) internal {
        if (cfg.antiSnipeDuration > MAX_ANTISNIPE_DURATION) revert InvalidAntiSnipeDuration();
        _antiSnipeConfigs[pid] = cfg;
        emit AntiSnipeInitialized(pid, cfg);
    }
    
    /// @notice Called from main hook's _beforeSwap when AntiSnipe is enabled for this pool.
    /// @dev Stateless — no SSTOREs. View-only.
    function _checkAntiSnipe(
        PoolId pid,
        SwapParams calldata params,
        bool tokenIsCurrency0,
        uint64 launchTime
    ) internal view {
        AntiSnipeConfig storage cfg = _antiSnipeConfigs[pid];
        
        // Disabled or window expired → no restrictions
        if (cfg.antiSnipeDuration == 0) return;
        if (block.timestamp >= launchTime + cfg.antiSnipeDuration) return;
        
        // Sells unrestricted during anti-snipe window
        bool isBuy = (params.zeroForOne != tokenIsCurrency0);
        if (!isBuy) return;
        
        // Only exact-in during window (exact-out makes input size unpredictable)
        if (params.amountSpecified > 0) revert ExactOutNotAllowedDuringAntiSnipe();
        
        // Cap on input amount in pair currency
        uint256 amountIn = uint256(-params.amountSpecified);
        if (amountIn > cfg.maxBuyAmountIn) revert BuyTooLarge();
    }
    
    function antiSnipeConfigOf(PoolId pid) external view returns (AntiSnipeConfig memory) {
        return _antiSnipeConfigs[pid];
    }
}
```

### Integration in main hook

```solidity
function _beforeSwap(
    address /*sender*/,
    PoolKey calldata key,
    SwapParams calldata params,
    bytes calldata /*hookData*/
) internal override returns (bytes4, BeforeSwapDelta, uint24) {
    PoolId pid = key.toId();
    EnabledMechanisms memory en = enabled[pid];
    GovernanceState storage gov = _governance[pid];
    
    if (en.antiSnipe) {
        _checkAntiSnipe(pid, params, gov.tokenIsCurrency0, gov.launchTime);
    }
    // ... dispatch to other modules (M5, etc.)
    
    uint24 fee = en.tax ? _calculateTax(pid, params, gov) : 0;
    return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), fee);
}
```

Inside `_beforeAddLiquidity` bootstrap (called from `_initGovernance` flow):
```solidity
if (en.antiSnipe) {
    AntiSnipeConfig memory asCfg = abi.decode(hookData[offsetAntiSnipe:], (AntiSnipeConfig));
    _initAntiSnipe(pid, asCfg);
}
```

### Test cases (8 tests in `test/mechanisms/AntiSnipeMechanism.t.sol`)

```
test_init_storesConfig_emitsEvent
test_init_durationExceedsMax_reverts        (InvalidAntiSnipeDuration)
test_disabled_skipsCheck                     (antiSnipeDuration = 0)
test_buy_withinLimits_passes
test_buy_exceedsMaxAmount_reverts            (BuyTooLarge)
test_buy_exactOut_reverts                    (ExactOutNotAllowedDuringAntiSnipe)
test_sell_unrestricted_duringWindow
test_buy_afterWindowExpires_unrestricted
```

### Edge cases / notes

- **`maxBuyAmountIn = 0`** → effective block-0 ban (every buy attempt fails `amountIn > 0` check). Deployer's lever for strict mode.
- **Window precision**: `block.timestamp` granularity. On L1 ~12s blocks, MAX 1 day → window valid for ~7200 blocks. On L2 sub-second blocks, much finer granularity.
- **`tokenIsCurrency0` semantics**: `zeroForOne != tokenIsCurrency0` returns `true` iff swap is BUY of our launched token. Proof: if `tokenIsCurrency0=true` and `zeroForOne=false`, we're paying currency1 (pair) to receive currency0 (token) → BUY. Matches the XOR formula.
- **No state writes** → zero gas overhead from SSTOREs. Only SLOADs for config check.

## M2 BuySellTaxMechanism — Finalized Spec

### Purpose

Asymmetric tax via **V4 dynamic LP fee** mechanism. Higher fees on sells (deter dumping), lower on buys (encourage accumulation). Linear decay over time toward a base rate. v1 uses dynamic LP fee only (no `*ReturnDelta`) — fees flow naturally to LP holders. Treasury routing deferred to v2 (M8).

### Units

V4 dynamic fee uses **hundredths of basis points**:
- `1e4` = 1%
- `1e6` = 100% (V4 ceiling)
- Our `MAX_TAX = 1e5` = 10%

Using `uint24` directly matches V4 fee type — no conversion needed at hook callback boundary.

### Configuration (1 slot per pool, 19 bytes used)

```solidity
struct BuySellTaxConfig {
    // ─── Immutable post-bootstrap ───
    uint24 initialBuyTax;       // V4 fee units, capped at MAX_TAX
    uint24 initialSellTax;
    uint24 baseTax;             // final tax after decay (or always if decayDuration=0)
    uint32 decayDuration;       // seconds (0 = instant decay to baseTax)
    
    // ─── Mutable by governance, one-way ratchet down (T3, T9) ───
    uint24 manualBuyTax;        // 0 = no override
    uint24 manualSellTax;
    
    // Total: 24×5 + 32 = 152 bits = 19 bytes → fits in 1 slot ✓
}

mapping(PoolId => BuySellTaxConfig) internal _taxConfigs;
```

### Constants

```solidity
uint24 internal constant MAX_TAX = 100_000;  // 10% in V4 fee units
```

### Decay curve (linear, T1)

```
if decayDuration == 0 OR elapsed >= decayDuration:
    tax = baseTax
else:
    tax = initialTax - (initialTax - baseTax) × elapsed / decayDuration
```

**Example:** 5% initial sell, 0.3% base, 30-day decay:
- Day 0: 5.00%
- Day 7: ≈ 3.90%
- Day 15: ≈ 2.65%
- Day 30+: 0.30%

### Skeleton

```solidity
abstract contract BuySellTaxMechanism {
    uint24 internal constant MAX_TAX = 100_000;
    
    mapping(PoolId => BuySellTaxConfig) internal _taxConfigs;
    
    error InvalidTaxConfig();
    error TaxExceedsMax();
    error CanOnlyLowerTax();
    
    event BuySellTaxInitialized(PoolId indexed pid, BuySellTaxConfig cfg);
    event TaxOverrideSet(PoolId indexed pid, bool isBuy, uint24 oldValue, uint24 newValue);
    event TaxApplied(PoolId indexed pid, address indexed trader, bool isBuy, uint24 feeBps);
    
    function _initTax(PoolId pid, BuySellTaxConfig memory cfg) internal {
        if (cfg.initialBuyTax > MAX_TAX) revert TaxExceedsMax();
        if (cfg.initialSellTax > MAX_TAX) revert TaxExceedsMax();
        if (cfg.baseTax > MAX_TAX) revert TaxExceedsMax();
        if (cfg.baseTax > cfg.initialBuyTax || cfg.baseTax > cfg.initialSellTax) {
            revert InvalidTaxConfig();
        }
        if (cfg.manualBuyTax != 0 || cfg.manualSellTax != 0) revert InvalidTaxConfig();
        _taxConfigs[pid] = cfg;
        emit BuySellTaxInitialized(pid, cfg);
    }
    
    /// @notice Compute the effective tax for a swap. Stateless (no SSTOREs).
    function _currentTax(
        PoolId pid,
        SwapParams calldata params,
        bool tokenIsCurrency0,
        uint64 launchTime
    ) internal view returns (uint24) {
        bool isBuy = (params.zeroForOne != tokenIsCurrency0);
        BuySellTaxConfig storage cfg = _taxConfigs[pid];
        uint24 initial = isBuy ? cfg.initialBuyTax : cfg.initialSellTax;
        uint24 manual = isBuy ? cfg.manualBuyTax : cfg.manualSellTax;
        
        uint24 decayed = _decayedTax(
            initial, cfg.baseTax, cfg.decayDuration, block.timestamp - launchTime
        );
        if (manual == 0) return decayed;
        return decayed < manual ? decayed : manual;
    }
    
    function _decayedTax(uint24 initial, uint24 base, uint32 duration, uint256 elapsed) 
        internal pure returns (uint24) 
    {
        // T11: instant decay if duration = 0
        if (duration == 0 || elapsed >= duration) return base;
        // T1: linear interpolation
        uint24 reduction = uint24(uint256(initial - base) * elapsed / duration);
        return initial - reduction;
    }
    
    /// @notice Governance setter: lower buy-tax ceiling (one-way ratchet).
    function setBuyTaxOverride(PoolId pid, uint24 newOverride) external onlyGovernance(pid) {
        _setTaxOverride(pid, true, newOverride);
    }
    
    function setSellTaxOverride(PoolId pid, uint24 newOverride) external onlyGovernance(pid) {
        _setTaxOverride(pid, false, newOverride);
    }
    
    function _setTaxOverride(PoolId pid, bool isBuy, uint24 newOverride) internal {
        if (newOverride == 0) revert InvalidTaxConfig();  // T4: 0 reserved for "no override"
        if (newOverride > MAX_TAX) revert TaxExceedsMax();
        BuySellTaxConfig storage cfg = _taxConfigs[pid];
        uint24 old = isBuy ? cfg.manualBuyTax : cfg.manualSellTax;
        // T9: strictly lower; first set has old=0 so always lower
        if (old != 0 && newOverride >= old) revert CanOnlyLowerTax();
        if (isBuy) cfg.manualBuyTax = newOverride;
        else cfg.manualSellTax = newOverride;
        emit TaxOverrideSet(pid, isBuy, old, newOverride);
    }
    
    // Views
    function taxConfigOf(PoolId pid) external view returns (BuySellTaxConfig memory) {
        return _taxConfigs[pid];
    }
    
    function effectiveBuyTaxOf(PoolId pid) external view returns (uint24);
    function effectiveSellTaxOf(PoolId pid) external view returns (uint24);
}
```

### Integration in main hook

```solidity
function _beforeSwap(...) internal override returns (bytes4, BeforeSwapDelta, uint24) {
    PoolId pid = key.toId();
    EnabledMechanisms memory en = enabled[pid];
    GovernanceState storage gov = _governance[pid];
    
    if (en.antiSnipe) {
        _checkAntiSnipe(pid, params, gov.tokenIsCurrency0, gov.launchTime);
    }
    // ... other modules (M5, etc.)
    
    uint24 fee = 0;
    if (en.tax) {
        fee = _currentTax(pid, params, gov.tokenIsCurrency0, gov.launchTime);
        bool isBuy = (params.zeroForOne != gov.tokenIsCurrency0);
        emit TaxApplied(pid, tx.origin, isBuy, fee);  // T8
    }
    
    return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), fee);
}
```

### Test cases (14 tests in `test/mechanisms/BuySellTaxMechanism.t.sol`)

```
test_init_storesConfig_emitsEvent
test_init_initialBelowBase_reverts                       (InvalidTaxConfig)
test_init_initialExceedsMax_reverts                      (TaxExceedsMax)
test_init_baseExceedsMax_reverts                         (TaxExceedsMax)
test_init_manualPresetAtBootstrap_reverts                (InvalidTaxConfig)
test_buy_atLaunchTime_returnsInitialBuyTax
test_sell_atLaunchTime_returnsInitialSellTax
test_buy_midDecay_returnsLinearInterpolation
test_buy_afterDecayDuration_returnsBaseTax
test_zeroDecayDuration_immediatelyReturnsBase
test_setBuyTaxOverride_byOwner_succeeds_emitsEvent
test_setBuyTaxOverride_byNonOwner_reverts                (NotGovernanceOwner)
test_setBuyTaxOverride_higherThanCurrent_reverts         (CanOnlyLowerTax)
test_setBuyTaxOverride_thenDecayGoesBelow_usesDecay
test_postLaunchEnd_setOverride_reverts                   (LaunchEnded)
```

### Edge cases / notes

- **Tax economics under v1 (no ReturnDelta)**: tax = LP fee. All collected fees go to active LPs at the swap's tick range. Deployer's locked seed LP captures most of this initially. Once unlock conditions met and other LPs join, fees distribute pro-rata.
- **`decayDuration = 0`**: launch with permanent flat tax (initial fields ignored). Use case: stable assets, RWA pools where tax doesn't decay.
- **Override mechanics**: setting `setBuyTaxOverride(5_000)` while decay is at 8% → effective drops to 5% immediately. If decay later naturally reaches 3%, effective continues to drop to 3% (min wins). Override doesn't "freeze" tax — it caps it.
- **Stateless module**: `_currentTax` is `internal view`. No SSTOREs in `_beforeSwap`. Only SLOADs.

## M3 LiquidityLockMechanism — Finalized Spec

### Purpose

Provides **conditional unlock** for the governance NFT (deployer's seed LP). Extends GovernanceModule's simple time-based burn protection (`launchEndTime` from G3) with richer criteria: cumulative volume threshold, combined logic.

**Relationship with Governance burn protection:**
- GovernanceModule: blocks `decreaseLiquidity` / `burn` of gov NFT until `launchEndTime` — **always applies** (whether M3 enabled or not)
- M3: **additional** check on top — when enabled, both conditions must pass

Result: `launchEndTime` is the **minimum lock duration**, M3 extends it with stricter requirements.

**Scope:** M3 applies ONLY to governance NFT. Other LP NFTs (joining after launch) are free to add/remove anytime. Avoids overly-restrictive UX for retail LPs.

### Configuration (2 slots per pool)

```solidity
enum UnlockLogic { AND, OR }

struct LiquidityLockConfig {
    UnlockLogic logic;              // 1 byte
    bool timeEnabled;               // 1 byte
    bool volumeEnabled;             // 1 byte
    uint64 unlockTime;              // 8 bytes (must be >= launchEndTime at init)
    uint128 unlockVolumeThreshold;  // 16 bytes (pair-currency wei)
    // Total: 27 bytes → fits in 1 slot ✓
}

struct LiquidityLockState {
    uint128 cumulativeVolume;       // 16 bytes — accumulated pair-side, lifetime
}

mapping(PoolId => LiquidityLockConfig) internal _lockConfigs;
mapping(PoolId => LiquidityLockState) internal _lockStates;
```

### Volume tracking (in `_afterSwap`)

```solidity
function _trackVolume(PoolId pid, BalanceDelta delta, bool tokenIsCurrency0) internal {
    int128 pairAmount = tokenIsCurrency0 ? delta.amount1() : delta.amount0();
    uint128 absVol = uint128(uint256(int256(pairAmount < 0 ? -pairAmount : pairAmount)));
    _lockStates[pid].cumulativeVolume += absVol;
}
```

Volume = sum of absolute pair-currency deltas across all swaps (L5, L6, L7). Both buys and sells contribute. Pair-side measurement makes thresholds comparable across launches (deployer specifies in WETH wei).

### Unlock check

```solidity
function _isUnlocked(PoolId pid) internal view returns (bool) {
    LiquidityLockConfig storage cfg = _lockConfigs[pid];
    LiquidityLockState storage state = _lockStates[pid];
    
    bool timeOk = !cfg.timeEnabled || block.timestamp >= cfg.unlockTime;
    bool volumeOk = !cfg.volumeEnabled || state.cumulativeVolume >= cfg.unlockVolumeThreshold;
    
    if (cfg.logic == UnlockLogic.AND) {
        return timeOk && volumeOk;
    } else {
        // OR: at least one ENABLED condition must be met
        return (cfg.timeEnabled && timeOk) || (cfg.volumeEnabled && volumeOk);
    }
}
```

### Skeleton

```solidity
abstract contract LiquidityLockMechanism {
    mapping(PoolId => LiquidityLockConfig) internal _lockConfigs;
    mapping(PoolId => LiquidityLockState) internal _lockStates;
    
    error NoConditionsEnabled();
    error UnlockTimeBeforeLaunchEnd();
    error CanOnlyRelax();
    error MustKeepOneCondition();
    error LiquidityStillLocked();
    error AlreadyOr();
    
    event LiquidityLockInitialized(PoolId indexed pid, LiquidityLockConfig cfg);
    event UnlockTimeRelaxed(PoolId indexed pid, uint64 oldTime, uint64 newTime);
    event UnlockVolumeRelaxed(PoolId indexed pid, uint128 oldVol, uint128 newVol);
    event ConditionDisabled(PoolId indexed pid, bool wasTime);
    event LogicSwitchedToOr(PoolId indexed pid);
    
    function _initLock(PoolId pid, LiquidityLockConfig memory cfg, uint64 launchEndTime) internal {
        if (!cfg.timeEnabled && !cfg.volumeEnabled) revert NoConditionsEnabled();       // L4
        if (cfg.timeEnabled && cfg.unlockTime < launchEndTime) revert UnlockTimeBeforeLaunchEnd(); // L11
        if (cfg.volumeEnabled && cfg.unlockVolumeThreshold == 0) revert NoConditionsEnabled();
        _lockConfigs[pid] = cfg;
        emit LiquidityLockInitialized(pid, cfg);
    }
    
    function _checkLiquidityLock(PoolId pid) internal view {
        if (!_isUnlocked(pid)) revert LiquidityStillLocked();
    }
    
    function _trackVolume(PoolId pid, BalanceDelta delta, bool tokenIsCurrency0) internal {
        int128 pairAmount = tokenIsCurrency0 ? delta.amount1() : delta.amount0();
        uint128 absVol = uint128(uint256(int256(pairAmount < 0 ? -pairAmount : pairAmount)));
        _lockStates[pid].cumulativeVolume += absVol;
    }
    
    // ─── Governance setters (one-way relaxation per L3) ───
    
    function relaxUnlockTime(PoolId pid, uint64 newTime) external onlyGovernance(pid) {
        LiquidityLockConfig storage cfg = _lockConfigs[pid];
        if (!cfg.timeEnabled) revert NoConditionsEnabled();
        if (newTime >= cfg.unlockTime) revert CanOnlyRelax();
        uint64 old = cfg.unlockTime;
        cfg.unlockTime = newTime;
        emit UnlockTimeRelaxed(pid, old, newTime);
    }
    
    function relaxUnlockVolume(PoolId pid, uint128 newVol) external onlyGovernance(pid) {
        LiquidityLockConfig storage cfg = _lockConfigs[pid];
        if (!cfg.volumeEnabled) revert NoConditionsEnabled();
        if (newVol >= cfg.unlockVolumeThreshold) revert CanOnlyRelax();
        if (newVol == 0) revert NoConditionsEnabled();  // use disableVolumeCondition instead
        uint128 old = cfg.unlockVolumeThreshold;
        cfg.unlockVolumeThreshold = newVol;
        emit UnlockVolumeRelaxed(pid, old, newVol);
    }
    
    function disableTimeCondition(PoolId pid) external onlyGovernance(pid) {
        LiquidityLockConfig storage cfg = _lockConfigs[pid];
        if (!cfg.timeEnabled) revert NoConditionsEnabled();
        if (!cfg.volumeEnabled) revert MustKeepOneCondition();  // L4
        cfg.timeEnabled = false;
        emit ConditionDisabled(pid, true);
    }
    
    function disableVolumeCondition(PoolId pid) external onlyGovernance(pid) {
        LiquidityLockConfig storage cfg = _lockConfigs[pid];
        if (!cfg.volumeEnabled) revert NoConditionsEnabled();
        if (!cfg.timeEnabled) revert MustKeepOneCondition();
        cfg.volumeEnabled = false;
        emit ConditionDisabled(pid, false);
    }
    
    function switchToOr(PoolId pid) external onlyGovernance(pid) {
        LiquidityLockConfig storage cfg = _lockConfigs[pid];
        if (cfg.logic == UnlockLogic.OR) revert AlreadyOr();
        cfg.logic = UnlockLogic.OR;
        emit LogicSwitchedToOr(pid);
    }
    
    // Views
    function lockConfigOf(PoolId pid) external view returns (LiquidityLockConfig memory) {
        return _lockConfigs[pid];
    }
    
    function cumulativeVolumeOf(PoolId pid) external view returns (uint128) {
        return _lockStates[pid].cumulativeVolume;
    }
    
    function isUnlocked(PoolId pid) external view returns (bool) {
        return _isUnlocked(pid);
    }
}
```

### Integration in main hook

```solidity
// _beforeRemoveLiquidity
function _beforeRemoveLiquidity(
    address /*sender*/,
    PoolKey calldata key,
    ModifyLiquidityParams calldata params,
    bytes calldata
) internal override returns (bytes4) {
    PoolId pid = key.toId();
    GovernanceState storage gov = _governance[pid];
    
    if (uint256(params.salt) == gov.tokenId) {       // L8: only gov NFT
        _checkBurnProtection(pid, params);            // Governance G3 — always
        if (enabled[pid].lock) {
            _checkLiquidityLock(pid);                 // M3 — when enabled (L9: AND with G3)
        }
    }
    return this.beforeRemoveLiquidity.selector;
}

// _afterSwap
function _afterSwap(
    address /*sender*/,
    PoolKey calldata key,
    SwapParams calldata /*params*/,
    BalanceDelta delta,
    bytes calldata
) internal override returns (bytes4, int128) {
    PoolId pid = key.toId();
    if (enabled[pid].lock) {
        _trackVolume(pid, delta, _governance[pid].tokenIsCurrency0);
    }
    return (this.afterSwap.selector, 0);
}
```

### Test cases (18 tests in `test/mechanisms/LiquidityLockMechanism.t.sol`)

```
test_init_storesConfig_emitsEvent
test_init_noConditions_reverts                       (NoConditionsEnabled)
test_init_unlockTimeBeforeLaunchEnd_reverts          (UnlockTimeBeforeLaunchEnd)
test_init_volumeEnabledZeroThreshold_reverts         (NoConditionsEnabled)
test_volumeAccumulates_inAfterSwap_bothDirections
test_isUnlocked_AND_bothMet_returnsTrue
test_isUnlocked_AND_oneMet_returnsFalse
test_isUnlocked_OR_eitherMet_returnsTrue
test_isUnlocked_neitherMet_returnsFalse
test_removeLiquidity_locked_reverts                  (LiquidityStillLocked)
test_removeLiquidity_unlocked_succeeds
test_removeLiquidity_beforeLaunchEnd_reverts         (Governance G3, even if M3 met)
test_relaxUnlockTime_byOwner_succeeds_emitsEvent
test_relaxUnlockTime_higherThanCurrent_reverts       (CanOnlyRelax)
test_relaxUnlockVolume_byOwner_succeeds
test_disableTimeCondition_keepsVolumeActive
test_disableLastCondition_reverts                    (MustKeepOneCondition)
test_switchToOr_changesLogic_emitsEvent
test_switchToOr_alreadyOr_reverts                    (AlreadyOr)
test_nonGovNFT_removeLiquidity_unrestricted
```

### Edge cases / notes

- **Volume accumulation overflow**: `uint128` ceiling = ~3.4 × 10³⁸ wei = ~3.4 × 10²⁰ ETH. Effectively unlimited for any realistic launch. SafeMath not needed.
- **Cumulative metric**: volume never resets, even after unlock. Allows tracking lifetime activity for analytics.
- **AND→OR one-way ratchet**: gov cannot tighten by reverting OR→AND. Once relaxed, stays relaxed.
- **Edge case: relax to current `block.timestamp`**: `newTime < cfg.unlockTime` allows setting to `block.timestamp - 1`, effectively "unlock now if other conditions met". Useful for emergency unlock.
- **No "reachability check" on volumeThreshold**: deployer could set `unlockVolumeThreshold = type(uint128).max` → effectively never unlocks via volume. That's their choice; gov can lower if mistake.

## M5 WhitelistPhaseMechanism — Finalized Spec

### Purpose

Phased access control: only **whitelisted addresses** can interact with the pool (buys, sells, LP adds) until a configurable end time. After endTime expires, restrictions lift entirely. Removal of liquidity (`decreaseLiquidity` / `burn`) is **always** allowed even for non-whitelisted addresses — anyone with a position can exit.

**Use cases:**
- **RWA / Permissioned**: KYC required for trading. `whitelistEndTime = launchEndTime` for full launch protection.
- **Fair launch**: early-access for community members. Whitelist for first hours/days, then open.
- **ICO-like presale**: only pre-sale participants buy early.

### Configuration (1 slot per pool, 8 bytes used)

```solidity
struct WhitelistPhaseConfig {
    uint64 whitelistEndTime;     // must be > launchTime AND <= launchEndTime
    // 8 bytes used; rest of slot unused (room for v2 extensions)
}

struct WhitelistPhaseState {
    mapping(address => bool) whitelisted;
}

mapping(PoolId => WhitelistPhaseConfig) internal _whitelistConfigs;
mapping(PoolId => WhitelistPhaseState) internal _whitelistStates;
```

**Storage cost:**
- 1 slot per pool for config
- 1 slot per (pool, address) for state — grows with whitelist size

### Check logic

```solidity
function _checkWhitelist(PoolId pid) internal view {
    WhitelistPhaseConfig storage cfg = _whitelistConfigs[pid];
    if (block.timestamp >= cfg.whitelistEndTime) return;  // window expired — open phase
    if (!_whitelistStates[pid].whitelisted[tx.origin]) revert NotWhitelisted();
}
```

Single check covers all gated actions. Applied to:
- `_beforeSwap`: catches both buys and sells
- `_beforeAddLiquidity`: catches LP adds (except bootstrap — see Integration)

NOT applied to `_beforeRemoveLiquidity` (W11 — always allow exit).

### Skeleton

```solidity
abstract contract WhitelistPhaseMechanism {
    mapping(PoolId => WhitelistPhaseConfig) internal _whitelistConfigs;
    mapping(PoolId => WhitelistPhaseState) internal _whitelistStates;
    
    error NotWhitelisted();
    error InvalidWhitelistEndTime();
    error CanOnlyRelax();
    
    event WhitelistPhaseInitialized(PoolId indexed pid, uint64 whitelistEndTime);
    event WhitelistEndTimeRelaxed(PoolId indexed pid, uint64 oldTime, uint64 newTime);
    event AddressWhitelisted(PoolId indexed pid, address indexed user);
    event AddressUnwhitelisted(PoolId indexed pid, address indexed user);
    
    function _initWhitelist(
        PoolId pid, 
        WhitelistPhaseConfig memory cfg, 
        uint64 launchTime, 
        uint64 launchEndTime
    ) internal {
        // W7 + W8: bounded by launch lifecycle
        if (cfg.whitelistEndTime <= launchTime) revert InvalidWhitelistEndTime();
        if (cfg.whitelistEndTime > launchEndTime) revert InvalidWhitelistEndTime();
        _whitelistConfigs[pid] = cfg;
        emit WhitelistPhaseInitialized(pid, cfg.whitelistEndTime);
    }
    
    function _checkWhitelist(PoolId pid) internal view {
        WhitelistPhaseConfig storage cfg = _whitelistConfigs[pid];
        if (block.timestamp >= cfg.whitelistEndTime) return;
        if (!_whitelistStates[pid].whitelisted[tx.origin]) revert NotWhitelisted();
    }
    
    // ─── Governance setters ───
    
    function addToWhitelist(PoolId pid, address user) external onlyGovernance(pid) {
        _whitelistStates[pid].whitelisted[user] = true;
        emit AddressWhitelisted(pid, user);
    }
    
    function addManyToWhitelist(PoolId pid, address[] calldata users) external onlyGovernance(pid) {
        WhitelistPhaseState storage state = _whitelistStates[pid];
        for (uint256 i = 0; i < users.length; i++) {
            state.whitelisted[users[i]] = true;
            emit AddressWhitelisted(pid, users[i]);
        }
    }
    
    function removeFromWhitelist(PoolId pid, address user) external onlyGovernance(pid) {
        _whitelistStates[pid].whitelisted[user] = false;
        emit AddressUnwhitelisted(pid, user);
    }
    
    function removeManyFromWhitelist(PoolId pid, address[] calldata users) external onlyGovernance(pid) {
        WhitelistPhaseState storage state = _whitelistStates[pid];
        for (uint256 i = 0; i < users.length; i++) {
            state.whitelisted[users[i]] = false;
            emit AddressUnwhitelisted(pid, users[i]);
        }
    }
    
    function relaxWhitelistEndTime(PoolId pid, uint64 newEndTime) external onlyGovernance(pid) {
        WhitelistPhaseConfig storage cfg = _whitelistConfigs[pid];
        if (newEndTime >= cfg.whitelistEndTime) revert CanOnlyRelax();
        uint64 old = cfg.whitelistEndTime;
        cfg.whitelistEndTime = newEndTime;
        emit WhitelistEndTimeRelaxed(pid, old, newEndTime);
    }
    
    // Views
    function whitelistConfigOf(PoolId pid) external view returns (WhitelistPhaseConfig memory) {
        return _whitelistConfigs[pid];
    }
    
    function isAddressWhitelisted(PoolId pid, address user) external view returns (bool) {
        return _whitelistStates[pid].whitelisted[user];
    }
}
```

### Integration in main hook

```solidity
function _beforeSwap(...) internal override returns (bytes4, BeforeSwapDelta, uint24) {
    PoolId pid = key.toId();
    EnabledMechanisms memory en = enabled[pid];
    GovernanceState storage gov = _governance[pid];
    
    if (en.whitelist) _checkWhitelist(pid);           // gates BOTH swap directions
    if (en.antiSnipe) _checkAntiSnipe(pid, params, gov.tokenIsCurrency0, gov.launchTime);
    // ...
    
    uint24 fee = en.tax ? _currentTax(pid, params, gov.tokenIsCurrency0, gov.launchTime) : 0;
    return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), fee);
}

function _beforeAddLiquidity(...) internal override returns (bytes4) {
    PoolId pid = key.toId();
    GovernanceState storage state = _governance[pid];
    
    if (!state.initialized) {
        // Bootstrap path — skip whitelist check (deployer doesn't need to be whitelisted)
        _initGovernance(pid, params, decoded.govCfg, sender);
        // ... init other enabled modules from hookData
        return this.beforeAddLiquidity.selector;
    }
    
    EnabledMechanisms memory en = enabled[pid];
    if (en.whitelist) _checkWhitelist(pid);           // gates LP adds
    
    return this.beforeAddLiquidity.selector;
}

// _beforeRemoveLiquidity — NO whitelist check (W11: always allow exit)
```

### Test cases (19 tests in `test/mechanisms/WhitelistPhaseMechanism.t.sol`)

```
test_init_storesConfig_emitsEvent
test_init_endTimeAtOrBeforeLaunchTime_reverts            (InvalidWhitelistEndTime)
test_init_endTimeAfterLaunchEnd_reverts                  (InvalidWhitelistEndTime)
test_whitelisted_canBuy
test_whitelisted_canSell
test_whitelisted_canAddLiquidity
test_nonWhitelisted_cannotBuy                            (NotWhitelisted)
test_nonWhitelisted_cannotSell                           (NotWhitelisted)
test_nonWhitelisted_cannotAddLiquidity                   (NotWhitelisted)
test_nonWhitelisted_canAlwaysRemoveLiquidity
test_afterEndTime_unrestricted_evenNonWhitelisted
test_bootstrap_skipsWhitelistCheck                       (deployer doesn't need to be whitelisted)
test_addToWhitelist_byOwner_succeeds_emitsEvent
test_addManyToWhitelist_batch_emitsEvents
test_removeFromWhitelist_byOwner_succeeds_emitsEvent
test_removeManyFromWhitelist_batch_emitsEvents
test_addToWhitelist_byNonOwner_reverts                   (NotGovernanceOwner)
test_relaxEndTime_byOwner_succeeds
test_relaxEndTime_laterThanCurrent_reverts               (CanOnlyRelax)
```

### Edge cases / notes

- **Bootstrap path bypass**: at first mint, `state.initialized == false` → governance init runs and module init configures whitelist. Deployer's first mint doesn't require their address to be whitelisted (they configure the list during the same atomic TX).
- **Whitelist bounded by launch lifecycle**: `whitelistEndTime` is in `(launchTime, launchEndTime]`. After `launchEndTime`, governance phase is frozen anyway — whitelist must conclude by then. For "RWA permanent gating", deployer sets `launchDuration = 365 days` (MAX) and `whitelistEndTime = launchTime + 365 days`.
- **Storage growth**: each whitelisted address consumes 1 slot. For a launch with 10,000 KYC'd users, that's 10K SSTOREs at bootstrap or via batch — costly. Recommendation: use `addManyToWhitelist` in chunks of 100-200 per TX to manage gas.
- **W11 rationale**: removing liquidity is asset withdrawal. Blocking it could trap user funds. Even if a user gets removed from whitelist (after adding liquidity earlier), they can still exit. M3 LiquidityLock separately protects the governance NFT — that's deployer's own LP, not third-party LPs.
- **Bootstrap multicall order**: in `CampaignWrapper.launchCampaign`, after governance bootstrap completes, the wrapper can immediately call `addManyToWhitelist` for the initial KYC list — all in same atomic launch TX.


## Required Hook Permissions

```solidity
Hooks.Permissions({
    beforeInitialize: true,                       // no-op (V4 enforces first-init-wins)
    afterInitialize: false,
    beforeAddLiquidity: true,                     // bootstrap + whitelist + sniper checks
    afterAddLiquidity: false,
    beforeRemoveLiquidity: true,                  // governance burn protection + M3 lock check
    afterRemoveLiquidity: false,
    beforeSwap: true,                             // anti-snipe + tax (fee override) + whitelist
    afterSwap: true,                              // M3 volume tracking
    beforeSwapReturnDelta: true,                  // v2: bonding curve fallback (M6)
    afterSwapReturnDelta: true,                   // v2: treasury fee routing (M8) + auto-buyback (M7)
    afterAddLiquidityReturnDelta: false,
    afterRemoveLiquidityReturnDelta: false,
    beforeDonate: false,
    afterDonate: false
});
```

**Note:** v1 modules don't use `*ReturnDelta` at runtime, but flags are reserved at deploy for v2 modules (M6, M7, M8) to be added later without redeploying the hook.

## Reused Patterns

- **`BaseHook`** (`lib/v4-hooks-public/src/base/BaseHook.sol`) — standard inheritance, **unchanged**. CREATE2 salt mining for `TokenLaunchHook` deploy address handles permission flag bits.
- **OpenZeppelin `Clones`** (`@openzeppelin/contracts/proxy/Clones.sol`) — for `TokenFactory` ERC-20 minimal proxies. NOT used for the hook itself.
- **`Multicall_v4`** in PositionManager — atomic batching of `initializePool + modifyLiquidities`; forwards `msg.value`.
- **`Permit2`** approval flow — pre-signed token approval used inside `CampaignWrapper`.
- **Dynamic fee** via `LPFeeLibrary.DYNAMIC_FEE_FLAG` + per-swap fee in `_beforeSwap` return value (M2).
- **`BalanceDelta`** for swap amount tracking (M3 volume).
- **`StateLibrary`** for reading pool state (slot0, position) inside callbacks.
- **`Hooks.isValidHookAddress`** for verifying mined hook deploy address has correct flag bits.
