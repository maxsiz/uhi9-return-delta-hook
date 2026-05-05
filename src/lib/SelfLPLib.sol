// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title SelfLPLib
/// @notice Stateless helpers shared by the SelfLP* hook variants.
/// @dev Encapsulates three pure / view primitives:
///   1. computeRange       — snap a half-width range around a tick onto the pool's tickSpacing.
///   2. previewFeesETH     — estimate accrued fees in ETH terms from view-side state only,
///                            without poking the position (no state mutation, no unlock).
///   3. computeReinvestSwap — decide how to rebalance the hook's idle balances toward a 50/50
///                            ratio at the new range before re-minting.
library SelfLPLib {
    using StateLibrary for IPoolManager;

    /// @notice Snap a half-width range around `currentTick` to the pool's tickSpacing.
    /// @dev Centers the range on the spacing-aligned tick at or below currentTick. The snapped
    ///      bounds are guaranteed to be valid initialized-tick candidates (multiples of spacing).
    function computeRange(int24 currentTick, int24 halfWidthTicks, int24 tickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        // Floor division: for negative numbers, integer division truncates toward zero, but we need floor.
        int24 compressed = currentTick / tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) compressed--;
        // Center = spacing-aligned tick at or below currentTick.
        int24 center = compressed * tickSpacing;

        // Round half-width down to nearest spacing multiple; enforce minimum = tickSpacing (avoid 0 range).
        int24 halfSnapped = (halfWidthTicks / tickSpacing) * tickSpacing;
        if (halfSnapped < tickSpacing) halfSnapped = tickSpacing;

        // Symmetric range around center: [center - halfSnapped, center + halfSnapped].
        tickLower = center - halfSnapped;
        tickUpper = center + halfSnapped;
    }

    /// @notice Bundle of position-coordinate fields for `previewFeesETH`. Bundling these into a
    ///         memory struct keeps the function's argument count low and avoids
    ///         "stack too deep" on solc 0.8.26 without `via_ir`.
    struct PreviewParams {
        IPoolManager manager;
        PoolId poolId;
        address owner;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
        bool ethIsCurrency0;
        uint160 sqrtPriceX96;
    }

    /// @notice View-side estimate of accrued fees on a position, denominated in ETH.
    /// @dev Demonstrates the StateLibrary path: we read feeGrowthInside (live) and the
    ///      position's last cached growth, multiply by liquidity, and convert the non-ETH side
    ///      to ETH via current sqrtPriceX96. No SSTORE, no unlock — appropriate for the
    ///      threshold gate in afterSwap so the no-op path stays cheap.
    function previewFeesETH(PreviewParams memory p) internal view returns (uint256 ethValue) {
        (uint256 fees0, uint256 fees1) = _accruedFees(p);
        if (fees0 == 0 && fees1 == 0) return 0;

        if (p.ethIsCurrency0) {
            // currency1 → ETH via price: amount1 * sqrtPrice^2 / Q192.
            // Split into two mulDivs to avoid overflow: (fees1 * Q96 / sqrtPrice) * Q96 / sqrtPrice.
            uint256 step = FullMath.mulDiv(fees1, FixedPoint96.Q96, p.sqrtPriceX96);
            ethValue = fees0 + FullMath.mulDiv(step, FixedPoint96.Q96, p.sqrtPriceX96);
        } else {
            // currency0 → ETH via price: amount0 * sqrtPrice^2 / Q192.
            // Split into two mulDivs: (fees0 * sqrtPrice / Q96) * sqrtPrice / Q96.
            uint256 step = FullMath.mulDiv(fees0, p.sqrtPriceX96, FixedPoint96.Q96);
            ethValue = fees1 + FullMath.mulDiv(step, p.sqrtPriceX96, FixedPoint96.Q96);
        }
    }

    function _accruedFees(PreviewParams memory p) private view returns (uint256 fees0, uint256 fees1) {
        bytes32 positionKey = keccak256(abi.encodePacked(p.owner, p.tickLower, p.tickUpper, p.salt));
        (uint128 liquidity, uint256 fgi0Last, uint256 fgi1Last) = p.manager.getPositionInfo(p.poolId, positionKey);
        if (liquidity == 0) return (0, 0);

        (uint256 fgi0Now, uint256 fgi1Now) = p.manager.getFeeGrowthInside(p.poolId, p.tickLower, p.tickUpper);
        unchecked {
            // Fee = (feeGrowthInside_now - feeGrowthInside_last) * liquidity / Q128.
            // Subtraction wraps on overflow per V4 invariants; same convention as Position.update.
            fees0 = FullMath.mulDiv(fgi0Now - fgi0Last, liquidity, FixedPoint128.Q128);
            fees1 = FullMath.mulDiv(fgi1Now - fgi1Last, liquidity, FixedPoint128.Q128);
        }
    }

    /// @notice Compute a one-shot rebalance swap so the hook's idle balances better match the
    ///         token ratio implied by the new range at the current price.
    /// @dev Heuristic: size the swap to convert the surplus side into the deficient side at
    ///      current price using `getAmountsForLiquidity` of the max-fit liquidity as the target.
    ///      The post-swap amounts will be slightly off because the swap itself shifts the price,
    ///      but a single-iteration pass is enough for the workshop demo and avoids fixed-point
    ///      iteration. Returns `(false, 0)` if no swap is needed.
    function computeReinvestSwap(
        uint160 sqrtPriceX96,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 balance0,
        uint256 balance1
    ) internal pure returns (bool zeroForOne, uint256 amountIn) {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(newTickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(newTickUpper);

        // Inverse liquidity formula: L = min(balance0 * sqrt(price) / (sqrt(B) - sqrt(price)), ...).
        uint128 maxLiq = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, balance0, balance1);
        if (maxLiq == 0) return (false, 0);

        // Forward liquidity formula: amounts = (L * (sqrt(B) - sqrt(price)) / (sqrt(B) - sqrt(A)), ...).
        (uint256 target0, uint256 target1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, maxLiq);

        // Identify which side has surplus and swap half of it (heuristic: avoids overshoot and iteration).
        if (balance0 > target0 && target1 > balance1) {
            // Surplus in 0, deficit in 1 → sell 0 for 1.
            return (true, (balance0 - target0) / 2);
        }
        if (balance1 > target1 && target0 > balance0) {
            // Surplus in 1, deficit in 0 → sell 1 for 0.
            return (false, (balance1 - target1) / 2);
        }
        return (false, 0);
    }
}
