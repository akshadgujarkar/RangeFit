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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {RangeFitHook} from "../src/RangeFitHook.sol";
import {IRangeFit} from "../src/interfaces/IRangeFit.sol";
import {RangeMath} from "../src/libraries/RangeMath.sol";

/// @notice Helper router simulating external traders executing swaps on the pool.
contract SimpleSwapHelper is IUnlockCallback {
    IPoolManager immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) external returns (BalanceDelta delta) {
        bytes memory data = manager.unlock(
            abi.encode(key, zeroForOne, amountSpecified, sqrtPriceLimitX96, msg.sender)
        );
        delta = abi.decode(data, (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        (
            PoolKey memory key,
            bool zeroForOne,
            int256 amountSpecified,
            uint160 sqrtPriceLimitX96,
            address sender
        ) = abi.decode(rawData, (PoolKey, bool, int256, uint160, address));

        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        if (delta.amount0() < 0) {
            uint256 pay0 = uint256(uint128(-delta.amount0()));
            manager.sync(key.currency0);
            MockERC20(Currency.unwrap(key.currency0)).transferFrom(sender, address(manager), pay0);
            manager.settle();
        } else if (delta.amount0() > 0) {
            manager.take(key.currency0, sender, uint256(uint128(delta.amount0())));
        }

        if (delta.amount1() < 0) {
            uint256 pay1 = uint256(uint128(-delta.amount1()));
            manager.sync(key.currency1);
            MockERC20(Currency.unwrap(key.currency1)).transferFrom(sender, address(manager), pay1);
            manager.settle();
        } else if (delta.amount1() > 0) {
            manager.take(key.currency1, sender, uint256(uint128(delta.amount1())));
        }

        return abi.encode(delta);
    }
}

/// @title RangeFitRebalanceTest
/// @notice Comprehensive Milestone 4 tests verifying swapless rebalancing, position lifecycle,
///         zero-swap guarantees, dust reinvestment, LP fee compounding, and Section 8.6 Invariants.
contract RangeFitRebalanceTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

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
    address keeper = makeAddr("keeper");

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

        // Initialize pool at 1:1 price (tick 0, spacing 60)
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Configure hook
        hook.setPoolKey(poolKey);

        // Deploy swap helper
        swapHelper = new SimpleSwapHelper(poolManager);

        // Fund test accounts
        _fundAndApprove(alice, 1000 ether, 1000 ether);
        _fundAndApprove(bob, 1000 ether, 1000 ether);
        _fundAndApprove(trader, 1000 ether, 1000 ether);
        _fundAndApprove(keeper, 1000 ether, 1000 ether);

        // Approve swap helper for trader
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
    // Core Rebalance Tests
    // -------------------------------------------------------------------------

    /// @notice Test initial position deployment directly from idle deposits.
    function test_InitialRebalance_DeploysLiquidityFromIdle() public {
        // Alice deposits 100 token0 and 100 token1 into idle
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        assertEq(hook.liquidity(), 0);
        assertEq(hook.idle0(), 100 ether);
        assertEq(hook.idle1(), 100 ether);

        // Range: [-120, 120] symmetric around tick 0
        IRangeFit.RebalanceParams memory params = IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 1 ether,
            maxDustBps: 500 // 5%
        });

        uint256 gasBefore = gasleft();
        uint128 mintedLiq = hook.rebalance(params);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas used for initial rebalance:", gasUsed);

        assertTrue(mintedLiq > 0, "Liquidity should be deployed");
        assertEq(hook.liquidity(), mintedLiq);
        assertEq(hook.tickLower(), -120);
        assertEq(hook.tickUpper(), 120);

        // Idle tokens should now only be the leftover dust
        assertTrue(hook.idle0() < 1 ether, "Idle0 should be small dust");
        assertTrue(hook.idle1() < 1 ether, "Idle1 should be small dust");

        // Inventory should still reflect full assets (deployed + dust)
        (uint256 inv0, uint256 inv1) = hook.inventory();
        assertApproxEqRel(inv0, 100 ether, 0.001e18);
        assertApproxEqRel(inv1, 100 ether, 0.001e18);
    }

    /// @notice Test swapless rebalance after external trader swaps push price and shift inventory.
    function test_SwaplessRebalance_AfterPriceMove() public {
        // Alice deposits and deploys initial position
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 1 ether,
            maxDustBps: 500
        }));

        // Trader swaps token0 for token1 (exact input 2 ether token0)
        // This shifts pool price down (tick becomes negative)
        vm.prank(trader);
        swapHelper.swap(poolKey, true, -2 ether, TickMath.MIN_SQRT_PRICE + 1);

        (, int24 tickAfterSwap, , ) = poolManager.getSlot0(poolId);
        assertTrue(tickAfterSwap < 0, "Price should have moved downwards");
        console2.log("Tick after swap:", tickAfterSwap);

        // Solve for the exact range that fits the new inventory after the swap
        (uint256 curInv0, uint256 curInv1) = hook.inventory();
        (uint160 curSpot, , , ) = poolManager.getSlot0(poolId);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(-180);
        (, uint160 solvedUpper) = RangeMath.solveRange(curSpot, sqrtLower, curInv0, curInv1);
        (int24 newLower, int24 newUpper) = RangeMath.alignTicksToSpacing(sqrtLower, solvedUpper, 60);
        if (newUpper <= TickMath.getTickAtSqrtPrice(curSpot)) {
            newUpper += 60;
        }

        IRangeFit.RebalanceParams memory newParams = IRangeFit.RebalanceParams({
            newTickLower: newLower,
            newTickUpper: newUpper,
            minLiquidity: 1 ether,
            maxDustBps: 2000
        });

        uint256 gasBefore = gasleft();
        uint128 newLiq = hook.rebalance(newParams);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas used for re-ranging rebalance:", gasUsed);

        assertEq(hook.tickLower(), newLower);
        assertEq(hook.tickUpper(), newUpper);
        assertEq(hook.liquidity(), newLiq);
        assertTrue(newLiq > 0, "New liquidity should be active");
    }

    /// @notice Test Invariant 3: Zero swap occurred during the vault's rebalance operation.
    function test_ZeroSwap_Verification() public {
        vm.prank(alice);
        hook.deposit(50 ether, 50 ether, 0);

        // Spot price before rebalance
        (uint160 priceBefore, int24 tickBefore, , ) = poolManager.getSlot0(poolId);

        // Execute rebalance
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -60,
            newTickUpper: 60,
            minLiquidity: 1 ether,
            maxDustBps: 500
        }));

        // Spot price after rebalance
        (uint160 priceAfter, int24 tickAfter, , ) = poolManager.getSlot0(poolId);

        // Section 8.6 Invariant 3: Pool price is completely unchanged by the vault's own call!
        assertEq(priceAfter, priceBefore, "Spot price MUST NOT change during rebalance");
        assertEq(tickAfter, tickBefore, "Tick MUST NOT change during rebalance");
    }

    /// @notice Test that dust from one rebalance remains in the vault and is reinvested in the next rebalance.
    function test_DustRetention_AndReinvestment() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        // Rebalance 1
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 1 ether,
            maxDustBps: 500
        }));

        uint256 dust0_after1 = hook.idle0();

        // Bob deposits additional single-sided token0
        vm.prank(bob);
        hook.deposit(10 ether, 0, 0);

        // Total idle0 now includes previous dust0 + bob's deposit
        assertEq(hook.idle0(), dust0_after1 + 10 ether);

        // Rebalance 2 absorbs both bob's deposit and prior dust
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 1 ether,
            maxDustBps: 1000
        }));

        assertTrue(hook.liquidity() > 0);
    }

    /// @notice Test that accrued LP fees from trader swaps are compounded into new liquidity on rebalance.
    function test_FeeCompounding_IntoNewLiquidity() public {
        vm.prank(alice);
        hook.deposit(100 ether, 100 ether, 0);

        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 1 ether,
            maxDustBps: 500
        }));

        // Trader swaps back and forth, generating trading fees without shifting net price much
        vm.startPrank(trader);
        swapHelper.swap(poolKey, true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        swapHelper.swap(poolKey, false, -1 ether, TickMath.MAX_SQRT_PRICE - 1);
        vm.stopPrank();

        uint256 valueBeforeRebalance = hook.totalVaultValue();

        // Keeper rebalances
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 1 ether,
            maxDustBps: 500
        }));

        uint256 valueAfterRebalance = hook.totalVaultValue();

        // Total vault value is preserved / increased from fees
        assertGe(valueAfterRebalance + 1000, valueBeforeRebalance, "Value must be preserved with fees");
    }

    /// @notice Test Invariant 4: Value preservation after rebalance (Value_after >= Value_before * (1 - epsilon)).
    function test_Invariant_4_ValuePreservation() public {
        vm.prank(alice);
        hook.deposit(80 ether, 120 ether, 0);

        uint256 valueBefore = hook.totalVaultValue();

        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 1 ether,
            maxDustBps: 2500
        }));

        uint256 valueAfter = hook.totalVaultValue();

        // Allowed loss is epsilon (max dust is 10% = 1000 bps, but actual value change should be < 0.1%)
        // Value_after >= Value_before * 99.9%
        uint256 minAllowedValue = FullMath.mulDiv(valueBefore, 999, 1000);
        assertGe(valueAfter, minAllowedValue, "Invariant 4: Vault value must be preserved within epsilon");
    }

    /// @notice Test Invariant 5: Net deltas settle cleanly to zero with no CurrencyNotSettled revert.
    function test_Invariant_5_DeltasSettle() public {
        vm.prank(alice);
        hook.deposit(50 ether, 50 ether, 0);

        // If deltas did not settle to 0, poolManager.unlock() would revert with CurrencyNotSettled
        // Successful execution verifies Invariant 5
        uint128 newLiq = hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -60,
            newTickUpper: 60,
            minLiquidity: 1 ether,
            maxDustBps: 500
        }));

        assertTrue(newLiq > 0, "Deltas settled and position successfully minted");
    }

    /// @notice Test in-range pro-rata withdrawal removing both idle reserves and active position liquidity.
    function test_Withdraw_WhilePositionActive_FairProRata() public {
        vm.prank(alice);
        hook.deposit(60 ether, 60 ether, 0);

        vm.prank(bob);
        hook.deposit(40 ether, 40 ether, 0);

        // Deploy position
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 1 ether,
            maxDustBps: 500
        }));

        uint128 totalLiqBefore = hook.liquidity();
        uint256 bobShares = hook.shares(bob);
        uint256 totalShares = hook.totalShares();

        // Bob withdraws all his shares
        uint256 expectedLiqBurned = FullMath.mulDiv(uint256(totalLiqBefore), bobShares, totalShares);

        uint256 bobBal0Before = token0.balanceOf(bob);
        uint256 bobBal1Before = token1.balanceOf(bob);

        vm.prank(bob);
        (uint256 out0, uint256 out1) = hook.withdraw(bobShares, 0, 0);

        // Bob should receive tokens from both idle and the active position
        assertTrue(out0 > 0, "Bob should receive token0");
        assertTrue(out1 > 0, "Bob should receive token1");
        assertEq(token0.balanceOf(bob), bobBal0Before + out0);
        assertEq(token1.balanceOf(bob), bobBal1Before + out1);

        // Position liquidity should be reduced by Bob's pro-rata share
        assertApproxEqAbs(
            uint256(hook.liquidity()),
            totalLiqBefore - expectedLiqBurned,
            2,
            "Liquidity must be reduced pro-rata"
        );

        // Alice's value should remain intact (Section 8.6 Invariant 7: No cross-user leakage)
        assertApproxEqRel(hook.userValue(alice), 120 ether, 0.01e18);
    }

    /// @notice Test previewRebalance view function matches actual rebalance outcome.
    function test_PreviewRebalance_MatchesActual() public {
        vm.prank(alice);
        hook.deposit(50 ether, 50 ether, 0);

        (
            uint128 prevLiq,
            uint256 prevUsed0,
            uint256 prevUsed1,
            uint256 prevDust0,
            uint256 prevDust1,
            uint256 prevDustBps
        ) = hook.previewRebalance(-120, 120);

        assertTrue(prevLiq > 0);
        assertTrue(prevUsed0 > 0);
        assertTrue(prevUsed1 > 0);
        assertTrue(prevDustBps < 500);

        uint128 actualLiq = hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 1000
        }));

        assertEq(actualLiq, prevLiq, "Previewed liquidity must match actual");
        assertEq(hook.idle0(), prevDust0, "Previewed dust0 must match actual idle0");
        assertEq(hook.idle1(), prevDust1, "Previewed dust1 must match actual idle1");
    }

    // -------------------------------------------------------------------------
    // Revert / Failure Mode Tests
    // -------------------------------------------------------------------------

    /// @notice Rebalance reverts if ticks are not integer multiples of tickSpacing.
    function test_Revert_Rebalance_UnalignedTicks() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        // tickSpacing is 60; -50 is not aligned
        vm.expectRevert(
            abi.encodeWithSelector(IRangeFit.TicksNotAligned.selector, int24(-50), int24(60))
        );
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -50,
            newTickUpper: 60,
            minLiquidity: 0,
            maxDustBps: 500
        }));
    }

    /// @notice Rebalance reverts if tickLower >= tickUpper.
    function test_Revert_Rebalance_InvalidTickRange() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        vm.expectRevert(
            abi.encodeWithSelector(IRangeFit.InvalidTickRange.selector, int24(60), int24(-60))
        );
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: 60,
            newTickUpper: -60,
            minLiquidity: 0,
            maxDustBps: 500
        }));
    }

    /// @notice Rebalance reverts if current spot price is outside the proposed range.
    function test_Revert_Rebalance_PriceOutOfRange() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        // Spot price is at tick 0. Range [60, 120] does not contain tick 0
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(60);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(120);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRangeFit.PriceOutOfRange.selector,
                Constants.SQRT_PRICE_1_1,
                sqrtLower,
                sqrtUpper
            )
        );
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: 60,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 500
        }));
    }

    /// @notice Rebalance reverts if slippage bound minLiquidity is not met.
    function test_Revert_Rebalance_InsufficientLiquidity() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        vm.expectRevert();
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -60,
            newTickUpper: 60,
            minLiquidity: 1_000_000 ether, // Impossible minLiquidity
            maxDustBps: 1000
        }));
    }

    /// @notice Rebalance reverts if dust exceeds maxDustBps limit.
    function test_Revert_Rebalance_DustToleranceExceeded() public {
        // Asymmetric deposit: 100 token0 and 1 token1
        vm.prank(alice);
        hook.deposit(100 ether, 1 ether, 0);

        // Symmetric range [-60, 60] with 100:1 inventory will leave almost all token0 as dust (~98% dust)
        vm.expectRevert();
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -60,
            newTickUpper: 60,
            minLiquidity: 0,
            maxDustBps: 50 // Strict 0.5% max dust
        }));
    }
}
