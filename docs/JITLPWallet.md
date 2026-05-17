# JITLPWallet — Smart Wallet for Tactical V4 LP

> **Status:** Architecture draft. Not implemented.
> **Sibling spec:** `PositionManagerService.md` — works with externally-minted user NFTs via approve+subscribe. This spec describes a different product: a smart wallet that mints/manages its own LP positions directly through V4 PoolManager.

## Concept

A **smart wallet contract** that holds capital and creates concentrated LP positions in V4 pools on demand. Used for **tactical / opportunistic LP**: owner (or their off-chain bot) decides when to open a position at specific (poolKey, tickRange) parameters, betting on organic swap volume passing through that range to earn LP fees. Position is closed when owner decides — could be minutes, hours, or days later.

Despite the "JIT" name, **NOT** atomic JIT (open-swap-close in single TX). The wallet just exposes efficient `openPosition` / `closePosition` primitives — when and where to use them is the owner's strategy, executed via separate TXs.

**Key contrasts:**

| | PositionManagerService (sibling) | JITLPWallet (this) |
|--|----------------------------------|---------------------|
| Position origin | User-minted NFT (existing) | Wallet mints directly via `poolManager.modifyLiquidity` |
| Wrapper | PositionManager (PosM) | None — direct PoolManager interaction |
| Custody | User keeps NFT | Wallet owns position (no NFT) |
| Position identity | `tokenId` (ERC-721) | `bytes32 salt` (caller-chosen) |
| Audience | Retail LPs with existing positions | Power users / MEV operators / bots |
| Strategy | Automated rebalance via keeper | Manual / signal-driven by wallet owner |
| Multi-position | Per-NFT | Many positions via salt registry |

## Authorization: Singleton NFT pattern

The wallet itself **inherits ERC-721** with exactly **one** mintable token. The NFT is minted at deploy and represents the **sole ownership claim** on the wallet. Whoever holds that NFT controls the wallet's funds and operations.

```solidity
contract JITLPWallet is ERC721, IUnlockCallback {
    uint256 public constant OWNERSHIP_TOKEN_ID = 0;

    constructor(address initialOwner) ERC721("JITLPWallet Ownership", "JLPW") {
        _mint(initialOwner, OWNERSHIP_TOKEN_ID);
    }

    modifier onlyOwnerNFT() {
        require(ownerOf(OWNERSHIP_TOKEN_ID) == msg.sender, "Not NFT owner");
        _;
    }
}
```

**Properties:**
- **Singleton:** only one token ever exists. `_mint` overridden to revert post-constructor.
- **Burn-resistant:** `_burn` overridden to revert — burning would orphan the wallet.
- **Transferable:** standard ERC-721 transfer hands over wallet control atomically.
- **Composable:** ownership NFT can be sold, locked in timelock, owned by a multisig.

### Operator delegation

NFT owner delegates operational rights (`openPosition` / `closePosition` / `decreasePosition` / `pokePosition`) to bots without giving NFT custody:

```solidity
mapping(address => bool) public operators;

function setOperator(address op, bool allowed) external onlyOwnerNFT {
    operators[op] = allowed;
    emit OperatorSet(op, allowed);
}

modifier onlyAuthorized() {
    require(
        ownerOf(OWNERSHIP_TOKEN_ID) == msg.sender || operators[msg.sender],
        "Not authorized"
    );
    _;
}
```

Withdrawals stay `onlyOwnerNFT` — operators can manage positions but cannot drain capital.

**Operators auto-cleared on NFT transfer.** The ERC-721 `_update` override iterates and resets `operators[]` to prevent inherited delegations from harming the new owner.

## Direct PoolManager integration

Wallet implements `IUnlockCallback` and calls `poolManager.unlock(...)` directly. Pattern is identical to `src/SelfLPDirect.sol` in this repo — that contract already proves the direct-PoolManager LP pattern works (mint + settle + take + fee accounting via `feeGrowthInside`).

### Why direct vs PositionManager

