// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {SelfLPLib} from "./lib/SelfLPLib.sol";

/// @title SelfLPDirect — auto-compounding self-LP hook (baseline variant).
/// @notice Owns its own concentrated LP position in the pool it is attached to. On every swap,
///         a view-side check estimates accrued fees in ETH; once the threshold is crossed the
///         hook pokes the position to claim fees, burns the old range, and re-mints around the
///         current tick — all under the swap's existing PoolManager unlock.
///
/// @dev This is the **baseline** of three planned variants. It demonstrates the most direct
///      custom-accounting style:
///        • position owned at `(address(this), tickLower, tickUpper, salt = 0)` — no
///          PositionManager, no NFT;
///        • view-side fee preview via `StateLibrary.getFeeGrowthInside` + `getPositionInfo` —
///          no state mutation in the no-op path;
///        • fee claim via `modifyLiquidity(liquidityDelta = 0)` ("poke");
///        • principal/fee movement via `take` and `CurrencySettler.settle`.
///
///      The reinvest path skips the optional rebalance swap mentioned in the plan: surplus on
///      one side stays as idle inventory and is folded into the next reinvest. Variants
///      `SelfLPAfterDelta` and `SelfLPBeforeInternalize` (forthcoming) layer additional
///      accounting techniques on top of this baseline.
contract SelfLPDirect is BaseHook, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // -----------------------------------------------------------------------
    // Configuration (immutable)
    // -----------------------------------------------------------------------

    /// @notice Address authorized to seed the hook's initial position.
    address public immutable owner;

    /// @notice Half-width of the maintained concentrated range, in ticks (snapped to spacing).
    int24 public immutable halfWidthTicks;

    /// @notice Minimum accrued-fee value (denominated in ETH) that triggers a reinvest.
    uint256 public immutable feeThresholdETH;

    /// @notice Dynamic LP fee applied on every swap (hundredths of a bip; e.g. 3000 = 0.30%).
    /// @dev The pool is opened with the dynamic-fee flag, so a concrete fee must be installed
    ///      via `updateDynamicLPFee`. We do that once in `_afterInitialize`.
    uint24 public immutable lpFee;

    /// @dev Salt for the hook-owned position. Single position per hook → fixed at zero.
    bytes32 internal constant POSITION_SALT = bytes32(0);

    // -----------------------------------------------------------------------
    // Pool / position state (set after _beforeInitialize and seedPosition)
    // -----------------------------------------------------------------------

    PoolKey internal _poolKey;
    PoolId internal _poolId;
    bool public ethIsCurrency0;
    int24 public currentTickLower;
    int24 public currentTickUpper;
    uint128 public currentLiquidity;
    bool public seeded;

    // -----------------------------------------------------------------------
    // Errors / events
    // -----------------------------------------------------------------------

    error MustUseDynamicFee();
    error PoolShouldBeWithEth();
    error AlreadyInitialized();
    error AlreadySeeded();
    error NotOwner();
    error WrongMsgValue();
    error NoLiquidity();

    /// @notice Emitted on every successful reinvest cycle.
    /// @param oldLower Previous range lower tick.
    /// @param oldUpper Previous range upper tick.
    /// @param newLower New range lower tick (snapped).
    /// @param newUpper New range upper tick (snapped).
    /// @param newLiquidity Liquidity minted into the new range.
    event PositionRebalanced(
        int24 oldLower, int24 oldUpper, int24 newLower, int24 newUpper, uint128 newLiquidity
    );

    event DebugEvent(uint256 point);

    /// @dev unlockCallback action discriminator. Currently only SEED uses it; the reinvest path
    ///      runs inside the swapper's already-open unlock and does not re-enter `unlock()`.
    enum Action {
        SEED
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(
        IPoolManager _manager,
        address _owner,
        int24 _halfWidthTicks,
        uint256 _feeThresholdETH,
        uint24 _lpFee
    ) BaseHook(_manager) {
        owner = _owner;
        halfWidthTicks = _halfWidthTicks;
        feeThresholdETH = _feeThresholdETH;
        lpFee = _lpFee;
    }

    /// @dev Required so `poolManager.take(currencyEth, hook, ...)` can land native ETH here.
    receive() external payable {}

    // -----------------------------------------------------------------------
    // Hook permissions
    // -----------------------------------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------------------------------
    // Pool init guard — copied from InternalSwapPool: dynamic-fee + ETH side
    // -----------------------------------------------------------------------

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (PoolId.unwrap(_poolId) != bytes32(0)) revert AlreadyInitialized();

        if (key.fee != 0x800000) revert MustUseDynamicFee();

        bool eth0 = Currency.unwrap(key.currency0) == address(0);
        bool eth1 = Currency.unwrap(key.currency1) == address(0);
        if (!eth0 && !eth1) revert PoolShouldBeWithEth();

        _poolKey = key;
        _poolId = key.toId();
        ethIsCurrency0 = eth0;

        return this.beforeInitialize.selector;
    }

    /// @dev The dynamic-fee flag opens the pool with no concrete fee — install ours now so the
    ///      LP position actually accrues fees from swaps.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        poolManager.updateDynamicLPFee(key, lpFee);
        return this.afterInitialize.selector;
    }

    // -----------------------------------------------------------------------
    // Owner-funded initial mint
    // -----------------------------------------------------------------------

    /// @notice Seed the hook's first concentrated position. Callable once by `owner`.
    /// @param amount0 Amount of currency0 to deposit (must equal msg.value if currency0 is ETH).
    /// @param amount1 Amount of currency1 to deposit (must equal msg.value if currency1 is ETH).
    function seedPosition(uint256 amount0, uint256 amount1) external payable {
        if (msg.sender != owner) revert NotOwner();
        if (seeded) revert AlreadySeeded();

        if (ethIsCurrency0) {
            if (msg.value != amount0) revert WrongMsgValue();
            if (amount1 > 0) {
                IERC20Minimal(Currency.unwrap(_poolKey.currency1)).transferFrom(msg.sender, address(this), amount1);
            }
        } else {
            if (msg.value != amount1) revert WrongMsgValue();
            if (amount0 > 0) {
                IERC20Minimal(Currency.unwrap(_poolKey.currency0)).transferFrom(msg.sender, address(this), amount0);
            }
        }

        (uint160 sqrtPriceX96, int24 tickCurrent,,) = poolManager.getSlot0(_poolId);
        (int24 newLower, int24 newUpper) =
            SelfLPLib.computeRange(tickCurrent, halfWidthTicks, _poolKey.tickSpacing);

        uint128 newLiq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(newLower),
            TickMath.getSqrtPriceAtTick(newUpper),
            amount0,
            amount1
        );
        if (newLiq == 0) revert NoLiquidity();

        // Unlock the manager to mint the first position. We can re-enter unlock here because
        // seedPosition is called from the outside (no enclosing unlock).
        poolManager.unlock(abi.encode(Action.SEED, newLower, newUpper, newLiq));

        currentTickLower = newLower;
        currentTickUpper = newUpper;
        currentLiquidity = newLiq;
        seeded = true;
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only invoked via `seedPosition`. The reinvest path runs inside the swapper's
    ///      unlock and does NOT call `poolManager.unlock` again — so this dispatcher only
    ///      handles SEED.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        // `NotPoolManager` is inherited from ImmutableState (via BaseHook).
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        (Action action, int24 tL, int24 tU, uint128 liq) = abi.decode(data, (Action, int24, int24, uint128));
        if (action == Action.SEED) {
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                _poolKey,
                ModifyLiquidityParams({tickLower: tL, tickUpper: tU, liquidityDelta: int256(uint256(liq)), salt: POSITION_SALT}),
                ""
            );
            _settleDelta(delta);
        }
        return "";
    }

    // -----------------------------------------------------------------------
    // After-swap: threshold gate + reinvest
    // -----------------------------------------------------------------------

    function _afterSwap(
        address, /*sender*/
        PoolKey calldata key,
        SwapParams calldata, /*params*/
        BalanceDelta, /*delta*/
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, int128) {
        // Fast no-op until the position is funded.
        if (!seeded) return (this.afterSwap.selector, 0);
        
        // View-side fee preview — no SSTORE, no unlock — keeps the no-op path cheap.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_poolId);
        uint256 feesEth = SelfLPLib.previewFeesETH(
            SelfLPLib.PreviewParams({
                manager: poolManager,
                poolId: _poolId,
                owner: address(this),
                tickLower: currentTickLower,
                tickUpper: currentTickUpper,
                salt: POSITION_SALT,
                ethIsCurrency0: ethIsCurrency0,
                sqrtPriceX96: sqrtPriceX96
            })
        );
        if (feesEth < feeThresholdETH) return (this.afterSwap.selector, 0);
        
        _reinvest(key, sqrtPriceX96);
        return (this.afterSwap.selector, 0);
    }

    /// @dev Reinvest cycle, executed inside the swapper's existing unlock.
    ///
    ///      Critical accounting note: we do NOT physically `take` after burn. Doing so would
    ///      attempt to withdraw the full position size from PoolManager — but the swap that
    ///      triggered this `afterSwap` is mid-flight: the swapper's input token has not yet been
    ///      settled, so the manager's physical balance is still the pre-swap reserve, less than
    ///      what `take(burnAmount)` would request. Reverts with `OutOfFunds`.
    ///
    ///      Instead, we keep the burn proceeds as a virtual `+delta` and net them against the
    ///      mint's `-delta` directly. Only the residue (a small dust amount) hits PoolManager
    ///      physically via `take`/`settle` at the end. This is the canonical flash-accounting
    ///      pattern for in-callback rebalancing.
    ///
    ///      Sequence:
    ///        1. Burn old position → `+burnDelta` accumulates on hook's account (no physical move).
    ///        2. Compute new range around post-swap tick.
    ///        3. Compute target liquidity from `(burnDelta amounts) + idle balance`.
    ///        4. Mint at new range → `-mintDelta` subtracts from hook's account.
    ///        5. Net `burnDelta + mintDelta`: each side may be positive (take) or negative
    ///           (settle physically from idle).
    ///      The optional rebalance swap (plan §4) is intentionally omitted in the baseline.
    function _reinvest(PoolKey calldata key, uint160 sqrtPriceX96) internal {
        int24 oldLower = currentTickLower;
        int24 oldUpper = currentTickUpper;
        uint128 oldLiq = currentLiquidity;
        
        // 1. Burn old position. burnDelta > 0 on both sides (principal + accrued fees).
        (BalanceDelta burnDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: oldLower,
                tickUpper: oldUpper,
                liquidityDelta: -int256(uint256(oldLiq)),
                salt: POSITION_SALT
            }),
            ""
        );

        // 2. New range around the post-swap tick.
        (, int24 tickAfter,,) = poolManager.getSlot0(_poolId);
        (int24 newLower, int24 newUpper) =
            SelfLPLib.computeRange(tickAfter, halfWidthTicks, key.tickSpacing);

        // 3. Total amount available to mint = +delta from burn + idle physical balance.
        uint256 avail0 = uint256(uint128(burnDelta.amount0())) + key.currency0.balanceOfSelf();
        uint256 avail1 = uint256(uint128(burnDelta.amount1())) + key.currency1.balanceOfSelf();

        uint128 newLiq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(newLower),
            TickMath.getSqrtPriceAtTick(newUpper),
            avail0,
            avail1
        );
        if (newLiq == 0) {
            // Edge case: no mintable liquidity. Take the burn proceeds physically and bail.
            _takeDelta(burnDelta);
            currentLiquidity = 0;
            return;
        }

        // 4. Mint at new range. mintDelta < 0 on both sides (debt to manager).
        (BalanceDelta mintDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: newLower,
                tickUpper: newUpper,
                liquidityDelta: int256(uint256(newLiq)),
                salt: POSITION_SALT
            }),
            ""
        );

        // 5. Settle the netted delta. Each side independently take vs settle.
        _settleDelta(burnDelta + mintDelta);

        currentTickLower = newLower;
        currentTickUpper = newUpper;
        currentLiquidity = newLiq;
        emit PositionRebalanced(oldLower, oldUpper, newLower, newUpper, newLiq);
    }

    // -----------------------------------------------------------------------
    // Settlement helpers — interpret BalanceDelta and move tokens accordingly.
    // -----------------------------------------------------------------------

    /// @dev Settle a delta where each side may be positive (hook is owed → take) or
    ///      negative (hook owes → settle).
    function _settleDelta(BalanceDelta delta) internal {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 > 0) poolManager.take(_poolKey.currency0, address(this), uint128(a0));
        else if (a0 < 0) _poolKey.currency0.settle(poolManager, address(this), uint128(-a0), false);
        if (a1 > 0) poolManager.take(_poolKey.currency1, address(this), uint128(a1));
        else if (a1 < 0) _poolKey.currency1.settle(poolManager, address(this), uint128(-a1), false);
    }

    /// @dev Like `_settleDelta` but expects positive (or zero) sides only — used after burn /
    ///      poke where credits are owed to the hook. A negative side here would indicate a
    ///      sign-convention bug.
    function _takeDelta(BalanceDelta delta) internal {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 > 0) poolManager.take(_poolKey.currency0, address(this), uint128(a0));
        if (a1 > 0) poolManager.take(_poolKey.currency1, address(this), uint128(a1));
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function poolId() external view returns (PoolId) {
        return _poolId;
    }
}
