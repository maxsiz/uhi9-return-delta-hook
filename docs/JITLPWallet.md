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

## Authorization: Singleton NFT pattern (Envelop V2 style)

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
- **Singleton:** only one token ever exists (`mint` is overridden / disabled post-constructor)
- **Transferable:** standard ERC-721 transfer hands over wallet control atomically
- **Composable:** the ownership NFT can be sold, used as collateral, transferred to multisig, etc.
- **Burn-resistant:** burning the NFT would orphan the wallet — likely override `_burn` to revert

### Why singleton NFT (vs simple `owner` address)

- **Transferable in one ERC-721 standard call** (`transferFrom`) — no custom `transferOwnership` function needed
- **Composable** — wallet ownership can be sold on NFT marketplaces, locked in timelocks, owned by other smart contracts
- **Discoverable** — indexers see standard `Transfer` events; ownership history is queryable
- **Atomic transfer of all state** — new owner inherits all open positions, balances, operator delegations

### Optional: operator delegation

NFT owner can delegate operational rights (`openPosition` / `closePosition`) to bots without giving NFT custody:

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

Withdrawals stay `onlyOwnerNFT` (operators can manage positions but not drain capital).

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
2. **Fallback — V4 Subgraph** (TheGraph). GraphQL list of all pools for the pair with `liquidity`, `volumeUSD`, `fee`, `tickSpacing`, `hooks`. Use when Trading API is unavailable or when the operator wants to audit candidates manually (e.g., second-deepest pool with better fee tier).
3. **Future — self-indexed `Initialize` events.** Out of scope for v1; documented as the autonomy path if dependence on external APIs becomes unacceptable.

