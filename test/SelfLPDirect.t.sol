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

import {SelfLPDirect} from "../src/SelfLPDirect.sol";
import {hlpEnvelopTest} from "./hlpEnvelopTest.sol";

contract TestSelfLPDirect is Test, Deployers, hlpEnvelopTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SelfLPDirect hook;
    Currency ethCurrency = Currency.wrap(address(0));

    int24 constant HALF_WIDTH = 600;
    uint256 constant FEE_THRESHOLD_ETH = 1e13; // 0.00001 ETH — small enough that one 0.01 ETH swap crosses it
    uint24 constant LP_FEE = 3000; // 0.30%

    function _logHookState(string memory title) internal view {
        (uint160 sqrtPrice, int24 tickCurrent,,) = manager.getSlot0(key.toId());
        console2.log("");
        console2.log(string.concat("=== ", title, " ==="));
        console2.log(string.concat("hook:ETH:     ", _formatEther(address(hook).balance), " ether"));
        console2.log(string.concat("hook:Token1:  ", vm.toString(currency1.balanceOf(address(hook)))));
        console2.log(string.concat("PM:ETH:     ", _formatEther(address(manager).balance), " ether"));
        console2.log(string.concat(
            "PM:Token1:  ", 
            vm.toString(currency1.balanceOf(address(manager))),", ",
            _formatEther(currency1.balanceOf(address(manager))), "eth"
        ));

        int24 center = (hook.currentTickLower() + hook.currentTickUpper()) / 2;
        console2.log(string.concat("Tick center: ", _formatTick(center), " (current ", _formatTick(tickCurrent), ")"));
        console2.log(string.concat("Range:      [", _formatTick(hook.currentTickLower()), ", ", _formatTick(hook.currentTickUpper()), "]"));
        console2.log(string.concat("Liq:         ", vm.toString(uint256(hook.currentLiquidity()))));
        console2.log(string.concat("sqrtP:       ", vm.toString(uint256(sqrtPrice))));
    }

    function _formatTick(int24 tick) internal pure returns (string memory) {
        if (tick < 0) {
            return string.concat("-", vm.toString(uint256(int256(-tick))));
        }
        return vm.toString(uint256(int256(tick)));
    }

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

        /*
        Пример — ETH по 2000 USDC (pool: ETH = currency0, USDC = currency1, price = 2000):                                                                                                                                                                                      
        import {TickMath} from "v4-core/libraries/TickMath.sol";
        */
        /*
        Расчёт для курса 1:2000                                                                                                                                                                     
                                                                                                                                                                                                      
        tick = ln(2000) / ln(1.0001)                                                                                                                                                                
           = 7.6009025 / 0.0000999950                                                                                                                                                             
           ≈ 76012.04                                                                                                                                                                             
                                                                                                                                                                                                      
        Реальный тик для price = 2000 равен ~76012, а не 75060 (как в текущем тесте).                                                                                                               
                                                                                                                                                                                                      
          Проверка: что даёт текущий tick = 75060?                                                                                                                                                    
                                                                                                                                                                                                      
          price = 1.0001^75060 = e^(75060 × 0.0000999950) = e^7.5056 ≈ 1817.74                                                                                                                        
                                                                                                                                                                                                      
          Поэтому твой тест и показывает PM:Token1: 1818.2408eth — пул считает по реальному курсу 1818, а не 2000.                                                                                    
                                                                                                                                                                                                      
          ---                                                                                                                                                                                         
          Снаппинг к tickSpacing = 60                                                                                                                                                                 
                                                                                                                                                                                                      
          Тик должен быть кратен 60:                                                                                                                                                                  
                                                                                                                                                                                                      
          76012 / 60 = 1266.87                                                                                                                                                                        
          → варианты:                                                                                                                                                                                 
             1266 × 60 = 75960 → price = e^(75960×0.00009999) = e^7.5946 ≈ 1995.26                                                                                                                    
             1267 × 60 = 76020 → price ≈ 2001.59  ← ближе к 2000      

        Ответ: tick = 76020 даёт price ≈ 2001.6, отклонение 0.08%.              
        */
          // price = amount1/amount0 = 2000                                                                                                                                                                                                                                       
        int24 tick = 76020;                                                                                                                                                                                                                                                     
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);           
        
        // Initialize the pool. ETH = currency0 (Deployers sorts so address(0) < ERC20).
        (key,) = initPool(ethCurrency, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, sqrtPrice);
        // Price: 1 = 1 
        //(key,) = initPool(ethCurrency, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        // Test contract needs ETH to seed and to swap.
        vm.deal(address(this), 100 ether);
        // Approve currency1 to the hook so seedPosition's transferFrom works.
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        console2.log("Pool tickSpacing: %s", key.tickSpacing);
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
        console2.log("");
        console2.log("=== test_seedPosition_initialState ===");
        // console2.log("BEFORE seedPosition:");
        // console2.log(string.concat("  Hook ETH:    ", _formatEther(address(hook).balance), " ether"));
        // console2.log(string.concat("  Hook Token1: ", vm.toString(currency1.balanceOf(address(hook))), " * 1e18"));
        _logHookState("BEFORE seedPosition");
        _seed(1 ether, 2000e18);

        _logHookState("AFTER seedPosition");
        (uint160 sqrtPrice, int24 tickCurrent,,) = manager.getSlot0(key.toId());
        assertTrue(hook.seeded(), "must be seeded");
        assertLe(tickCurrent - hook.currentTickLower(), HALF_WIDTH, "|lower - current| > halfWidth");
        assertEq(hook.currentTickUpper(), tickCurrent+HALF_WIDTH, "upper = +halfWidth around tick 0");
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

    // function test_swap_belowThreshold_noReinvest() public {
    //     console2.log("");
    //     console2.log("=== test_swap_belowThreshold_noReinvest ===");
    //     _seed(1 ether, 2000 ether);
    //     _logHookState("AFTER seedPosition");

    //     int24 lowerBefore = hook.currentTickLower();
    //     int24 upperBefore = hook.currentTickUpper();

    //     console2.log("");
    //     console2.log("BEFORE swap (0.0001 ETH):");
    //     console2.log(string.concat("  Fee generated: ~", _formatEther(0.0001 ether * 3000 / 1000000), " ETH (below ", _formatEther(FEE_THRESHOLD_ETH), " threshold)"));

    //     _swapZeroForOne(0.0001 ether); // 0.0001 ETH * 0.3% = 3e-7 ETH ≪ 1e-5 threshold

    //     _logHookState("AFTER swap (no reinvest expected)");

    //     assertEq(hook.currentTickLower(), lowerBefore, "range unchanged");
    //     assertEq(hook.currentTickUpper(), upperBefore, "range unchanged");
    // }

    function test_swap_aboveThreshold_reinvests() public {
        console2.log("");
        console2.log("=== test_swap_aboveThreshold_reinvests ===");
        _seed(1 ether, 2000 ether);
        _logHookState("AFTER seedPosition");

        int24 lowerBefore = hook.currentTickLower();
        int24 upperBefore = hook.currentTickUpper();
        uint128 liqBefore = hook.currentLiquidity();

        console2.log("");
        console2.log("BEFORE swap (0.01 ETH):");
        console2.log(string.concat(
            "  Fee generated: ~", _formatEther(0.01 ether * 3000 / 1000000), 
            " ETH (above ", _formatEther(FEE_THRESHOLD_ETH), " threshold)"
        ));
        console2.log("  Expected: reinvest will trigger");

        // 0.01 ETH * 0.3% = 3e-5 ETH > 1e-5 threshold → reinvest fires.
        vm.recordLogs();
        _swapZeroForOne(0.01 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool sawRebalance = false;
        for (uint256 i = 0; i < logs.length; i++) {
             console2.log(vm.toString(logs[i].topics[0]));
            if (logs[i].topics[0] == SelfLPDirect.PositionRebalanced.selector) {
                sawRebalance = true;
                break;
            }
        }
        assertTrue(sawRebalance, "PositionRebalanced must be emitted");

        _logHookState("AFTER swap with reinvest");

        console2.log("");
        console2.log("Reinvest analysis:");
        console2.log(string.concat("  Old range: [", _formatTick(lowerBefore), ", ", _formatTick(upperBefore), "]"));
        console2.log(string.concat("  New range: [", _formatTick(hook.currentTickLower()), ", ", _formatTick(hook.currentTickUpper()), "]"));
        console2.log(string.concat("  Liquidity before: ", vm.toString(uint256(liqBefore))));
        console2.log(string.concat("  Liquidity after:  ", vm.toString(uint256(hook.currentLiquidity())), " (includes accrued fees)"));

        // After reinvest the range is recentered around the post-swap tick → at least one bound moved.
        bool rangeMoved = (hook.currentTickLower() != lowerBefore) || (hook.currentTickUpper() != upperBefore);
        assertTrue(rangeMoved, "range must shift after reinvest");
        assertGt(hook.currentLiquidity(), 0, "still has liquidity");
        // Liquidity may differ from before (fees rolled back in plus any idle dust contribution).
        liqBefore;
    }

    // function test_followsPrice() public {
    //     console2.log("");
    //     console2.log("=== test_followsPrice ===");
    //     _seed(1 ether, 1 ether);
    //     _logHookState("AFTER seedPosition");

    //     // Push price down with several oneForZero-style swaps in the same direction. Each big
    //     // enough to cross the fee threshold, so each triggers a reinvest re-centering the range.
    //     for (uint256 i = 0; i < 3; i++) {
    //         console2.log("");
    //         console2.log(string.concat("--- Swap ", vm.toString(i + 1), ": 0.05 ETH ---"));
    //         console2.log("BEFORE:");
    //         console2.log(string.concat("  Range center: ", _formatTick((hook.currentTickLower() + hook.currentTickUpper()) / 2)));

    //         _swapZeroForOne(0.05 ether);

    //         _logHookState(string.concat("AFTER swap ", vm.toString(i + 1)));
    //     }

    //     int24 tickAfter = _currentTick();
    //     int24 center = (hook.currentTickLower() + hook.currentTickUpper()) / 2;
    //     int24 diff = tickAfter > center ? tickAfter - center : center - tickAfter;

    //     console2.log("");
    //     console2.log("Final analysis:");
    //     console2.log(string.concat("  Pool tick:       ", _formatTick(tickAfter)));
    //     console2.log(string.concat("  Range center:    ", _formatTick(center)));
    //     console2.log(string.concat("  Difference:      ", vm.toString(uint256(int256(diff)))));
    //     console2.log(string.concat("  Tick spacing:    ", vm.toString(uint256(int256(key.tickSpacing)))));

    //     // The new range must be centered near the post-swap tick (within one tickSpacing).
    //     assertLt(diff, key.tickSpacing * 2, "new range center should track current tick");
    // }

    // // ----------------------------------------------------------------------- //
    // // Native ETH dust handling                                                //
    // // ----------------------------------------------------------------------- //

    // function test_native_dustHandling() public {
    //     console2.log("");
    //     console2.log("=== test_native_dustHandling ===");
    //     console2.log("Testing accounting correctness: hook should not hold more than seeded + swapped");

    //     console2.log("");
    //     console2.log("Deposit: 1.0000 ETH + 1.0000e18 token1");
    //     _seed(1 ether, 1 ether);
    //     _logHookState("AFTER seedPosition");

    //     console2.log("");
    //     console2.log("Performing swap: 0.05 ETH");
    //     _swapZeroForOne(0.05 ether);

    //     _logHookState("AFTER swap (reinvest triggered)");

    //     uint256 hookEthAfter = address(hook).balance;
    //     uint256 hookT1After = currency1.balanceOf(address(hook));

    //     console2.log("");
    //     console2.log("Accounting check:");
    //     console2.log(string.concat("  Max ETH allowed:    ", _formatEther(1 ether + 0.05 ether), " (deposit 1.0 + swap 0.05)"));
    //     console2.log(string.concat("  Actual ETH:         ", _formatEther(hookEthAfter)));
    //     console2.log("  Max token1 allowed: 1.0000e18");
    //     console2.log(string.concat("  Actual token1:      ", vm.toString(hookT1After), "e18"));

    //     // Sanity bound: leftover ≤ amount the hook ever owned in either currency.
    //     assertLe(hookEthAfter, 1 ether + 0.05 ether, "hook ETH bounded by deposit + swap input");
    //     assertLe(hookT1After, 1 ether, "hook token1 bounded by deposit");

    //     console2.log("");
    //     console2.log("[OK] Accounting is correct - no excess holdings");
    // }
}
