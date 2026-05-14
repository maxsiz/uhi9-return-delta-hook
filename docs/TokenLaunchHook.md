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
            
            // Capture governance NFT via salt convention
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

## Critical Files to Create

### On-chain contracts (one deploy per chain)

| File | Purpose |
|------|---------|
| `src/TokenLaunchHook.sol` | Single hook contract for ALL launches on this chain. Inherits `BaseHook` **unchanged**. Storage: `mapping(PoolId => CampaignState)`. Submitted to Uniswap allowlist once. Mined CREATE2 salt for permission flag bits. |
| `src/CampaignWrapper.sol` | Non-upgradeable coordinator. Single function `launchCampaign(params, permitSig)` does everything atomically via PosM multicall. Optionally invokes TokenFactory. |
| `src/TokenFactory.sol` | Deploys cheap ERC-20 tokens via EIP-1167 minimal proxies (`Clones.clone` from OpenZeppelin). Independent of hook — no allowlist concerns. |
| `src/StandardToken.sol` | Initializable ERC-20 implementation cloned by TokenFactory. Standard `mint to recipient` semantics. |
| `src/lib/LaunchMath.sol` | Tax calculation, decay curves, bonding curve math (pure library) |
| `src/lib/UnlockConditions.sol` | Unlock condition predicates (time, volume, holders, price) |
| `script/MineSalt.s.sol` | Off-chain Foundry helper to compute CREATE2 salt for `TokenLaunchHook` so its address has the required permission flag bits |
| `script/DeployStack.s.sol` | One-time per-chain deploy: mine salt → deploy hook → deploy wrapper → deploy factory → deploy token impl |

### Off-chain components

| Component | Purpose |
|-----------|---------|
| `web/` (static frontend) | Vercel-hosted Web3 UI. Form for campaign params. Wallet connect via RainbowKit. Builds and signs single TX to `CampaignWrapper`. |
| `web/lib/launchURL.ts` | URL builder for deep-linking individual campaigns + sharing on Twitter/Telegram |
| (optional) `keeper/` | If using auto-harvest for tax distribution — Cloudflare Workers bot |

### Tests

| File | Purpose |
|------|---------|
| `test/CampaignWrapper.t.sol` | Atomic launch flow, edge cases (existing token vs new, native ETH vs ERC-20 pair) |
| `test/TokenLaunchHook.t.sol` | Mechanism tests (anti-snipe, tax, lock, etc.) |
| `test/TokenLaunchHook.governance.t.sol` | Governance NFT capture, mutability constraints, lifecycle phases |
| `test/TokenLaunchHook.race.t.sol` | Anti-sandwich resistance (try to mint first as attacker) |
| `test/TokenFactory.t.sol` | Token deploy via clones, initialization correctness |
| `test/TokenLaunchHook.fork.t.sol` | Mainnet fork tests against real PoolManager/PosM |

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
        
        // Capture governance NFT
        // Salt convention in V4 PosM: salt = bytes32(tokenId) — VERIFY in PosM source
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

### Salt = tokenId convention

For NFT capture to work, V4 PositionManager **must** use `salt = bytes32(tokenId)` when calling `PoolManager.modifyLiquidity`. **VERIFY** in `lib/v4-hooks-public/lib/v4-periphery/src/PositionManager.sol` source before relying on it.

If different, alternative capture mechanisms:
- Listen to `Transfer(address(0), recipient, tokenId)` event off-chain → call `hook.designateGovernance(pid, tokenId)` from authorized address
- Use `subscribe(tokenId, hook, "")` from wrapper immediately after mint; hook captures tokenId from `notifySubscribe`
- Wrapper reads `PosM.nextTokenId()` before mint, predicts tokenId, passes via hookData (fragile — race with other PosM users)

**Recommendation: verify salt convention as priority #1 before coding.**

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

4. **First-LP capture: `salt = tokenId` convention assumption:**
   - PosM source must use `salt = bytes32(tokenId)` for hook to read tokenId
   - **Highest priority: verify in `lib/v4-hooks-public/lib/v4-periphery/src/PositionManager.sol` BEFORE coding.**
   - If different, fallback: `subscribe()` + `notifySubscribe` callback to record tokenId

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

