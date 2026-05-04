// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
 
import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {InternalSwapPool} from "../src/InternalSwapPool.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {console} from "forge-std/console.sol";
import {Script, console2} from "forge-std/Script.sol";
import {hlpEnvelopTest} from "./hlpEnvelopTest.sol";

contract TestInternalSwapPool is Test, Deployers, hlpEnvelopTest {
    InternalSwapPool hook;
    Currency ethCurrency = Currency.wrap(address(0));
    //
    // Global variables -  derived from Deployers
    // Currency internal currency0;
    // Currency internal currency1;
    // IPoolManager manager;
    // PoolModifyLiquidityTest modifyLiquidityRouter;
    // PoolModifyLiquidityTestNoChecks modifyLiquidityNoChecks;
    // SwapRouterNoChecks swapRouterNoChecks;
    // PoolSwapTest swapRouter;
    // PoolDonateTest donateRouter;
    // PoolTakeTest takeRouter;
    // ActionsRouter actionsRouter;

    // PoolClaimsTest claimsRouter;
    // PoolNestedActionsTest nestedActionRouter;
    // address feeController;

    // PoolKey key;
    // PoolKey nativeKey;
    // PoolKey uninitializedKey;
    // PoolKey uninitializedNativeKey;

	function setUp() public {
		// Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        // Deploy our hook with the proper flags
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG|
                    Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );

        // Set gas price = 10 gwei and deploy our hook
        //vm.txGasPrice(10 gwei);
        deployCodeTo(
            "InternalSwapPool.sol:InternalSwapPool",   // code
            abi.encode(manager, address(0)),           // constructor args
            hookAddress                                // address of deployed contract
        );
        hook = InternalSwapPool(payable(hookAddress));
          
        // Initialize a pool 
        (key, ) = initPool(
            ethCurrency,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
            SQRT_PRICE_1_1
        );
        
        vm.deal(address(this), 100 ether);
        vm.deal(hookAddress, 100 ether);  // !!!!
        console2.log(
            "Addres(this).ethBalance:%s, \n raw: %s ", 
            _formatEther(address(this).balance), address(this).balance
        );
        // Add some liquidity
        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 3e21, //~9 eth in pool
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        console2.log(
            "Addres(this).ethBalance:%s, \n raw: %s ", 
            _formatEther(address(this).balance), address(this).balance
        );
        console2.log(
            "Addres(this).currency1:%s, \n raw: %s ", 
            _formatEther(currency1.balanceOf(address(this))), currency1.balanceOf(address(this))
        );
        assertGt(address(manager).balance, 8 ether);
	}

	function test_1() public {
        // Set up our swap parameters
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        console2.log(
            "Before swap Addres(manager).ethBalance:%s, \n raw: %s ", 
            _formatEther(address(manager).balance), address(manager).balance
        );
        console2.log(
            "Before swap Addres(manager).currency1:%s, \n raw: %s ", 
            _formatEther(currency1.balanceOf(address(manager))), currency1.balanceOf(address(manager))
        );
        swapRouter.swap{value: 0.1 ether}(key, params, testSettings, ZERO_BYTES);
        console2.log(
            "After swap Addres(manager).ethBalance:%s, \n raw: %s ",
            _formatEther(address(manager).balance), address(manager).balance
        );

        // zeroForOne + exact-in: unspecified = currency1, fee accumulates in amount1.
        // 1% of ~9.999e15 token1 ≈ 9.999e13 < DONATE_THRESHOLD_MIN (1e14) → no donate.
        InternalSwapPool.ClaimableFees memory fees = hook.poolFees(key);
        assertEq(fees.amount0, 0, "fees should not land in amount0");
        assertGt(fees.amount1, 0, "fees should accumulate in amount1");
    }

    function test_oneForZero_exactIn() public {
        // Selling token1 for ETH, exact input.
        // Unspecified = currency0 (ETH), fee accumulates in amount0, below threshold → no donate.
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: -0.01 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        uint managerEthBefore = address(manager).balance;
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // User paid token1, received ETH from the pool. Manager loses ETH on net.
        assertLt(address(manager).balance, managerEthBefore, "manager ETH must decrease");

        InternalSwapPool.ClaimableFees memory fees = hook.poolFees(key);
        assertGt(fees.amount0, 0, "fees should accumulate in amount0 (ETH)");
        assertEq(fees.amount1, 0, "fees should not land in amount1");
    }

    function test_zeroForOne_exactOut() public {
        // Buying 0.01 token1 with ETH, exact output.
        // Unspecified = currency0 (ETH input). Fee = ~1% of input > threshold → donate triggers.
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 0.01 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap{value: 0.1 ether}(key, params, testSettings, ZERO_BYTES);

        // donate path drained the bucket back to zero.
        InternalSwapPool.ClaimableFees memory fees = hook.poolFees(key);
        assertEq(fees.amount0, 0, "amount0 should be zero after donate");
        assertEq(fees.amount1, 0, "amount1 should remain zero");
    }

    function test_oneForZero_exactOut() public {
        // Buying 0.01 ETH with token1, exact output.
        // Unspecified = currency1 (token1 input). Fee > threshold → donate triggers on currency1.
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: 0.01 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        InternalSwapPool.ClaimableFees memory fees = hook.poolFees(key);
        assertEq(fees.amount0, 0, "amount0 should remain zero");
        assertEq(fees.amount1, 0, "amount1 should be zero after donate");
    }

}