| Aspect | Direct PoolManager | Via PositionManager |
|--------|---------------------|----------------------|
| Gas per open | ~100K-130K | ~150K-200K (NFT mint) |
| Gas per close | ~30K-60K | ~50K-100K (NFT burn) |
| NFT representation | none (don't need it) | yes (don't want it) |
| Multicall | not needed (we control unlock) | provided by PosM |
| Subscribe / observers | not needed | provided |
| External composability | none (intentional) | via NFT |
| Position identity | `bytes32 salt` (caller-chosen) | `tokenId` (auto-incrementing) |

**Direct wins clearly for this use case.** PosM features add gas + complexity without benefit.

## Pool Selection & Validation

`openPosition` consumes a full `PoolKey` (`currency0, currency1, fee, tickSpacing, hooks`). The operator typically starts from just two token addresses — many V4 pools can exist for the same pair (different fee tier, tickSpacing, and especially different hook addresses). The wallet does **not** discover pools on-chain. V4 `PoolManager` has no enumeration: `PoolId = keccak256(abi.encode(PoolKey))` is a one-way hash and the manager only stores `PoolId → state`. Reverse lookup is impossible without an external index.

**Responsibility split:** discovery lives off-chain (operator / bot), validation lives on-chain (this contract).

### Off-chain discovery (operator / bot)

Recommended path, in order:

1. **Primary — Uniswap Trading API `/quote`** (`https://trade-api.gateway.uniswap.org/v1`). Send a small test quote constrained to V4; the router replies with the `PoolKey` of the deepest pool it would route through. This is the cheapest signal for "best pool by liquidity".
   - Headers: `Content-Type: application/json`, `x-api-key: <UNISWAP_API_KEY>`, `x-universal-router-version: 2.0`.
   - Payload essentials: `tokenIn`, `tokenOut`, `amount` (small probe), `type: "EXACT_INPUT"`, `protocols: ["V4"]`, `hookOptions: "V4_HOOKS_INCLUSIVE"` (or `V4_NO_HOOKS` to force hookless pools only), `tokenInChainId` / `tokenOutChainId` from supported set (1, 8453, 42161, 10, 137, 130).
   - Parse: the chosen V4 route's pool descriptor → `currency0, currency1, fee, tickSpacing, hooks`. Re-canonicalize token order (`currency0 < currency1`) before forming the on-chain call.
2. **Fallback — V4 Subgraph** (TheGraph). GraphQL list of all pools for the pair with `liquidity`, `volumeUSD`, `fee`, `tickSpacing`, `hooks`. Use when Trading API is unavailable or when the operator wants to audit candidates manually.

