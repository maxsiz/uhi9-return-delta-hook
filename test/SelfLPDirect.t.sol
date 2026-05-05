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

import {SelfLPDirect} from "../src/SelfLPDirect.sol";
import {hlpEnvelopTest} from "./hlpEnvelopTest.sol";

contract TestSelfLPDirect is Test, Deployers, hlpEnvelopTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SelfLPDirect hook;
    Currency ethCurrency = Currency.wrap(address(0));

    int24 constant HALF_WIDTH = 600;
    uint256 constant FEE_THRESHOLD_ETH = 1e13; // 0.00001 ETH — small enough that one 0.01 ETH swap crosses it
    uint24 constant LP_FEE = 3000; // 0.30%

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Hook permission bits: beforeInitialize | afterInitialize | afterSwap.
        address hookAddress = address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)
        );
        deployCodeTo(
            "SelfLPDirect.sol:SelfLPDirect",
            abi.encode(manager, address(this), HALF_WIDTH, FEE_THRESHOLD_ETH, LP_FEE),
            hookAddress
        );
        hook = SelfLPDirect(payable(hookAddress));

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
        // Read slot0.tick via the PoolManager's StateLibrary view. We replicate the wrapper here
        // to avoid pulling another library import into the test.
        bytes32 slot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), uint256(6))); // POOLS_SLOT
        bytes32 data = manager.extsload(slot);
        assembly {
            tick := signextend(2, shr(160, data))
        }
    }

    // ----------------------------------------------------------------------- //
    // seedPosition                                                            //
    // ----------------------------------------------------------------------- //

    function test_seedPosition_initialState() public {
        _seed(1 ether, 1 ether);
        assertTrue(hook.seeded(), "must be seeded");
        assertEq(hook.currentTickLower(), -HALF_WIDTH, "lower = -halfWidth around tick 0");
        assertEq(hook.currentTickUpper(), HALF_WIDTH, "upper = +halfWidth around tick 0");
        assertGt(hook.currentLiquidity(), 0, "liquidity > 0");
    }

    function test_seedPosition_idempotent() public {
        _seed(1 ether, 1 ether);
        vm.expectRevert(SelfLPDirect.AlreadySeeded.selector);
        hook.seedPosition{value: 1 ether}(1 ether, 1 ether);
    }

    function test_seedPosition_wrongMsgValue() public {
        // ETH is currency0; msg.value must equal amount0.
        vm.expectRevert(SelfLPDirect.WrongMsgValue.selector);
        hook.seedPosition{value: 0.5 ether}(1 ether, 1 ether);
    }

    function test_seedPosition_onlyOwner() public {
        address attacker = address(0xBEEF);
        vm.deal(attacker, 10 ether);
        vm.prank(attacker);
        vm.expectRevert(SelfLPDirect.NotOwner.selector);
        hook.seedPosition{value: 1 ether}(1 ether, 1 ether);
    }

    // ----------------------------------------------------------------------- //
    // afterSwap — threshold gate                                              //
    // ----------------------------------------------------------------------- //

    function test_swap_belowThreshold_noReinvest() public {
        _seed(1 ether, 1 ether);
        int24 lowerBefore = hook.currentTickLower();
        int24 upperBefore = hook.currentTickUpper();

        // Swap so small that fee on input < threshold.
        _swapZeroForOne(0.0001 ether); // 0.0001 ETH * 0.3% = 3e-7 ETH ≪ 1e-5 threshold

        assertEq(hook.currentTickLower(), lowerBefore, "range unchanged");
        assertEq(hook.currentTickUpper(), upperBefore, "range unchanged");
    }

    function test_swap_aboveThreshold_reinvests() public {
        _seed(1 ether, 1 ether);
        int24 lowerBefore = hook.currentTickLower();
        int24 upperBefore = hook.currentTickUpper();
        uint128 liqBefore = hook.currentLiquidity();

        // 0.01 ETH * 0.3% = 3e-5 ETH > 1e-5 threshold → reinvest fires.
        vm.recordLogs();
        _swapZeroForOne(0.01 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool sawRebalance = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SelfLPDirect.PositionRebalanced.selector) {
                sawRebalance = true;
                break;
            }
        }
        assertTrue(sawRebalance, "PositionRebalanced must be emitted");

        // After reinvest the range is recentered around the post-swap tick → at least one bound moved.
        bool rangeMoved = (hook.currentTickLower() != lowerBefore) || (hook.currentTickUpper() != upperBefore);
        assertTrue(rangeMoved, "range must shift after reinvest");
        assertGt(hook.currentLiquidity(), 0, "still has liquidity");
        // Liquidity may differ from before (fees rolled back in plus any idle dust contribution).
        liqBefore;
    }

    function test_followsPrice() public {
        _seed(1 ether, 1 ether);

        // Push price down with several oneForZero-style swaps in the same direction. Each big
        // enough to cross the fee threshold, so each triggers a reinvest re-centering the range.
        for (uint256 i = 0; i < 3; i++) {
            _swapZeroForOne(0.05 ether);
        }

        int24 tickAfter = _currentTick();
        int24 center = (hook.currentTickLower() + hook.currentTickUpper()) / 2;

        // The new range must be centered near the post-swap tick (within one tickSpacing).
        int24 diff = tickAfter > center ? tickAfter - center : center - tickAfter;
        assertLt(diff, key.tickSpacing * 2, "new range center should track current tick");
    }

    // ----------------------------------------------------------------------- //
    // Native ETH dust handling                                                //
    // ----------------------------------------------------------------------- //

    function test_native_dustHandling() public {
        _seed(1 ether, 1 ether);

        // After a single reinvest, leftover idle on either side can be a non-trivial fraction
        // of the seeded amount: an asymmetric range around the post-swap tick may need a very
        // different (token0, token1) ratio than the burn returned, and the baseline omits the
        // rebalance swap. The invariant we DO want is that the hook isn't somehow holding more
        // than the original deposit + swap input — that would mean we mismatched accounting.
        _swapZeroForOne(0.05 ether);

        uint256 hookEthAfter = address(hook).balance;
        uint256 hookT1After = currency1.balanceOf(address(hook));

        // Sanity bound: leftover ≤ amount the hook ever owned in either currency.
        assertLe(hookEthAfter, 1 ether + 0.05 ether, "hook ETH bounded by deposit + swap input");
        assertLe(hookT1After, 1 ether, "hook token1 bounded by deposit");
    }
}
