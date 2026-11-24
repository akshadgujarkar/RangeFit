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

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {RangeFitHook} from "../src/RangeFitHook.sol";
import {IRangeFit} from "../src/interfaces/IRangeFit.sol";
import {Guards} from "../src/libraries/Guards.sol";
import {SimpleSwapHelper} from "./RangeFitRebalance.t.sol";

/// @notice Malicious reentrant contract attempting to reenter RangeFitHook during execution.
contract MaliciousReentrantCaller is IUnlockCallback {
    IPoolManager immutable manager;
    RangeFitHook immutable hook;
    bool public attacked;

    constructor(IPoolManager _manager, RangeFitHook _hook) {
        manager = _manager;
        hook = _hook;
    }

    function attackRebalance(IRangeFit.RebalanceParams memory params) external {
        // Attempt unlock then reenter
        manager.unlock(abi.encode(params));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        IRangeFit.RebalanceParams memory params = abi.decode(data, (IRangeFit.RebalanceParams));
        attacked = true;
        // Reentrant call into hook.rebalance
        hook.rebalance(params);
        return "";
    }
}

/// @title RangeFitGuardsTest
/// @notice Comprehensive Milestone 5 security and attack test suite.
/// @dev Covers price manipulation defense, cooldowns, keeper permissions, width bounds,
///      continuous EMA smoothing, reentrancy defense, donation resilience, and no-valid-range fallback.
contract RangeFitGuardsTest is BaseTest {
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
    address attacker = makeAddr("attacker");

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

        // Fund accounts
        _fundAndApprove(alice, 10_000 ether, 10_000 ether);
        _fundAndApprove(bob, 10_000 ether, 10_000 ether);
        _fundAndApprove(trader, 100_000 ether, 100_000 ether);
        _fundAndApprove(keeper, 10_000 ether, 10_000 ether);
        _fundAndApprove(attacker, 100_000 ether, 100_000 ether);

        // Approve swap helper
        vm.prank(trader);
        token0.approve(address(swapHelper), type(uint256).max);
        vm.prank(trader);
        token1.approve(address(swapHelper), type(uint256).max);

        vm.prank(attacker);
        token0.approve(address(swapHelper), type(uint256).max);
        vm.prank(attacker);
        token1.approve(address(swapHelper), type(uint256).max);
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
    // 1. Attack Test: Flash-Loan / Large Swap Price Manipulation Guard
    // -------------------------------------------------------------------------

    /// @notice Verify that manipulation of spot price beyond maxDeviationBps is blocked by the deviation guard.
    function test_Attack_PriceManipulation_Reverts() public {
        // 1. Alice deposits into vault and initial position is deployed
        vm.prank(alice);
        hook.deposit(500 ether, 500 ether, 0);

        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 1 ether,
            maxDustBps: 500
        }));

        // Configure guard tolerance to 15 bps to test sensitivity within position bounds
        hook.setMaxDeviationBps(15);
        assertEq(hook.maxDeviationBps(), 15);
        assertEq(hook.emaSqrtPriceX96(), Constants.SQRT_PRICE_1_1);

        // 2. Attacker executes a swap to manipulate spot price
        vm.prank(attacker);
        swapHelper.swap(
            poolKey,
            true, // zeroForOne
            200 ether,
            TickMath.MIN_SQRT_PRICE + 1
        );

        (uint160 spotPriceX96,,,) = poolManager.getSlot0(poolId);
        uint160 currentEma = hook.emaSqrtPriceX96();

        // The spot price has moved significantly away from EMA
        uint256 devBps = Guards.computeDeviationBps(spotPriceX96, currentEma);
        console2.log("Manipulated spotPriceX96:", spotPriceX96);
        console2.log("Current smoothed EMA:", currentEma);
        console2.log("Computed Deviation BPS:", devBps);
        assertTrue(devBps > 15, "Deviation should exceed 15 bps");

        // 3. Attacker tries to execute rebalance at this manipulated price -> MUST REVERT
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRangeFit.PriceDeviationTooHigh.selector,
                spotPriceX96,
                currentEma,
                devBps,
                15
            )
        );
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -240,
            newTickUpper: 60,
            minLiquidity: 0,
            maxDustBps: 10_000
        }));

        // 4. Arbitrageur swaps back, restoring spot price close to EMA
        vm.prank(trader);
        swapHelper.swap(
            poolKey,
            false, // oneForZero
            190 ether,
            TickMath.MAX_SQRT_PRICE - 1
        );

        (uint160 restoredSpot,,,) = poolManager.getSlot0(poolId);
        uint160 restoredEma = hook.emaSqrtPriceX96();
        uint256 restoredDev = Guards.computeDeviationBps(restoredSpot, restoredEma);
        console2.log("Restored Deviation BPS:", restoredDev);
        assertTrue(restoredDev <= 15, "Restored price should be within guard tolerance");

        // Now rebalance succeeds!
        vm.warp(block.timestamp + 61); // ensure cooldown passes
        uint128 newLiq = hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 10_000
        }));
        assertTrue(newLiq > 0, "Rebalance must succeed once price is restored");
    }

    /// @notice Verify deviation guard with large price shift (>1000 bps) reverts under default maxDeviationBps.
    function test_Attack_LargeDeviation_RevertsUnderDefault1000Bps() public {
        vm.prank(alice);
        hook.deposit(500 ether, 500 ether, 0);

        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 1 ether,
            maxDustBps: 500
        }));

        assertEq(hook.maxDeviationBps(), 1000); // 10% default

        // Simulate EMA lagging behind at 1:1 price while spot moves or EMA set to 1.15x
        uint160 currentSpot = Constants.SQRT_PRICE_1_1;
        // 12% lower EMA in Q96: currentSpot * 88 / 100
        uint160 laggingEma = uint160((uint256(currentSpot) * 88) / 100);
        hook.setEmaPrice(laggingEma);

        uint256 devBps = Guards.computeDeviationBps(currentSpot, laggingEma);
        assertTrue(devBps > 1000, "Deviation should exceed default 1000 bps");

        vm.expectRevert(
            abi.encodeWithSelector(
                IRangeFit.PriceDeviationTooHigh.selector,
                currentSpot,
                laggingEma,
                devBps,
                1000
            )
        );
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 1000
        }));
    }

    // -------------------------------------------------------------------------
    // 2. Cooldown Enforcement Tests
    // -------------------------------------------------------------------------

    /// @notice Verify that rebalances cannot be executed faster than the configured cooldown.
    function test_Cooldown_Enforcement() public {
        vm.prank(alice);
        hook.deposit(200 ether, 200 ether, 0);

        // First rebalance at t=1
        vm.warp(100);
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 1 ether,
            maxDustBps: 500
        }));
        assertEq(hook.lastRebalance(), 100);

        // Setting cooldown to 300 seconds
        hook.setCooldown(300);
        assertEq(hook.cooldown(), 300);

        // Immediate subsequent rebalance at same timestamp -> REVERTS
        vm.expectRevert(
            abi.encodeWithSelector(IRangeFit.CooldownActive.selector, 100 + 300, 100)
        );
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 500
        }));

        // Warp to t = 399 (299s elapsed, cooldown still active) -> REVERTS
        vm.warp(399);
        vm.expectRevert(
            abi.encodeWithSelector(IRangeFit.CooldownActive.selector, 100 + 300, 399)
        );
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 500
        }));

        // Warp to t = 400 (exactly 300s elapsed) -> SUCCEEDS
        vm.warp(400);
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 500
        }));
        assertEq(hook.lastRebalance(), 400);
    }

    // -------------------------------------------------------------------------
    // 3. Keeper Allowlist & Permission Control Tests
    // -------------------------------------------------------------------------

    /// @notice Verify keeper-only mode restricts rebalances to allowlisted keepers.
    function test_KeeperAllowlist_Enforcement() public {
        vm.prank(alice);
        hook.deposit(200 ether, 200 ether, 0);

        // 1. By default, keeperOnly is false (permissionless)
        assertFalse(hook.keeperOnly());
        vm.prank(trader);
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 500
        }));

        // 2. Enable keeperOnly mode
        hook.setKeeperOnly(true);
        assertTrue(hook.keeperOnly());

        // Configure allowlisted keeper
        hook.setKeeper(keeper, true);
        assertTrue(hook.isKeeper(keeper));
        assertFalse(hook.isKeeper(trader));

        vm.warp(block.timestamp + 61);

        // 3. Unauthorized trader attempts rebalance -> REVERTS
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IRangeFit.UnauthorizedKeeper.selector, trader));
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 500
        }));

        // 4. Authorized keeper attempts rebalance -> SUCCEEDS
        vm.prank(keeper);
        uint128 liq = hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 500
        }));
        assertTrue(liq > 0, "Authorized keeper should succeed");

        // 5. Revoke keeper
        hook.setKeeper(keeper, false);
        assertFalse(hook.isKeeper(keeper));

        vm.warp(block.timestamp + 61);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IRangeFit.UnauthorizedKeeper.selector, keeper));
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 500
        }));

        // 6. Disable keeperOnly -> trader can rebalance again
        hook.setKeeperOnly(false);
        vm.prank(trader);
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 500
        }));
    }

    // -------------------------------------------------------------------------
    // 4. Range Width Bounds Tests
    // -------------------------------------------------------------------------

    /// @notice Verify enforcement of minWidthTicks and maxWidthTicks constraints.
    function test_RangeWidthBounds_Enforcement() public {
        vm.prank(alice);
        hook.deposit(200 ether, 200 ether, 0);

        // Set bounds: min 120 ticks, max 600 ticks
        hook.setWidthBounds(120, 600);
        assertEq(hook.minWidthTicks(), 120);
        assertEq(hook.maxWidthTicks(), 600);

        // Case A: Proposed range width 60 ticks < minWidthTicks (120) -> RangeTooNarrow
        vm.expectRevert(abi.encodeWithSelector(IRangeFit.RangeTooNarrow.selector, 60, 120));
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -60,
            newTickUpper: 0,
            minLiquidity: 0,
            maxDustBps: 1000
        }));

        // Case B: Proposed range width 720 ticks > maxWidthTicks (600) -> RangeTooWide
        vm.expectRevert(abi.encodeWithSelector(IRangeFit.RangeTooWide.selector, 720, 600));
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -360,
            newTickUpper: 360,
            minLiquidity: 0,
            maxDustBps: 1000
        }));

        // Case C: Valid width 240 ticks within [120, 600] -> SUCCEEDS
        uint128 liq = hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 1000
        }));
        assertTrue(liq > 0, "Valid range width should succeed");
    }

    // -------------------------------------------------------------------------
    // 5. Continuous EMA Smoothing & RebalanceDue Flag Tests
    // -------------------------------------------------------------------------

    /// @notice Verify that EMA smoothly updates across swaps and detects edge proximity.
    function test_ContinuousEMA_SmoothingAndRebalanceDue() public {
        vm.prank(alice);
        hook.deposit(500 ether, 500 ether, 0);

        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 500
        }));

        uint160 initialEma = hook.emaSqrtPriceX96();
        assertEq(initialEma, Constants.SQRT_PRICE_1_1);
        assertFalse(hook.rebalanceDue(), "rebalanceDue initially false");

        // Swap 1: trader swaps 5 ether token0 -> token1
        vm.prank(trader);
        swapHelper.swap(
            poolKey,
            true,
            5 ether,
            TickMath.MIN_SQRT_PRICE + 1
        );

        (uint160 spot1,,,) = poolManager.getSlot0(poolId);
        uint160 ema1 = hook.emaSqrtPriceX96();

        // Spot moved down, so ema should move down, but strictly: spot1 < ema1 < initialEma
        assertTrue(spot1 < initialEma, "Spot should have dropped");
        assertTrue(ema1 < initialEma, "EMA should have dropped");
        assertTrue(spot1 < ema1, "EMA should be smoothed (higher than instantaneous spot)");

        // Check exact smoothing formula with alpha = 1000 (10%)
        uint160 expectedEma1 = Guards.updateEMA(initialEma, spot1, 1000);
        assertEq(ema1, expectedEma1, "EMA must match Guards.updateEMA");

        // Swap 2: trader swaps more token0 to push price near the lower tick boundary (-120)
        vm.prank(trader);
        swapHelper.swap(
            poolKey,
            true,
            30 ether,
            TickMath.MIN_SQRT_PRICE + 1
        );

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        console2.log("Tick after swap 2:", currentTick);

        // Near tickLower (-120), edge threshold is 20% of 240 ticks = 48 ticks
        // If currentTick <= -72 (-120 + 48), rebalanceDue should trigger
        if (currentTick <= -72) {
            assertTrue(hook.rebalanceDue(), "rebalanceDue should be flagged near boundary");
        }

        // Executing rebalance resets rebalanceDue
        vm.warp(block.timestamp + 61);
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -240,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 10_000
        }));

        assertFalse(hook.rebalanceDue(), "rebalanceDue must reset to false after rebalance");
    }

    // -------------------------------------------------------------------------
    // 6. Reentrancy Defense Tests
    // -------------------------------------------------------------------------

    /// @notice Verify that reentrancy into hook functions is prevented.
    function test_Reentrancy_Defense() public {
        MaliciousReentrantCaller attackerContract = new MaliciousReentrantCaller(poolManager, hook);

        IRangeFit.RebalanceParams memory params = IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 500
        });

        // The malicious contract tries to call rebalance from within an unlock callback
        // The manager's lock is active and hook.rebalance will attempt manager.unlock, which reverts
        vm.expectRevert();
        attackerContract.attackRebalance(params);
    }

    // -------------------------------------------------------------------------
    // 7. Donation & Dust Resilience Tests
    // -------------------------------------------------------------------------

    /// @notice Verify direct unsolicited ERC20 transfers to hook do not corrupt share accounting.
    function test_DonationAndDustResilience() public {
        // Alice deposits
        vm.prank(alice);
        uint256 aliceShares = hook.deposit(100 ether, 100 ether, 0);

        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 500
        }));

        uint256 assetsBefore = hook.totalVaultValue();
        (uint256 inv0Before, uint256 inv1Before) = hook.inventory();

        // Attacker donates 50 ether of token0 directly to hook contract address
        token0.mint(address(hook), 50 ether);
        token1.mint(address(hook), 50 ether);

        // Total assets tracked by the vault depends on internal inventory, not raw token balance
        uint256 assetsAfter = hook.totalVaultValue();
        (uint256 inv0After, uint256 inv1After) = hook.inventory();
        assertEq(assetsBefore, assetsAfter, "Direct donations should not inflate internal vault totalVaultValue");
        assertEq(inv0Before, inv0After, "Inventory 0 unaffected by raw donation");
        assertEq(inv1Before, inv1After, "Inventory 1 unaffected by raw donation");

        // Bob deposits 100 ether of each token
        vm.prank(bob);
        uint256 bobShares = hook.deposit(100 ether, 100 ether, 0);

        // Share minting is not diluted or manipulated by the donation
        assertTrue(bobShares > 0, "Bob should receive shares");
        assertApproxEqRel(bobShares, aliceShares, 0.05e18, "Bob's shares should be proportional to real assets");

        // Alice withdraws all her shares
        vm.prank(alice);
        (uint256 out0, uint256 out1) = hook.withdraw(aliceShares, 0, 0);
        assertTrue(out0 > 0 && out1 > 0, "Alice should receive her assets");
    }

    // -------------------------------------------------------------------------
    // 8. No-Valid-Range Fallback (Graceful Degradation)
    // -------------------------------------------------------------------------

    /// @notice Verify user withdrawals still work when no feasible active range can be formed.
    function test_NoValidRange_FallbackWithdrawalsWork() public {
        // User deposits 100% token0 (zero token1)
        // With price at 1:1, an active concentrated range containing tick 0 requires BOTH tokens.
        // Therefore, inventory (100 token0, 0 token1) is infeasible for an active range.
        vm.prank(alice);
        uint256 aliceShares = hook.deposit(100 ether, 0, 0);

        // Attempting to rebalance into an active range containing spot price reverts InfeasibleInventory
        vm.expectRevert(IRangeFit.InfeasibleInventory.selector);
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -120,
            newTickUpper: 120,
            minLiquidity: 0,
            maxDustBps: 1000
        }));

        // Position liquidity remains 0
        assertEq(hook.liquidity(), 0);

        // Alice can still withdraw her shares pro-rata without any loss or lockup
        vm.prank(alice);
        (uint256 out0, uint256 out1) = hook.withdraw(aliceShares, 0, 0);
        assertEq(out0, 100 ether - hook.DEAD_SHARES(), "Alice should withdraw her full deposited token0 minus dead shares");
        assertEq(out1, 0, "Alice should receive 0 token1");
        assertEq(hook.idle0(), hook.DEAD_SHARES(), "Dead shares permanently retain 1000 wei in vault");
    }

    // -------------------------------------------------------------------------
    // 9. Admin Functions & Access Control Tests
    // -------------------------------------------------------------------------

    /// @notice Verify only the owner can call administrative functions and transfer ownership.
    function test_Admin_AccessControl() public {
        // Non-owner (trader) calls revert
        vm.startPrank(trader);

        vm.expectRevert(abi.encodeWithSelector(IRangeFit.OnlyOwner.selector, trader));
        hook.setKeeper(keeper, true);

        vm.expectRevert(abi.encodeWithSelector(IRangeFit.OnlyOwner.selector, trader));
        hook.setKeeperOnly(true);

        vm.expectRevert(abi.encodeWithSelector(IRangeFit.OnlyOwner.selector, trader));
        hook.setCooldown(120);

        vm.expectRevert(abi.encodeWithSelector(IRangeFit.OnlyOwner.selector, trader));
        hook.setMaxDeviationBps(500);

        vm.expectRevert(abi.encodeWithSelector(IRangeFit.OnlyOwner.selector, trader));
        hook.setWidthBounds(60, 1200);

        vm.expectRevert(abi.encodeWithSelector(IRangeFit.OnlyOwner.selector, trader));
        hook.setEmaAlpha(500);

        vm.expectRevert(abi.encodeWithSelector(IRangeFit.OnlyOwner.selector, trader));
        hook.setEmaPrice(Constants.SQRT_PRICE_1_1);

        vm.expectRevert(abi.encodeWithSelector(IRangeFit.OnlyOwner.selector, trader));
        hook.transferOwnership(trader);

        vm.stopPrank();

        // Owner calls succeed and emit events
        hook.setCooldown(120);
        assertEq(hook.cooldown(), 120);

        hook.setMaxDeviationBps(500);
        assertEq(hook.maxDeviationBps(), 500);

        hook.setWidthBounds(60, 1200);
        assertEq(hook.minWidthTicks(), 60);
        assertEq(hook.maxWidthTicks(), 1200);

        hook.setEmaAlpha(500);
        assertEq(hook.emaAlphaBps(), 500);

        // Transfer ownership
        hook.transferOwnership(bob);
        assertEq(hook.owner(), bob);

        // Previous owner can no longer call
        vm.expectRevert(abi.encodeWithSelector(IRangeFit.OnlyOwner.selector, address(this)));
        hook.setCooldown(300);

        // New owner bob can call
        vm.prank(bob);
        hook.setCooldown(300);
        assertEq(hook.cooldown(), 300);
    }
}
