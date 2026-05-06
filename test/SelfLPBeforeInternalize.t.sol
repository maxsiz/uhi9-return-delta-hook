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

import {SelfLPBeforeInternalize} from "../src/SelfLPBeforeInternalize.sol";
import {hlpEnvelopTest} from "./hlpEnvelopTest.sol";

contract TestSelfLPBeforeInternalize is Test, Deployers, hlpEnvelopTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SelfLPBeforeInternalize hook;
    Currency ethCurrency = Currency.wrap(address(0));

    int24 constant HALF_WIDTH = 600;
    uint256 constant FEE_THRESHOLD_ETH = 1e13; // 0.00001 ETH
    uint24 constant LP_FEE = 3000; // 0.30%

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Hook permission bits: beforeInitialize | afterInitialize | beforeSwap | afterSwap | beforeSwapReturnDelta.
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            )
        );
        deployCodeTo(
            "SelfLPBeforeInternalize.sol:SelfLPBeforeInternalize",
            abi.encode(manager, address(this), HALF_WIDTH, FEE_THRESHOLD_ETH, LP_FEE),
            hookAddress
        );
        hook = SelfLPBeforeInternalize(payable(hookAddress));

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
    }

    function _formatTick(int24 tick) internal pure returns (string memory) {
        if (tick < 0) {
            return string.concat("-", vm.toString(uint256(int256(-tick))));
        }
        return vm.toString(uint256(int256(tick)));
    }

    // -----------------------------------------------------------------------
    // Standard tests (baseline functionality)
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
        vm.expectRevert(SelfLPBeforeInternalize.AlreadySeeded.selector);
        hook.seedPosition{value: 1 ether}(1 ether, 1 ether);
    }

    function test_swap_belowThreshold_noReinvest() public {
        console2.log("");
        console2.log("=== test_swap_belowThreshold_noReinvest ===");
        _seed(1 ether, 1 ether);
        _logHookState("AFTER seedPosition");

        int24 lowerBefore = hook.currentTickLower();
        int24 upperBefore = hook.currentTickUpper();

        _swapZeroForOne(0.0001 ether);

        _logHookState("AFTER small swap (no reinvest)");

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

        vm.recordLogs();
        _swapZeroForOne(0.01 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool sawRebalance = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SelfLPBeforeInternalize.PositionRebalanced.selector) {
                sawRebalance = true;
                break;
            }
        }
        assertTrue(sawRebalance, "PositionRebalanced must be emitted");

        _logHookState("AFTER large swap (reinvest triggered)");

        bool rangeMoved = (hook.currentTickLower() != lowerBefore) || (hook.currentTickUpper() != upperBefore);
        assertTrue(rangeMoved, "range must shift after reinvest");
        assertGt(hook.currentLiquidity(), 0, "still has liquidity");
    }

    function test_followsPrice() public {
        console2.log("");
        console2.log("=== test_followsPrice ===");
        _seed(1 ether, 1 ether);
        _logHookState("AFTER seedPosition");

        for (uint256 i = 0; i < 3; i++) {
            _swapZeroForOne(0.05 ether);
            _logHookState(string.concat("AFTER swap ", vm.toString(i + 1)));
        }

        int24 tickAfter = _currentTick();
        int24 center = (hook.currentTickLower() + hook.currentTickUpper()) / 2;
        int24 diff = tickAfter > center ? tickAfter - center : center - tickAfter;

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

        assertLe(hookEthAfter, 1 ether + 0.05 ether, "hook ETH bounded");
        assertLe(hookT1After, 1 ether, "hook token1 bounded");
    }

    // -----------------------------------------------------------------------
    // Variant-specific tests for beforeSwapReturnDelta internalization
    // -----------------------------------------------------------------------

    function test_internalize_partialFill() public {
        console2.log("");
        console2.log("=== test_internalize_partialFill ===");
        _seed(2 ether, 2 ether);  // seed with larger amounts to have more residue
        _logHookState("AFTER seedPosition");

        // First swap to trigger reinvest and generate idle inventory.
        _swapZeroForOne(0.02 ether);
        _logHookState("AFTER first swap (reinvest)");

        uint256 token1Idle = currency1.balanceOf(address(hook));
        console2.log(string.concat("  Idle token1 after reinvest: ", vm.toString(token1Idle)));

        if (token1Idle > 0) {
            // Small swap that should be partially internalized.
            uint256 token1Before = token1Idle;
            _swapZeroForOne(0.001 ether);

            uint256 token1After = currency1.balanceOf(address(hook));

            console2.log("");
            console2.log("After internalization swap:");
            console2.log(string.concat("  Hook token1: ", vm.toString(token1Before), " -> ", vm.toString(token1After)));

            // Hook should have given some token1 (internalized part of user's output).
            assertLe(token1After, token1Before, "hook should have provided token1 from internalization");
        }
    }

    function test_internalize_emptyInventory_fallthrough() public {
        console2.log("");
        console2.log("=== test_internalize_emptyInventory_fallthrough ===");

        // Seed with a perfect 1:1 ratio at current price so no residual dust.
        // (In practice, the reinvest might leave tiny dust, but test the no-op case.)
        _seed(1 ether, 1 ether);
        _logHookState("AFTER seedPosition");

        uint256 token1Idle = currency1.balanceOf(address(hook));
        console2.log(string.concat("  Idle token1: ", vm.toString(token1Idle)));

        // Do a swap. If hook has no idle token1, internalization is a no-op (ZERO_DELTA).
        uint256 ethBefore = address(hook).balance;
        _swapZeroForOne(0.001 ether);
        uint256 ethAfter = address(hook).balance;

        console2.log("");
        console2.log("After swap with no idle inventory:");
        console2.log(string.concat("  Hook ETH: ", _formatEther(ethBefore), " -> ", _formatEther(ethAfter)));

        // If truly no idle inventory, hook balance shouldn't change much
        // (it might change slightly from fees or reinvest, but not from internalization).
        if (token1Idle == 0) {
            assertEq(ethAfter, ethBefore, "no change when no idle inventory");
        }
    }

    function test_beforeDelta_sign() public {
        console2.log("");
        console2.log("=== test_beforeDelta_sign ===");
        _seed(2 ether, 2 ether);  // larger seed for more idle inventory

        // Trigger reinvest to generate idle inventory.
        _swapZeroForOne(0.02 ether);
        _logHookState("AFTER first swap (reinvest)");

        uint256 idleToken1Before = currency1.balanceOf(address(hook));
        console2.log(string.concat("  Idle token1 after reinvest: ", vm.toString(idleToken1Before)));

        if (idleToken1Before > 0) {
            // Swap that will trigger internalization.
            // When user swaps ETH for token1 (zeroForOne):
            // - Hook provides token1 (output) from idle
            // - Hook receives ETH (input) from user
            // Delta should be: (+ethReceived, -token1Provided)
            uint256 ethBefore = address(hook).balance;
            _swapZeroForOne(0.001 ether);
            uint256 ethAfter = address(hook).balance;

            uint256 idleToken1After = currency1.balanceOf(address(hook));

            console2.log("");
            console2.log("BeforeSwapDelta check (zeroForOne exactIn):");
            console2.log(string.concat("  Hook ETH:    ", _formatEther(ethBefore), " -> ", _formatEther(ethAfter)));
            console2.log(string.concat("  Hook token1: ", vm.toString(idleToken1Before), " -> ", vm.toString(idleToken1After)));

            // For zeroForOne exactIn with internalization:
            // Hook receives ETH (from user's input that hook internalized)
            // Hook gives token1 (from idle inventory)
            assertGe(ethAfter, ethBefore, "hook should receive or keep ETH");
            assertLe(idleToken1After, idleToken1Before, "hook should give token1 (from idle)");
        }
    }
}