11. **Custom accounting (`*ReturnDelta`) — include or exclude?**
    - Including: full feature set (auto-tax-redirect, bonding curve, auto-buyback) but **requires Uniswap allowlist** before pool routes via Uniswap UI
    - Excluding: ship without allowlist friction; lose some mechanism elegance (taxes flow to LPs not treasury)
    - **Recommendation: launch v1 WITH custom accounting + apply for allowlist concurrently. Use fallback distribution (aggregators, own UI) until approved.**

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| **Uniswap allowlist rejection or long delay** | 🔴 **CRITICAL** | Use fallback distribution (aggregators + own swap UI) until approved; build product NOT dependent on Uniswap UI |
| Reputation: memecoin scams use our hook | 🔴 High | Position as "fair launch infra"; vet projects via opt-in audit |
| Regulatory: ICO-like mechanisms = securities | 🔴 High | Geofence US users on frontend; legal review of templates |
| MEV: sniper bots adapt to our anti-snipe | 🟡 Medium | Continuous iteration; collaborative testing with searchers |
| Hook contract bug → ALL launches affected (blast radius) | 🔴 High | Single hook = one comprehensive audit (~$80K); bug bounty pre-launch; hook is immutable post-deploy |
| Wrapper bug breaks new launches | 🟡 Medium | Old launches still work (only `_beforeAddLiquidity` runs through hook). Deploy new wrapper version, UI updates |
| Salt mining incorrectness for hook → bad flag bits | 🟡 Medium | Deploy script validates `Hooks.isValidHookAddress` post-deploy |
| Init race in multi-step deploy (before atomic multicall) | 🟢 Low | `CampaignWrapper` uses atomic multicall — race window = 0 |
| Governance NFT lost/burned mid-launch | 🟡 Medium | Hook blocks burn in Phase 1 via `_beforeRemoveLiquidity` |
| AA wallets break `tx.origin` checks | 🟡 Medium | ECDSA signature pattern in v2; document v1 limitation |
| Tax logic gas cost makes small swaps uneconomical | 🟡 Medium | Optimize gas; consider waiver for swaps below threshold |
| `salt = tokenId` convention assumption wrong | 🟡 Medium | **Verify in PosM source BEFORE coding**; fallback via subscribe |
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
| **Pre-coding research** | 1 week | Verify salt convention; salt mining feasibility; Uniswap allowlist process |
| **Spec finalization** | 1 week | Interfaces locked; deploy script outlined; UI mockups |
| **Core contracts: hook + wrapper + factory** | 6 weeks | M1-M3 implemented; CampaignWrapper full; TokenFactory; 90% test coverage |
| **Extended mechanisms** | 3 weeks | M4-M6 implemented |
| **Web3 UI MVP** | 3 weeks | Static Vercel-hosted; campaign form; wallet connect; deep links |
| **Submit Uniswap allowlist application** | — | Parallel with audit; whenever code is testable |
| **Audit** | 4-6 weeks | External audit of hook + wrapper + factory (~$80K); fixes; bug bounty |
| **Testnet launch + beta** | 4 weeks | Base Sepolia + Unichain Sepolia; 3-5 beta launches with friendly projects |
| **Mainnet** | — | Deploy on Base/Unichain (cheap), Arbitrum (good liquidity), Mainnet (last) |

**Total to mainnet: ~5-6 months.** Uniswap allowlist may resolve in parallel or post-mainnet (Phase A/B fallback handles either).

## Open Questions for Future Sessions

1. **VERIFY: `salt = bytes32(tokenId)` in V4 PositionManager** — read `lib/v4-hooks-public/lib/v4-periphery/src/PositionManager.sol`, confirm. If different, redesign capture via subscribe-callback. *🔴 Highest priority before coding — blocks the whole governance model.*

2. **Uniswap allowlist process research**:
   - What's the application form URL and required materials?
   - Typical timeline (days/weeks/months)?
   - Rejection criteria — any documented patterns?
   - Examples of approved hooks for inspiration?
   - Apply early (parallel with development) so allowlist isn't sequential

3. **Submit timeline:** if Uniswap allowlist needs 4-12 weeks, when in our dev cycle should we apply? Probably right after testnet deployment + initial audit (so we have something concrete to show).

4. **Anti-sandwich auth: `tx.origin` vs ECDSA signature** — for v1 pick `tx.origin` (most launchers EOA). For v2, design EIP-712 signing flow. Test wallet ecosystem coverage.

5. **Salt mining for `TokenLaunchHook` address** — what's typical mining time on commodity hardware (say, MacBook M-series)? If hours, that's fine for one-time deploy. If days, need GPU rig. Test once.

6. **`PositionManager.multicall` exact API**:
   - Confirm it forwards `msg.value` across all sub-calls (Multicall_v4 contract pattern)
   - Confirm `initializePool` works inside multicall (not just `modifyLiquidities`)
   - Confirm hookData propagates through actions correctly

7. **Cross-chain deploy synchronization**: if a token launches on multiple chains, do we want governance NFT to be cross-chain-aware? Probably not for v1 — separate launches per chain.

8. **Token deployment via `TokenFactory`**:
   - Standard ERC-20 with mintable supply to deployer
   - Should it support optional features (taxable burn, blacklist, etc.) or stay strictly minimal?
   - **Recommendation: strictly minimal for v1.** Custom ERC-20s = bring-your-own-token via `existingToken`.

9. **Wrapper failure modes**: what if `TokenFactory` deploys but multicall reverts? Token is orphaned (deployed, no pool, no owner mint). Solution: deploy token AFTER multicall succeeds, or use try/catch.

10. **Allowlist application content**: should we apply for the full permission set (including `*ReturnDelta`) or start minimal and request more later? **Probably full set upfront** — re-applications harder than initial submission.

11. **Branding / positioning**: "Fair Launch Infrastructure" vs "Memecoin Pump Tool" — different audiences, risk profiles, allowlist friendliness with Uniswap.

12. **Integration with existing launchpads**: partnership with PinkSale (they integrate our hook as backend) vs competition? Probably *complementary* — we provide the hook tech, they provide UI distribution.

13. **Web3 UI tech stack**: Next.js + RainbowKit + Wagmi (standard) vs more specialized memecoin-launch-UX patterns. Out-of-scope for hook architecture but blocks user-facing product.

14. **Sandwich resistance for dynamic tax** (post-allowlist): tax changing within block can be exploited; add commit-reveal or rate limiting?
