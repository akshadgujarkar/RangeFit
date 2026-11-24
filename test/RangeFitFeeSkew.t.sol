// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {RangeFitHook} from "../src/RangeFitHook.sol";
import {IRangeFit} from "../src/interfaces/IRangeFit.sol";
import {FeeSkew} from "../src/libraries/FeeSkew.sol";
import {SimpleSwapHelper} from "./RangeFitRebalance.t.sol";

/// @title RangeFitFeeSkewTest
/// @notice Comprehensive Milestone 6 tests verifying dynamic directional fee skew.
/// @dev Covers pure math skew calculation, direction mapping, clamps, "override with 0" flag pitfall,
///      and real pool swap integrations demonstrating fee divergence between swap directions.
contract RangeFitFeeSkewTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    Currency currency0;
    Currency currency1;
    MockERC20 token0;
    MockERC20 token1;

    PoolKey poolKey;
    PoolId poolId;

    RangeFitHook hook;
    SimpleSwapHelper swapHelper;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address trader = makeAddr("trader");

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        uint160 hookFlags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            hookFlags,
            type(RangeFitHook).creationCode,
            constructorArgs
        );

        hook = new RangeFitHook{salt: salt}(poolManager);
        require(address(hook) == hookAddress, "Mined address mismatch");

        // Dynamic fee pool at 1:1 price (tick 0, spacing 60)
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        hook.setPoolKey(poolKey);

        swapHelper = new SimpleSwapHelper(poolManager);

        _fundAndApprove(alice, 10_000 ether, 10_000 ether);
        _fundAndApprove(bob, 10_000 ether, 10_000 ether);
        _fundAndApprove(trader, 100_000 ether, 100_000 ether);

        vm.startPrank(trader);
        token0.approve(address(swapHelper), type(uint256).max);
        token1.approve(address(swapHelper), type(uint256).max);
        vm.stopPrank();
    }

    function _fundAndApprove(address user, uint256 amt0, uint256 amt1) internal {
        token0.mint(user, amt0);
        token1.mint(user, amt1);
        vm.startPrank(user);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // 1. Pure Math & Library Unit Tests (FeeSkew.sol)
    // -------------------------------------------------------------------------

    /// @notice Verify skew calculation for balanced, overweight token0, and underweight token0 portfolios.
    function test_SkewCalculation_Accuracy() public pure {
        uint160 price1_1 = Constants.SQRT_PRICE_1_1;
        uint16 target50 = 5000; // 50%

        // 1. Exactly 50/50 balance -> skew = 0
        int256 skewBalanced = FeeSkew.computeSkewBps(100 ether, 100 ether, price1_1, target50);
        assertEq(skewBalanced, 0, "50/50 should have zero skew");

        // 2. 70/30 overweight token0 -> skew = +2000 bps (+20%)
        int256 skewOver0 = FeeSkew.computeSkewBps(70 ether, 30 ether, price1_1, target50);
        assertEq(skewOver0, 2000, "70/30 should have +2000 bps skew");

        // 3. 20/80 underweight token0 -> skew = -3000 bps (-30%)
        int256 skewUnder0 = FeeSkew.computeSkewBps(20 ether, 80 ether, price1_1, target50);
        assertEq(skewUnder0, -3000, "20/80 should have -3000 bps skew");

        // 4. Zero total inventory -> skew = 0
        int256 skewZero = FeeSkew.computeSkewBps(0, 0, price1_1, target50);
        assertEq(skewZero, 0, "Zero inventory should yield zero skew");
    }

    /// @notice Verify Section 9 direction mapping:
    ///         Overweight token0 -> zeroForOne gets HIGHER fee, oneForZero gets LOWER fee.
    function test_DirectionMapping_OverweightToken0() public pure {
        int256 skewBps = 2000; // +20% overweight token0
        uint24 baseFee = 3000; // 0.30%
        uint24 sensitivity = 3000;
        uint24 minFee = 500;
        uint24 maxFee = 10000;

        // zeroForOne == true: adds token0 to pool -> worsens skew -> HIGHER fee
        // adjustment = 2000 * 3000 / 10000 = 600
        // fee = 3000 + 600 = 3600 (0.36%)
        uint24 feeZeroForOne = FeeSkew.computeDirectionalFee(
            skewBps,
            true,
            baseFee,
            sensitivity,
            minFee,
            maxFee
        );
        assertEq(feeZeroForOne, 3600, "zeroForOne fee should be baseFee + adjustment");

        // zeroForOne == false: removes token0 from pool -> improves balance -> LOWER fee
        // fee = 3000 - 600 = 2400 (0.24%)
        uint24 feeOneForZero = FeeSkew.computeDirectionalFee(
            skewBps,
            false,
            baseFee,
            sensitivity,
            minFee,
            maxFee
        );
        assertEq(feeOneForZero, 2400, "oneForZero fee should be baseFee - adjustment");

        assertTrue(feeZeroForOne > feeOneForZero, "zeroForOne fee must exceed oneForZero fee when overweight token0");
    }

    /// @notice Verify Section 9 direction mapping:
    ///         Underweight token0 -> zeroForOne gets LOWER fee, oneForZero gets HIGHER fee.
    function test_DirectionMapping_UnderweightToken0() public pure {
        int256 skewBps = -2000; // -20% underweight token0 (overweight token1)
        uint24 baseFee = 3000;
        uint24 sensitivity = 3000;
        uint24 minFee = 500;
        uint24 maxFee = 10000;

        // zeroForOne == true: adds token0 to pool -> improves balance -> LOWER fee
        // fee = 3000 - 600 = 2400 (0.24%)
        uint24 feeZeroForOne = FeeSkew.computeDirectionalFee(
            skewBps,
            true,
            baseFee,
            sensitivity,
            minFee,
            maxFee
        );
        assertEq(feeZeroForOne, 2400, "zeroForOne fee should be baseFee - adjustment");

        // zeroForOne == false: removes token0 from pool -> worsens skew -> HIGHER fee
        // fee = 3000 + 600 = 3600 (0.36%)
        uint24 feeOneForZero = FeeSkew.computeDirectionalFee(
            skewBps,
            false,
            baseFee,
            sensitivity,
            minFee,
            maxFee
        );
        assertEq(feeOneForZero, 3600, "oneForZero fee should be baseFee + adjustment");

        assertTrue(feeOneForZero > feeZeroForOne, "oneForZero fee must exceed zeroForOne fee when underweight token0");
    }

    /// @notice Verify that dynamic fees are strictly clamped between minFee and maxFee.
    function test_FeeClamping_EnforcesMinMaxBounds() public pure {
        uint24 baseFee = 3000;
        uint24 minFee = 1000;
        uint24 maxFee = 5000;

        // Extreme positive skew with high sensitivity -> clamped to maxFee
        int256 massivePositiveSkew = 5000; // +50%
        uint24 sensitivity = 10000;
        uint24 feeCapped = FeeSkew.computeDirectionalFee(
            massivePositiveSkew,
            true,
            baseFee,
            sensitivity,
            minFee,
            maxFee
        );
        assertEq(feeCapped, maxFee, "Fee must be clamped to maxFee");

        // Extreme negative skew with high sensitivity -> clamped to minFee
        uint24 feeFloored = FeeSkew.computeDirectionalFee(
            massivePositiveSkew,
            false,
            baseFee,
            sensitivity,
            minFee,
            maxFee
        );
        assertEq(feeFloored, minFee, "Fee must be clamped to minFee");
    }

    /// @notice Verify Section 11 Uniswap v4 "override with 0" flag pitfall.
    function test_OverrideWithZero_Pitfall_FlagSemantics() public pure {
        // In Uniswap v4, returning 0 without OVERRIDE_FEE_FLAG does NOT override the fee!
        uint24 feeZeroWithoutFlag = 0;
        assertFalse(
            feeZeroWithoutFlag.isOverride(),
            "Raw 0 does not have OVERRIDE_FEE_FLAG set and will NOT override the fee"
        );

        // To override the fee with 0 (zero fee swap), OVERRIDE_FEE_FLAG must be explicitly set!
        uint24 feeZeroWithFlag = 0 | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        assertTrue(
            feeZeroWithFlag.isOverride(),
            "0 | OVERRIDE_FEE_FLAG correctly sets override flag"
        );
        assertEq(
            feeZeroWithFlag.removeOverrideFlag(),
            0,
            "removeOverrideFlag cleanly recovers 0 fee"
        );
    }

    // -------------------------------------------------------------------------
    // 2. Integration Tests: Real Pool Swaps with Dynamic Fee Divergence
    // -------------------------------------------------------------------------

    /// @notice Integration test verifying that external swaps incur different effective fees
    ///         depending on swap direction when the vault inventory is skewed.
    function test_Integration_SwapFeeDivergence_WhenOverweightToken0() public {
        // 1. Initial balanced position
        vm.prank(alice);
        hook.deposit(200 ether, 200 ether, 0);

        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 1 ether,
            maxDustBps: 500
        }));

        // 2. Alice deposits a large amount of token0 only, skewing vault inventory heavily toward token0
        vm.prank(alice);
        hook.deposit(300 ether, 0, 0);

        (uint256 inv0, uint256 inv1) = hook.inventory();
        assertTrue(inv0 > inv1 * 2, "Vault should be heavily overweight token0");

        // 3. Trader executes exact input swap A: zeroForOne = true (-1 ether token0 in)
        // Since vault is overweight token0, this swap should pay the HIGHER fee
        vm.prank(trader);
        BalanceDelta deltaA = swapHelper.swap(
            poolKey,
            true, // zeroForOne: sends token0
            -1 ether, // exact input
            TickMath.MIN_SQRT_PRICE + 1
        );

        uint256 token1ReceivedA = uint256(uint128(deltaA.amount1()));
        console2.log("Swap A (zeroForOne, adds token0) token1 received:", token1ReceivedA);

        // 4. Reverse swap B to restore price back close to 1:1
        vm.prank(trader);
        swapHelper.swap(
            poolKey,
            false,
            -int256(token1ReceivedA),
            TickMath.MAX_SQRT_PRICE - 1
        );

        // Now disable feeSkew
        hook.setFeeSkewEnabled(false);
        assertFalse(hook.feeSkewEnabled());

        // Perform standard exact input swap with baseline fee (0.30%)
        vm.prank(trader);
        BalanceDelta deltaBaseline = swapHelper.swap(
            poolKey,
            true,
            -1 ether, // exact input
            TickMath.MIN_SQRT_PRICE + 1
        );
        uint256 token1ReceivedBaseline = uint256(uint128(deltaBaseline.amount1()));
        console2.log("Swap Baseline (feeSkew disabled) token1 received:", token1ReceivedBaseline);

        // When fee skew was active and vault was overweight token0,
        // the higher fee resulted in LESS token1 received than baseline!
        assertTrue(
            token1ReceivedA < token1ReceivedBaseline,
            "Higher fee on zeroForOne swap must yield strictly less output than baseline"
        );
    }

    /// @notice Integration test verifying that swaps improving vault balance receive a fee discount.
    function test_Integration_SwapFeeDiscount_WhenImprovingBalance() public {
        // Alice deposits balanced liquidity
        vm.prank(alice);
        hook.deposit(200 ether, 200 ether, 0);

        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 1 ether,
            maxDustBps: 500
        }));

        // Alice deposits extra token1, making vault heavily overweight token1
        vm.prank(alice);
        hook.deposit(0, 300 ether, 0);

        (uint256 inv0, uint256 inv1) = hook.inventory();
        assertTrue(inv1 > inv0 * 2, "Vault should be heavily overweight token1");

        // When overweight token1, a zeroForOne swap (sends token0, takes token1) IMPROVES balance!
        // Therefore zeroForOne should receive a DISCOUNTED lower fee (< baseFee)
        vm.prank(trader);
        BalanceDelta deltaDiscounted = swapHelper.swap(
            poolKey,
            true, // zeroForOne
            -1 ether, // exact input
            TickMath.MIN_SQRT_PRICE + 1
        );
        uint256 token1ReceivedDiscounted = uint256(uint128(deltaDiscounted.amount1()));

        // Restore pool
        vm.prank(trader);
        swapHelper.swap(
            poolKey,
            false,
            -int256(token1ReceivedDiscounted),
            TickMath.MAX_SQRT_PRICE - 1
        );

        // Compare against baseline (skew disabled)
        hook.setFeeSkewEnabled(false);
        vm.prank(trader);
        BalanceDelta deltaBaseline = swapHelper.swap(
            poolKey,
            true,
            -1 ether, // exact input
            TickMath.MIN_SQRT_PRICE + 1
        );
        uint256 token1ReceivedBaseline = uint256(uint128(deltaBaseline.amount1()));

        // The discounted swap received MORE token1 output than baseline because of lower swap fees!
        assertTrue(
            token1ReceivedDiscounted > token1ReceivedBaseline,
            "Discounted swap must yield strictly more output than baseline"
        );
    }

    // -------------------------------------------------------------------------
    // 3. Admin Governance & Parameter Validation Tests
    // -------------------------------------------------------------------------

    /// @notice Verify admin can update fee parameters and access control is enforced.
    function test_Admin_FeeConfiguration() public {
        // Non-owner reverts
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IRangeFit.OnlyOwner.selector, trader));
        hook.setFeeSkewEnabled(false);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IRangeFit.OnlyOwner.selector, trader));
        hook.setFeeParams(2000, 2000, 300, 8000, 5000);

        // Owner can toggle fee skew
        hook.setFeeSkewEnabled(false);
        assertFalse(hook.feeSkewEnabled());

        hook.setFeeSkewEnabled(true);
        assertTrue(hook.feeSkewEnabled());

        // Owner can set valid parameters
        hook.setFeeParams(2500, 4000, 400, 9000, 6000);
        assertEq(hook.baseFee(), 2500);
        assertEq(hook.feeSensitivity(), 4000);
        assertEq(hook.minFee(), 400);
        assertEq(hook.maxFee(), 9000);
        assertEq(hook.targetRatioBps(), 6000);

        // Invalid parameter combinations revert
        // Case 1: minFee > maxFee
        vm.expectRevert(
            abi.encodeWithSelector(IRangeFit.InvalidFeeParameters.selector, 5000, 3000, 4000)
        );
        hook.setFeeParams(4000, 1000, 5000, 3000, 5000);

        // Case 2: baseFee < minFee
        vm.expectRevert(
            abi.encodeWithSelector(IRangeFit.InvalidFeeParameters.selector, 1000, 5000, 800)
        );
        hook.setFeeParams(800, 1000, 1000, 5000, 5000);

        // Case 3: baseFee > maxFee
        vm.expectRevert(
            abi.encodeWithSelector(IRangeFit.InvalidFeeParameters.selector, 1000, 5000, 6000)
        );
        hook.setFeeParams(6000, 1000, 1000, 5000, 5000);

        // Case 4: targetRatioBps > 10000
        vm.expectRevert(
            abi.encodeWithSelector(IRangeFit.InvalidFeeParameters.selector, 1000, 5000, 3000)
        );
        hook.setFeeParams(3000, 1000, 1000, 5000, 12000);
    }
}
