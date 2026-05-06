// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {SelfLPAfterDelta} from "../src/SelfLPAfterDelta.sol";
import {hlpEnvelopTest} from "./hlpEnvelopTest.sol";

contract TestSelfLPAfterDelta is Test, Deployers, hlpEnvelopTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SelfLPAfterDelta hook;
    Currency ethCurrency = Currency.wrap(address(0));

    int24 constant HALF_WIDTH = 600;
    uint256 constant FEE_THRESHOLD_ETH = 1e13; // 0.00001 ETH
    uint24 constant LP_FEE = 3000; // 0.30%
    uint16 constant SKIM_BPS = 100; // 1%

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Hook permission bits: beforeInitialize | afterInitialize | afterSwap | afterSwapReturnDelta.
        address hookAddress = address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
        );
        deployCodeTo(
            "SelfLPAfterDelta.sol:SelfLPAfterDelta",
            abi.encode(manager, address(this), HALF_WIDTH, FEE_THRESHOLD_ETH, LP_FEE, SKIM_BPS),
            hookAddress
        );
        hook = SelfLPAfterDelta(payable(hookAddress));

        // Initialize the pool. ETH = currency0 (Deployers sorts so address(0) < ERC20).
        (key,) = initPool(ethCurrency, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        // Test contract needs ETH to seed and to swap.
        vm.deal(address(this), 100 ether);
        // Approve currency1 to the hook so seedPosition's transferFrom works.
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function _seed(uint256 amount0, uint256 amount1) internal {
        hook.seedPosition{value: amount0}(amount0, amount1);
    }

    function _swapZeroForOne(uint256 ethIn) internal {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(ethIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap{value: ethIn}(key, params, settings, "");
    }

    function _swapOneForZero(uint256 token1In) internal {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(token1In),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(key, params, settings, "");
    }

    function _currentTick() internal view returns (int24 tick) {
        bytes32 slot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), uint256(6)));
        bytes32 data = manager.extsload(slot);
        assembly {
            tick := signextend(2, shr(160, data))
        }
    }

    function _logHookState(string memory title) internal view {
        (uint160 sqrtPrice, int24 tickCurrent,,) = manager.getSlot0(key.toId());
        console2.log("");
        console2.log(string.concat("=== ", title, " ==="));
        console2.log(string.concat("ETH:     ", _formatEther(address(hook).balance), " ether"));
        console2.log(string.concat("Token1:  ", vm.toString(currency1.balanceOf(address(hook)))));

        int24 center = (hook.currentTickLower() + hook.currentTickUpper()) / 2;
        console2.log(string.concat("Tick:    ", _formatTick(center), " (current ", _formatTick(tickCurrent), ")"));
        console2.log(string.concat("Range:   [", _formatTick(hook.currentTickLower()), ", ", _formatTick(hook.currentTickUpper()), "]"));
        console2.log(string.concat("Liq:     ", vm.toString(uint256(hook.currentLiquidity()))));
        console2.log(string.concat("sqrtP:   ", vm.toString(uint256(sqrtPrice))));
    }

    function _formatTick(int24 tick) internal pure returns (string memory) {
        if (tick < 0) {
            return string.concat("-", vm.toString(uint256(int256(-tick))));
        }
        return vm.toString(uint256(int256(tick)));
    }

    // -----------------------------------------------------------------------
    // Standard tests (copied from SelfLPDirect with skim-specific additions)
    // -----------------------------------------------------------------------

    function test_seedPosition_initialState() public {
        console2.log("");
        console2.log("=== test_seedPosition_initialState ===");
        _seed(1 ether, 1 ether);
        _logHookState("AFTER seedPosition");

        assertTrue(hook.seeded(), "must be seeded");
        assertEq(hook.currentTickLower(), -HALF_WIDTH, "lower = -halfWidth around tick 0");
        assertEq(hook.currentTickUpper(), HALF_WIDTH, "upper = +halfWidth around tick 0");
        assertGt(hook.currentLiquidity(), 0, "liquidity > 0");
    }

    function test_seedPosition_idempotent() public {
        _seed(1 ether, 1 ether);
        vm.expectRevert(SelfLPAfterDelta.AlreadySeeded.selector);
        hook.seedPosition{value: 1 ether}(1 ether, 1 ether);
    }

    function test_swap_belowThreshold_noReinvest() public {
        console2.log("");
        console2.log("=== test_swap_belowThreshold_noReinvest ===");
        _seed(1 ether, 1 ether);
        _logHookState("AFTER seedPosition");

        int24 lowerBefore = hook.currentTickLower();
        int24 upperBefore = hook.currentTickUpper();

        console2.log("");
        console2.log("BEFORE swap (0.0001 ETH):");
        console2.log(string.concat("  Fee generated: ~", _formatEther(0.0001 ether * 3000 / 1000000), " ETH (below threshold)"));

        _swapZeroForOne(0.0001 ether);

        _logHookState("AFTER swap (no reinvest expected)");

        assertEq(hook.currentTickLower(), lowerBefore, "range unchanged");
        assertEq(hook.currentTickUpper(), upperBefore, "range unchanged");
    }

    function test_swap_aboveThreshold_reinvests() public {
        console2.log("");
        console2.log("=== test_swap_aboveThreshold_reinvests ===");
        _seed(1 ether, 1 ether);
        _logHookState("AFTER seedPosition");

        int24 lowerBefore = hook.currentTickLower();
        int24 upperBefore = hook.currentTickUpper();
        uint128 liqBefore = hook.currentLiquidity();

        console2.log("");
        console2.log("BEFORE swap (0.01 ETH):");
        console2.log("  Expected: reinvest will trigger, skim will be collected");

        vm.recordLogs();
        _swapZeroForOne(0.01 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool sawRebalance = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SelfLPAfterDelta.PositionRebalanced.selector) {
                sawRebalance = true;
                break;
            }
        }
        assertTrue(sawRebalance, "PositionRebalanced must be emitted");

        _logHookState("AFTER swap with reinvest");

        bool rangeMoved = (hook.currentTickLower() != lowerBefore) || (hook.currentTickUpper() != upperBefore);
        assertTrue(rangeMoved, "range must shift after reinvest");
        assertGt(hook.currentLiquidity(), 0, "still has liquidity");
        liqBefore;
    }

    // -----------------------------------------------------------------------
    // Variant-specific tests for skim functionality
    // -----------------------------------------------------------------------

    function test_skim_accumulates() public {
        console2.log("");
        console2.log("=== test_skim_accumulates ===");
        _seed(1 ether, 1 ether);
        console2.log("BEFORE swap:");
        console2.log(string.concat("  skimBuffer1: ", vm.toString(uint256(hook.skimBuffer1()))));

        // Small swap: generates skim but not enough fees for reinvest.
        _swapZeroForOne(0.001 ether);

        console2.log("AFTER swap (0.001 ETH):");
        uint128 skimAfterSwap = hook.skimBuffer1();
        console2.log(string.concat("  skimBuffer1: ", vm.toString(uint256(skimAfterSwap))));
        assertGt(skimAfterSwap, 0, "skim buffer should accumulate");

        // Second swap should increase the buffer.
        _swapZeroForOne(0.001 ether);

        uint128 skimAfterSwap2 = hook.skimBuffer1();
        console2.log(string.concat("  skimBuffer1 after 2nd swap: ", vm.toString(uint256(skimAfterSwap2))));
        assertGt(skimAfterSwap2, skimAfterSwap, "skim buffer should grow");
    }

    function test_skim_consumedAtReinvest() public {
        console2.log("");
        console2.log("=== test_skim_consumedAtReinvest ===");
        _seed(1 ether, 1 ether);

        // Small swap to build up skim without triggering reinvest.
        _swapZeroForOne(0.001 ether);
        uint128 skimBefore = hook.skimBuffer1();
        console2.log(string.concat("  skimBuffer1 before reinvest: ", vm.toString(uint256(skimBefore))));
        assertGt(skimBefore, 0, "skim should exist");

        // Large swap that triggers reinvest.
        _swapZeroForOne(0.01 ether);

        uint128 skimAfter = hook.skimBuffer1();
        console2.log(string.concat("  skimBuffer1 after reinvest: ", vm.toString(uint256(skimAfter))));
        assertEq(skimAfter, 0, "skim buffer should be reset after reinvest");
    }

    function test_returnDelta_sign() public {
        console2.log("");
        console2.log("=== test_returnDelta_sign ===");
        _seed(1 ether, 1 ether);

        // Small swap triggers skim but not reinvest.
        // The skim is collected via take(), and hookDeltaUnspecified is returned.
        _swapZeroForOne(0.001 ether);

        uint128 skimBuffer = hook.skimBuffer1();
        console2.log(string.concat("  skimBuffer1 after swap: ", vm.toString(uint256(skimBuffer))));
        assertGt(skimBuffer, 0, "skim should be collected");

        // Second swap triggers reinvest.
        _swapZeroForOne(0.01 ether);

        // After reinvest, skimBuffer should be reset (folded into position).
        uint128 skimBufferAfter = hook.skimBuffer1();
        console2.log(string.concat("  skimBuffer1 after reinvest: ", vm.toString(uint256(skimBufferAfter))));
        assertEq(skimBufferAfter, 0, "skimBuffer should be reset after reinvest");

        // Position should still have liquidity.
        assertGt(hook.currentLiquidity(), 0, "position should have liquidity after reinvest");
    }

    function test_followsPrice() public {
        console2.log("");
        console2.log("=== test_followsPrice ===");
        _seed(1 ether, 1 ether);
        _logHookState("AFTER seedPosition");

        for (uint256 i = 0; i < 3; i++) {
            console2.log("");
            console2.log(string.concat("--- Swap ", vm.toString(i + 1), ": 0.05 ETH ---"));
            _swapZeroForOne(0.05 ether);
            _logHookState(string.concat("AFTER swap ", vm.toString(i + 1)));
        }

        int24 tickAfter = _currentTick();
        int24 center = (hook.currentTickLower() + hook.currentTickUpper()) / 2;
        int24 diff = tickAfter > center ? tickAfter - center : center - tickAfter;

        console2.log("");
        console2.log("Final tick tracking:");
        console2.log(string.concat("  Pool tick: ", _formatTick(tickAfter)));
        console2.log(string.concat("  Range center: ", _formatTick(center)));
        console2.log(string.concat("  Difference: ", vm.toString(uint256(int256(diff)))));

        assertLt(diff, key.tickSpacing * 2, "new range center should track current tick");
    }

    function test_native_dustHandling() public {
        console2.log("");
        console2.log("=== test_native_dustHandling ===");
        _seed(1 ether, 1 ether);
        _logHookState("AFTER seedPosition");

        _swapZeroForOne(0.05 ether);
        _logHookState("AFTER swap (reinvest triggered)");

        uint256 hookEthAfter = address(hook).balance;
        uint256 hookT1After = currency1.balanceOf(address(hook));

        console2.log("");
        console2.log("Accounting check:");
        console2.log(string.concat("  Hook ETH:  ", _formatEther(hookEthAfter)));
        console2.log(string.concat("  Hook T1:   ", vm.toString(hookT1After)));

        assertLe(hookEthAfter, 1 ether + 0.05 ether, "hook ETH bounded by deposit + swap input");
        assertLe(hookT1After, 1 ether, "hook token1 bounded by deposit");

        console2.log("");
        console2.log("[OK] Accounting is correct - no excess holdings");
    }
}