Before submitting `openPosition`, the operator should also cross-check `PoolKey.hooks` against the [`Uniswap/hooklist`](https://github.com/Uniswap/hooklist) GitHub JSON registry. This is an off-chain courtesy duplicate of the on-chain check below.

### On-chain validation (this contract)

`openPosition` validates the provided `PoolKey` before any `modifyLiquidity` call:

1. **Hook whitelist (hybrid).** Hooks with `beforeSwapReturnDelta` / `afterSwapReturnDelta` can break LP economics — async swaps, custom curves, fee-stealing — so opening a tactical LP into an unknown hook is unacceptable.
   - Local mapping `allowedHooks[address]` managed by the NFT owner via `setHookAllowed`. Constructor seeds `allowedHooks[address(0)] = true` (standard hookless pools).
   - Optional external `hookRegistry` (an `IHookRegistry` view contract) for delegating policy to an on-chain source. If non-zero, the registry must also approve the hook.
   - Require: `allowedHooks[key.hooks] && (hookRegistry == address(0) || IHookRegistry(hookRegistry).isAllowed(key.hooks))`.
2. **Pool initialized.** `StateLibrary.getSlot0(key.toId()).sqrtPriceX96 != 0`. Catches operator typos in `tickSpacing` / `fee` / `hooks` that would otherwise resolve to a phantom `PoolId` and silently open a position no swap will ever touch.
3. **Minimum pool liquidity (optional).** `openPosition` accepts a `uint128 minPoolLiquidity` parameter (default `0`); if non-zero, require `StateLibrary.getLiquidity(key.toId()) >= minPoolLiquidity`.
4. **Slippage protection.** `openPosition` accepts `uint128 amount0Max` and `uint128 amount1Max`; the unlock callback reverts if the resulting `BalanceDelta` exceeds either bound. Protects against adverse price moves between TX submission and inclusion.

## Architecture Overview

```
Setup (one-time at deploy):
  - JITLPWallet deployed with initialOwner
  - Singleton NFT (tokenId=0) minted to initialOwner
  - allowedHooks[address(0)] = true
  - Wallet starts with zero balance

Capital management:
  - Owner / anyone deposits ETH and ERC-20 tokens to wallet
  - Owner (only) withdraws via withdrawERC20 / withdrawNative

Open position (called by NFT owner or operator):
  - openPosition(poolKey, tickLower, tickUpper, liquidity, salt,
                 minPoolLiquidity, amount0Max, amount1Max)
    → validate: allowedHooks + optional hookRegistry + getSlot0(poolId) != 0
                 + (if minPoolLiquidity > 0) getLiquidity(poolId) >= minPoolLiquidity
    → poolManager.unlock(OPEN, ...)
    → callback: modifyLiquidity(+L) → BalanceDelta < 0 (we owe)
    → enforce |delta0| <= amount0Max && |delta1| <= amount1Max
    → _settleDelta — pay from wallet balance
    → record positions[salt] = {key, tickLower, tickUpper, liquidity, openedAt}

Position sits:
  - Organic swap volume in the pool crosses our range
  - Fees accrue to our position (tracked by V4 via feeGrowthInside)
  - No active management from wallet during this period

Close position (called by NFT owner or operator):
  - closePosition(salt)
    → poolManager.unlock(CLOSE, ...)
    → callback: modifyLiquidity(-L) → BalanceDelta > 0 (we're owed)
    → _takeDelta — receive principal + accumulated fees
    → delete positions[salt]
    → emit PositionClosed with PnL

Poke (collect fees without closing):
  - pokePosition(salt)
    → poolManager.unlock(POKE, ...)
    → modifyLiquidity(0) — accounting-only; releases fees-owed delta
    → take fee amounts to wallet
```

## API Surface

```solidity
contract JITLPWallet is ERC721, IUnlockCallback, ReentrancyGuard {
    // ─── Constructor / immutables ───
    IPoolManager public immutable POOL_MANAGER;
    uint256 public constant OWNERSHIP_TOKEN_ID = 0;

    // ─── State ───
    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint64 openedAt;
    }
    mapping(bytes32 => Position) public positions;
    bytes32[] public openSalts;  // enumerable list of open positions

    mapping(address => bool) public operators;
    address[] internal _operatorList;  // tracked for auto-clear on NFT transfer

    // ─── Hook policy (see "Pool Selection & Validation") ───
    mapping(address => bool) public allowedHooks;  // local whitelist
    address public hookRegistry;                   // optional IHookRegistry; 0 disables

    // ─── Capital management ───
    receive() external payable;  // anyone can deposit native
    function depositERC20(address token, uint256 amount) external;  // anyone can deposit
    function withdrawERC20(address token, uint256 amount, address to)
        external onlyOwnerNFT nonReentrant;
    function withdrawNative(uint256 amount, address payable to)
        external onlyOwnerNFT nonReentrant;

    // ─── Position operations ───
    function openPosition(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bytes32 salt,
        uint128 minPoolLiquidity,  // 0 disables the liquidity-floor check
        uint128 amount0Max,        // slippage bound on currency0
        uint128 amount1Max         // slippage bound on currency1
    ) external onlyAuthorized nonReentrant;

    function closePosition(bytes32 salt) external onlyAuthorized nonReentrant;
    function decreasePosition(bytes32 salt, uint128 deltaLiquidity)
        external onlyAuthorized nonReentrant;
    function pokePosition(bytes32 salt) external onlyAuthorized nonReentrant;

    // ─── Delegation ───
    function setOperator(address op, bool allowed) external onlyOwnerNFT;

    // ─── Hook policy ───
    function setHookAllowed(address hook, bool allowed) external onlyOwnerNFT;
    function setHookRegistry(address registry) external onlyOwnerNFT;

    // ─── ERC-721 hardening ───
    // Override _update to clear operators on transfer and forbid additional mints
    // Override _burn to revert (singleton must not be destroyed)

    // ─── V4 unlock callback ───
    function unlockCallback(bytes calldata data) external returns (bytes memory);

    // ─── Views ───
    function positionOf(bytes32 salt) external view returns (Position memory);
    function openPositionCount() external view returns (uint256);
    function ownerNFTHolder() external view returns (address) {
        return ownerOf(OWNERSHIP_TOKEN_ID);
    }
}

interface IHookRegistry {
    function isAllowed(address hook) external view returns (bool);
}
```

Constructor:

```solidity
constructor(address initialOwner, IPoolManager poolManager_)
    ERC721("JITLPWallet Ownership", "JLPW")
{
    POOL_MANAGER = poolManager_;
    allowedHooks[address(0)] = true;
    _mint(initialOwner, OWNERSHIP_TOKEN_ID);
}
```

## Position Identity: salt-based

Positions in V4 PoolManager are keyed by `(owner, tickLower, tickUpper, salt)`. Since `owner = address(wallet)` for all positions in this wallet, **`salt` is what distinguishes them**. Caller chooses the salt (`bytes32`) when opening.

Collision: if caller reuses a salt while a position is still open, `openPosition` reverts. Enforced via `require(positions[salt].liquidity == 0)`.

## Capital flow

- Deposit: ETH via `receive()` payable; ERC-20 via `depositERC20` (pull pattern). Anyone can deposit (donation-friendly).
- Open position: settled from wallet's token balance, no external pull needed.
- Close position: tokens returned to wallet balance.
- Withdraw: only NFT owner.

## NFT transfer semantics

Transferring the ownership NFT (`safeTransferFrom`) atomically transfers all wallet control to the new owner:
- All open positions stay with the wallet (not the old NFT holder).
- Balance stays in wallet.
- Operators are **auto-cleared** in the ERC-721 `_update` hook so the new owner does not inherit unexpected delegations.
- New NFT owner has full `onlyOwnerNFT` rights.

## Critical Files to Create

| File | Purpose |
|------|---------|
| `src/JITLPWallet.sol` | Main contract; ERC-721 (singleton) + IUnlockCallback + position management |
| `src/lib/PositionMath.sol` | Tick-spacing snapping, liquidity-from-amounts helpers (reuse from `SelfLPLib` if compatible) |
| `script/DeployWallet.s.sol` | Deploy single wallet |
| `test/JITLPWallet.t.sol` | Forge tests: lifecycle, auth, edge cases |
| `test/JITLPWallet.fork.t.sol` | Fork tests against live PoolManager + real pool |

## Reused Patterns

- **`src/SelfLPDirect.sol`** (own repo) — direct PoolManager LP pattern; settle/take/unlock-callback dispatcher; serves as primary template
- **`src/lib/SelfLPLib.sol`** — `computeRange`, `previewFeesETH` math utilities
- **`@uniswap/v4-core/test/utils/CurrencySettler.sol`** — `Currency.settle()` and `poolManager.take()` patterns for native + ERC-20
- **OpenZeppelin `ERC721`** — base for singleton NFT
- **OpenZeppelin `ReentrancyGuard`** — withdraw + position operations protection
- **`@uniswap/v4-core/src/interfaces/IUnlockCallback.sol`** — interface for unlock callback receiver
- **`@uniswap/v4-core/src/libraries/StateLibrary.sol`** — `getSlot0`, `getLiquidity` for pool validation

## Architectural Decisions

| Topic | Decision |
|-------|----------|
| Operators feature | Yes — owner runs bots that react fast without owner signing every TX |
| Operator auto-clear on NFT transfer | Yes — cleared in ERC-721 `_update` hook |
| Salt collision | Revert if `positions[salt].liquidity != 0` |
| Multi-pool positions | Yes — `Position` struct stores `PoolKey`; arbitrary pools supported |
| `pokePosition` | Explicit call, `modifyLiquidity(0)` releases fees-owed delta |
| Permissionless triggers | No — owner / operators only; this is a personal tool |
| Single owner NFT | Yes — singleton, exactly one token ever; new wallet = new contract deploy |
| Pool discovery | Off-chain (operator/bot via Trading API `/quote`); on-chain validates `allowedHooks` + pool existence |
| Hook whitelist | Local `allowedHooks` mapping (default `{address(0)}`) + optional external `hookRegistry` |
| Slippage protection | `openPosition` takes `amount0Max` / `amount1Max`; callback reverts on exceed |
| Reentrancy | `nonReentrant` on `withdraw*` and on position operations (`open` / `close` / `decrease` / `poke`) |

## Verification Plan

### Phase 1: Local Forge tests
```bash
forge test --match-path ./test/JITLPWallet.t.sol -vv
```

Test cases:
- `test_deploy_mintsSingletonNFTToOwner`
- `test_singletonNFT_cannotMintMore`
- `test_singletonNFT_cannotBurn`
- `test_nftTransfer_handsOverControl`
- `test_nftTransfer_clearsOperators`
- `test_depositERC20_anyoneCanDeposit`
- `test_withdrawERC20_byNFTOwner_succeeds`
- `test_withdrawERC20_byNonOwner_reverts`
- `test_openPosition_byNFTOwner_succeeds`
- `test_openPosition_byOperator_succeeds`
- `test_openPosition_byNonAuthorized_reverts`
- `test_openPosition_saltCollision_reverts`
- `test_openPosition_insufficientBalance_reverts`
- `test_openPosition_disallowedHook_reverts`
- `test_openPosition_allowedHook_succeeds`
- `test_openPosition_uninitializedPool_reverts`
- `test_openPosition_belowMinLiquidity_reverts`
- `test_openPosition_exceedsAmount0Max_reverts`
- `test_openPosition_exceedsAmount1Max_reverts`
- `test_setHookAllowed_byOwner_succeeds`
- `test_setHookAllowed_byNonOwner_reverts`
- `test_setHookRegistry_blocksWhenRegistryRejects`
- `test_hookRegistryZero_fallsBackToLocalWhitelist`
- `test_closePosition_byNFTOwner_succeeds_returnsCapitalPlusFees`
- `test_decreasePosition_partial_succeeds`
- `test_pokePosition_collectsFeesOnly`
- `test_openMultiplePositions_independentSalts`
- `test_setOperator_byOwner_succeeds`
- `test_setOperator_byNonOwner_reverts`

### Phase 2: Mainnet fork tests
```bash
forge test --fork-url $BASE_RPC --match-path ./test/JITLPWallet.fork.t.sol
```
- Open position in real WETH/USDC pool on Base
- Trigger swap from another address through our range
- Close and verify fees accrued correctly
- PnL accounting end-to-end

### Phase 3: Testnet deployment
- Deploy on Base Sepolia
- Manual position open / close cycles
- Verify NFT transfer semantics (transfer ownership to second address, second address can operate)

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Wallet contract bug → all funds drained | 🔴 Critical | Comprehensive audit; reuse audited `SelfLPDirect` patterns |
| Lost NFT = lost wallet access permanently | 🔴 High | Standard NFT custody best practices; doc warns explicitly |
| Operator misuse — opens/closes with adverse params | 🟡 Medium | Operators cannot withdraw; slippage bounds limit damage; revoke if needed |
| IL on long-held positions | 🟡 Medium | Inherent risk of LP; not a contract risk |
| Salt collision unintentional reuse | 🟢 Low | Revert on collision |
| Singleton NFT mint loophole | 🔴 High | Override `_mint` to forbid post-constructor minting; tests verify |
| Direct PoolManager flash-accounting bug | 🟡 Medium | Reuse battle-tested settle/take patterns from `SelfLPDirect` |
| ERC-721 transfer reentrancy via `onERC721Received` | 🟡 Medium | `nonReentrant` on capital ops |
| Operator opens position in pool with malicious hook → LP economics broken | 🔴 High | `allowedHooks` whitelist + optional `hookRegistry` validated in `openPosition` |
| Operator typo in `PoolKey` → position opens in phantom uninitialized pool | 🟡 Medium | `openPosition` requires `StateLibrary.getSlot0(poolId).sqrtPriceX96 != 0` |
| Adverse price move between submit and inclusion | 🟡 Medium | `amount0Max` / `amount1Max` slippage bounds enforced in unlock callback |
