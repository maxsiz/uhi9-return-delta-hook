// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {SelfLPLib} from "./lib/SelfLPLib.sol";

/// @title SelfLPBeforeInternalize — auto-compounding self-LP hook with beforeSwapReturnDelta internalization.
/// @notice Extends SelfLPDirect with idle inventory internalization: the hook's accumulated idle
///         tokens (from reinvest residuals) partially fill swaps at the current price before
///         routing the remainder to the AMM. This gives better execution to swappers while
///         putting hook capital to work.
///
/// @dev This demonstrates the **beforeSwapReturnDelta** hook pattern:
///        • On every swap, check if the hook has idle inventory of the output currency.
///        • Use `SwapMath.computeSwapStep` to compute how much can be internalized at the
///          current price (bounded by idle balance and swap amount).
///        • Settle tokens directly: hook pays output, receives input.
///        • Return `BeforeSwapDelta` with correct signs so PoolManager reduces the AMM-routed
///          portion by the hook-filled amount.
///        • `_afterSwap` stays identical to baseline (threshold gate + reinvest).
contract SelfLPBeforeInternalize is BaseHook, IUnlockCallback {
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

    /// @notice Emitted when idle inventory is internalized into a swap.
    /// @param inputCurrency Currency the hook received (what user was paying).
    /// @param outputCurrency Currency the hook provided (what user was receiving).
    /// @param inputAmount Amount of input currency the hook took.
    /// @param outputAmount Amount of output currency the hook provided.
    event SwapInternalized(Currency indexed inputCurrency, Currency indexed outputCurrency, uint256 inputAmount, uint256 outputAmount);

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
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
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
    // Before-swap: idle inventory internalization
    // -----------------------------------------------------------------------

    function _beforeSwap(
        address, /*sender*/
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // No-op until position is seeded.
        if (!seeded) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // Determine output currency (what hook would provide from idle inventory).
        bool outputIsCurrency1 = params.zeroForOne;
        Currency outputCurrency = outputIsCurrency1 ? key.currency1 : key.currency0;
        Currency inputCurrency = outputIsCurrency1 ? key.currency0 : key.currency1;

        // Check idle inventory of the output currency.
        uint256 idleOutput = outputCurrency.balanceOfSelf();
        if (idleOutput == 0) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // Compute how much of the swap we can fill at current price using idle inventory.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_poolId);
        uint128 poolLiquidity = poolManager.getLiquidity(_poolId);

        (, uint256 amountIn, uint256 amountOut,) = SwapMath.computeSwapStep(
            sqrtPriceX96,
            params.sqrtPriceLimitX96,
            poolLiquidity,
            int256(idleOutput),  // positive = exactOut: hook provides this much output
            0                    // no fee on internalized portion
        );

        // Cap the internalized amount by the actual swap size.
        if (params.amountSpecified < 0) {
            // exactIn: cap amountIn to |amountSpecified|.
            uint256 swapInput = uint256(-params.amountSpecified);
            if (amountIn > swapInput) {
                amountOut = (amountOut * swapInput) / amountIn;
                amountIn = swapInput;
            }
        } else {
            // exactOut: cap amountOut to amountSpecified.
            uint256 swapOutput = uint256(params.amountSpecified);
            if (amountOut > swapOutput) {
                amountIn = (amountIn * swapOutput) / amountOut;
                amountOut = swapOutput;
            }
        }

        if (amountOut == 0) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // Settle tokens: hook provides output, receives input.
        outputCurrency.settle(poolManager, address(this), amountOut, false);
        poolManager.take(inputCurrency, address(this), amountIn);

        // Build BeforeSwapDelta with correct signs.
        // Convention: positive = hook took (is owed), negative = hook gave (owes).
        // exactIn:  specified = input,  unspecified = output  → (+amountIn, -amountOut)
        // exactOut: specified = output, unspecified = input   → (-amountOut, +amountIn)
        BeforeSwapDelta delta = params.amountSpecified < 0
            ? toBeforeSwapDelta(int128(uint128(amountIn)), -int128(uint128(amountOut)))
            : toBeforeSwapDelta(-int128(uint128(amountOut)), int128(uint128(amountIn)));

        emit SwapInternalized(inputCurrency, outputCurrency, amountIn, amountOut);

        return (this.beforeSwap.selector, delta, 0);
    }

    // -----------------------------------------------------------------------
    // After-swap: threshold gate + reinvest (identical to SelfLPDirect)
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
    ///      (Identical logic to SelfLPDirect — see comments there.)
    function _reinvest(PoolKey calldata key, uint160 sqrtPriceX96) internal {
        int24 oldLower = currentTickLower;
        int24 oldUpper = currentTickUpper;
        uint128 oldLiq = currentLiquidity;

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

        (, int24 tickAfter,,) = poolManager.getSlot0(_poolId);
        (int24 newLower, int24 newUpper) =
            SelfLPLib.computeRange(tickAfter, halfWidthTicks, key.tickSpacing);

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
            _takeDelta(burnDelta);
            currentLiquidity = 0;
            return;
        }

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

        _settleDelta(burnDelta + mintDelta);

        currentTickLower = newLower;
        currentTickUpper = newUpper;
        currentLiquidity = newLiq;
        emit PositionRebalanced(oldLower, oldUpper, newLower, newUpper, newLiq);
    }

    // -----------------------------------------------------------------------
    // Settlement helpers — interpret BalanceDelta and move tokens accordingly.
    // -----------------------------------------------------------------------

    function _settleDelta(BalanceDelta delta) internal {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 > 0) poolManager.take(_poolKey.currency0, address(this), uint128(a0));
        else if (a0 < 0) _poolKey.currency0.settle(poolManager, address(this), uint128(-a0), false);
        if (a1 > 0) poolManager.take(_poolKey.currency1, address(this), uint128(a1));
        else if (a1 < 0) _poolKey.currency1.settle(poolManager, address(this), uint128(-a1), false);
    }

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