Before submitting `openPosition`, the operator should also cross-check `PoolKey.hooks` against the [`Uniswap/hooklist`](https://github.com/Uniswap/hooklist) GitHub JSON registry. This is an off-chain courtesy duplicate of the on-chain check below.

### On-chain validation (this contract)

`openPosition` validates the provided `PoolKey` before any `modifyLiquidity` call:

1. **Hook whitelist (hybrid).** Hooks with `beforeSwapReturnDelta` / `afterSwapReturnDelta` can break LP economics — async swaps, custom curves, fee-stealing — so opening a tactical LP into an unknown hook is unacceptable.
   - Local mapping `allowedHooks[address]` managed by the NFT owner via `setHookAllowed`. Constructor seeds `allowedHooks[address(0)] = true` (standard hookless pools).
   - Optional external `hookRegistry` (an `IHookRegistry` view contract) for delegating policy to an on-chain source. If non-zero, the registry must also approve the hook. As of 2026-05 `Uniswap/hooklist` is GitHub-only with no canonical on-chain mirror — interface is reserved but `hookRegistry` stays `address(0)` until such a contract exists.
   - Require: `allowedHooks[key.hooks] && (hookRegistry == address(0) || IHookRegistry(hookRegistry).isAllowed(key.hooks))`.
2. **Pool initialized.** `StateLibrary.getSlot0(key.toId()).sqrtPriceX96 != 0`. Catches operator typos in `tickSpacing` / `fee` / `hooks` that would otherwise resolve to a phantom `PoolId` and silently open a position no swap will ever touch.
3. **Minimum pool liquidity (optional).** `openPosition` accepts a `uint128 minPoolLiquidity` parameter (default `0`); if non-zero, require `StateLibrary.getLiquidity(key.toId()) >= minPoolLiquidity`. Lets the bot refuse "empty" pools.

On-chain brute-force discovery (probing common `(fee, tickSpacing, address(0))` combinations via `getSlot0`) is **explicitly out of scope** — gas and complexity not justified for coverage of the hookless subset only.

## Architecture Overview

```
Setup (one-time at deploy):
  - JITLPWallet deployed with initialOwner
  - Singleton NFT (tokenId=0) minted to initialOwner
  - Wallet starts with zero balance

Capital management:
  - Owner / anyone deposits ETH and ERC-20 tokens to wallet
  - Owner (only) withdraws via withdrawERC20 / withdrawNative

Open position (called by NFT owner or operator):
  - openPosition(poolKey, tickLower, tickUpper, liquidity, salt, minPoolLiquidity)
    → validate: allowedHooks + optional hookRegistry + getSlot0(poolId) != 0
                 + (if minPoolLiquidity > 0) getLiquidity(poolId) >= minPoolLiquidity
    → poolManager.unlock(OPEN, ...)
    → callback: modifyLiquidity(+L) → BalanceDelta < 0 (we owe)
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

Optional: poke (collect fees without closing):
  - pokePosition(salt)
    → poolManager.unlock(POKE, ...)
    → modifyLiquidity(0) — accounting-only; releases fees-owed delta
    → take fee amounts to wallet
```

## API Surface

```solidity
contract JITLPWallet is ERC721, IUnlockCallback {
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
    
    // ─── Hook policy (see "Pool Selection & Validation") ───
    mapping(address => bool) public allowedHooks;  // local whitelist
    address public hookRegistry;                   // optional IHookRegistry; 0 disables
    
    // ─── Capital management ───
    receive() external payable;  // anyone can deposit native
    function depositERC20(address token, uint256 amount) external;  // anyone can deposit
    function withdrawERC20(address token, uint256 amount, address to) external onlyOwnerNFT;
    function withdrawNative(uint256 amount, address payable to) external onlyOwnerNFT;
    
    // ─── Position operations ───
    function openPosition(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bytes32 salt,
        uint128 minPoolLiquidity  // 0 disables the liquidity-floor check
    ) external onlyAuthorized;
    
    function closePosition(bytes32 salt) external onlyAuthorized;
    
    function decreasePosition(bytes32 salt, uint128 deltaLiquidity) external onlyAuthorized;
    
    function pokePosition(bytes32 salt) external onlyAuthorized;  // collect fees only
    
    // ─── Delegation ───
    function setOperator(address op, bool allowed) external onlyOwnerNFT;
    
    // ─── Hook policy ───
    function setHookAllowed(address hook, bool allowed) external onlyOwnerNFT;
    function setHookRegistry(address registry) external onlyOwnerNFT;
    
    // ─── ERC-721 hardening ───
    // Override _update / _mint to prevent additional tokenIds
    // Override _burn to prevent burning the singleton
    
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

Constructor seeds the hook whitelist with the hookless slot:

```solidity
constructor(address initialOwner, IPoolManager poolManager_) ERC721(...) {
    POOL_MANAGER = poolManager_;
    allowedHooks[address(0)] = true;
    _mint(initialOwner, OWNERSHIP_TOKEN_ID);
}
```

## Position Identity: salt-based

Positions in V4 PoolManager are keyed by `(owner, tickLower, tickUpper, salt)`. Since `owner = address(wallet)` for all positions in this wallet, **`salt` is what distinguishes them**.

Caller chooses the salt (`bytes32`) when opening. Conventions:
- Random salt for unrelated positions
- Structured salt (e.g., `keccak256("strategy-X", tickLower, openedAt)`) for traceability
- Wallet doesn't enforce — operator's responsibility

Collision: if caller reuses a salt while a position is still open, `openPosition` should revert (existing position would conflict). Enforced via `require(positions[salt].liquidity == 0)`.

## Capital flow

- Deposit: ETH via `receive()` payable; ERC-20 via `depositERC20` (pull pattern). Anyone can deposit (donation-friendly).
- Open position: settled from wallet's token balance (no external pull needed).
- Close position: tokens returned to wallet balance.
- Withdraw: only NFT owner.

## NFT transfer semantics

Transferring the ownership NFT (`safeTransferFrom`) atomically transfers all wallet control to the new owner:
- All open positions stay with the wallet (not the old NFT holder)
- Operators delegated by old owner remain operators
- Balance stays in wallet
- New NFT owner has full `onlyOwnerNFT` rights

**Caveat:** operators set by the old owner are NOT auto-revoked. New owner should review and revoke any unexpected operators after taking ownership (or wallet could implement auto-clear on NFT transfer via `_beforeTokenTransfer` hook — design decision).

## Critical Files to Create

| File | Purpose |
|------|---------|
| `src/JITLPWallet.sol` | Main contract; ERC-721 (singleton) + IUnlockCallback + position management |
| `src/JITLPWalletFactory.sol` | (optional) Factory for deploying wallets per-owner via CREATE2 |
| `src/lib/PositionMath.sol` | Tick-spacing snapping, liquidity-from-amounts helpers (reuse from `SelfLPLib` if compatible) |
| `script/DeployWallet.s.sol` | Deploy single wallet |
| `script/DeployFactory.s.sol` | Deploy factory (if used) |
| `test/JITLPWallet.t.sol` | Forge tests: lifecycle, auth, edge cases |
| `test/JITLPWallet.fork.t.sol` | Fork tests against live PoolManager + real fat pool |

## Reused Patterns

- **`src/SelfLPDirect.sol`** (own repo) — direct PoolManager LP pattern; settle/take/unlock-callback dispatcher; serves as primary template
- **`src/lib/SelfLPLib.sol`** — `computeRange`, `previewFeesETH` math utilities
- **`@uniswap/v4-core/test/utils/CurrencySettler.sol`** — `Currency.settle()` and `poolManager.take()` patterns for native + ERC-20
- **OpenZeppelin `ERC721`** — base for singleton NFT
- **`@uniswap/v4-core/src/interfaces/IUnlockCallback.sol`** — interface for unlock callback receiver

## Open Design Decisions

1. **Operators feature in v1?**
   - Yes — owner runs bots that need to react fast without owner signing every TX
   - Alternative: skip operators in v1, owner calls everything themselves

2. **Auto-clear operators on NFT transfer?**
   - Pro: safer for new NFT owner (no inherited delegations)
   - Con: complexity in `_beforeTokenTransfer` hook
   - Recommendation: yes, auto-clear on transfer for safety

3. **Position salt collision handling?**
   - Recommendation: revert if salt already in use (current liquidity > 0)

4. **Multiple positions across multiple pools?**
   - Yes — `Position` struct stores `PoolKey`, wallet supports arbitrary pools
   - Each position is independent

5. **Fee collection without closing — `pokePosition`?**
   - Yes — useful for long-held positions to harvest fees periodically
   - Implementation: `modifyLiquidity(0)` releases fees-owed delta

6. **Open multiple positions in one TX (batched)?**
   - v1: separate TXs per position (simpler)
   - v2: batch open / close via array param

7. **Atomic open + something + close ("classic" JIT)?**
   - v1: not exposed — would require taking arbitrary `innerCall` (security risk)
   - v2: dedicated `jitCycle` function with vetted inner targets, if there's demand

8. **Factory or one-off deploy?**
   - v1: one-off — each owner deploys their own wallet
   - v2: factory with CREATE2 for predictable addresses + easier off-chain tooling

9. **Permissionless triggering with reward?**
   - No — this is a personal tool. Owner / operators only.

10. **Single owner NFT vs multiple NFTs in collection?**
    - Singleton — exactly one token. New "wallet" = new contract deploy.

11. **Pool selection — on-chain or off-chain?**
    - **Decision: off-chain discovery + on-chain validation.** Operator/bot picks `PoolKey` via Trading API `/quote` (primary) or V4 Subgraph (fallback). Contract validates the supplied key against `allowedHooks` / `hookRegistry` and asserts the pool is initialized.
    - On-chain brute-force probing of fee/tickSpacing combinations is out of scope — covers only the hookless subset and adds gas for no real win.

12. **Hook whitelist policy?**
    - **Decision: local `allowedHooks` mapping + optional external `hookRegistry`.** Default seeds `address(0)` only (standard hookless pools). Owner adds vetted hooks per use case. `hookRegistry` is `address(0)` initially; reserved for a future on-chain mirror of `Uniswap/hooklist` or a custom registry.

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
- `test_nftTransfer_clearsOperators` (if auto-clear chosen)
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
| Wallet contract bug → all funds drained | 🔴 Critical | Comprehensive audit; reuse audited SelfLPDirect patterns |
| Lost NFT = lost wallet access permanently | 🔴 High | Standard NFT custody best practices; doc warns; v2 may add recovery mechanism |
| Operator misuse — drains via opening + closing positions with adverse params | 🟡 Medium | Operators can't withdraw; worst case loses some funds to bad LP; revoke if needed |
| IL on long-held positions | 🟡 Medium | Inherent risk of LP; not a contract risk |
| Salt collision unintentional reuse | 🟢 Low | Revert on collision; doc emphasizes salt management |
| Singleton NFT mint loophole | 🔴 High | Override `_mint` to forbid post-constructor minting; tests verify |
| Direct PoolManager flash-accounting bug | 🟡 Medium | Reuse battle-tested settle/take patterns from `SelfLPDirect` |
| ERC-721 transfer reentrancy via `onERC721Received` | 🟡 Medium | Use `nonReentrant` modifier on capital ops; standard OZ guard |
| Operator opens position in pool with malicious hook → LP economics broken (async swaps, custom curve, fee-stealing) | 🔴 High | `allowedHooks` whitelist + optional `hookRegistry` validated in `openPosition`; default whitelist is `{address(0)}` |
| Operator typo in `PoolKey` → position opens in phantom uninitialized pool | 🟡 Medium | `openPosition` requires `StateLibrary.getSlot0(poolId).sqrtPriceX96 != 0` |

## Out of Scope (v1)

- Atomic JIT cycle (open + inner action + close in one TX) — v2
- Permissionless triggers with bounty — v2
- Multiple ownership tokens / shared ownership — by design, singleton only
- ERC-4626 / share token wrappers — wallet is single-owner, no shares needed
- Cross-chain positions
- Strategy automation in-contract — strategy lives off-chain (bot via operator role)
- Position migration / merger / split helpers — keep base minimal; helpers can live outside

## Open Questions for Future Sessions

1. **Factory pattern**: deploy via factory for predictable CREATE2 addresses, or one-off deploys?
2. **Operator auto-clear on NFT transfer**: implement in `_beforeTokenTransfer` hook?
3. **`pokePosition` semantics**: does it need explicit user input, or auto-trigger on close?
4. **NFT metadata / tokenURI**: should the NFT expose info about wallet state (open positions, balance) via tokenURI? Useful for OpenSea / wallet UIs.
5. **Reentrancy guards**: which functions need them? `withdraw*` definitely; others via callback?
6. **Slippage protection**: should `openPosition` accept `amount0Max` / `amount1Max` like PosM does, to protect against price moves between TX submission and inclusion?
7. **Gas profiling**: target gas budget for `openPosition` + `closePosition` cycle on Mainnet vs L2.
