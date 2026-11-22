// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {RangeFitHook} from "../src/RangeFitHook.sol";
import {IRangeFit} from "../src/interfaces/IRangeFit.sol";
import {RangeMath} from "../src/libraries/RangeMath.sol";

contract RangeFitVaultTest is BaseTest {
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

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
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

        // Initialize pool at 1:1 price
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Configure pool key on hook
        hook.setPoolKey(poolKey);

        // Fund accounts
        _fundAndApprove(alice, 1000 ether, 1000 ether);
        _fundAndApprove(bob, 1000 ether, 1000 ether);
        _fundAndApprove(charlie, 1000 ether, 1000 ether);
        _fundAndApprove(attacker, 1000 ether, 1000 ether);
    }

    function _fundAndApprove(address user, uint256 amt0, uint256 amt1) internal {
        token0.mint(user, amt0);
        token1.mint(user, amt1);
        vm.startPrank(user);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    // =========================================================================
    // 1. First Depositor & Dead Shares Tests
    // =========================================================================

    /// @notice Validates first deposit mints dead shares permanently to address(0).
    function test_Deposit_FirstDepositor_MintsDeadShares() public {
        vm.prank(alice);
        uint256 sharesMinted = hook.deposit(10 ether, 10 ether, 0);

        // At 1:1 spot price, deposit value = 10 + 10 = 20 ether
        uint256 expectedTotalShares = 20 ether;
        assertEq(hook.totalShares(), expectedTotalShares, "Total shares mismatch");
        assertEq(hook.shares(address(0)), hook.DEAD_SHARES(), "Dead shares must be locked at address(0)");
        assertEq(sharesMinted, expectedTotalShares - hook.DEAD_SHARES(), "User should receive total - dead shares");
        assertEq(hook.shares(alice), sharesMinted, "Alice shares mismatch");

        assertEq(hook.idle0(), 10 ether, "idle0 mismatch");
        assertEq(hook.idle1(), 10 ether, "idle1 mismatch");
    }

    /// @notice Validates rejection if initial deposit is too small to cover dead shares.
    function test_Revert_InitialDepositTooSmall() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IRangeFit.InitialDepositTooSmall.selector, 1000, hook.DEAD_SHARES() + 1)
        );
        hook.deposit(500, 500, 0); // 500 + 500 = 1000 <= DEAD_SHARES
    }

    // =========================================================================
    // 2. Deposit Any Ratio (Single-Sided & Asymmetric)
    // =========================================================================

    /// @notice Validates deposit in any ratio: single-sided token0.
    function test_Deposit_AnyRatio_SingleSidedToken0() public {
        // Alice initial deposit
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        // Bob deposits only token0 (single-sided)
        vm.prank(bob);
        uint256 bobShares = hook.deposit(5 ether, 0, 0);

        assertTrue(bobShares > 0, "Bob should receive shares for token0 deposit");
        assertEq(hook.idle0(), 15 ether, "idle0 should now be 15 ether");
        assertEq(hook.idle1(), 10 ether, "idle1 should remain 10 ether");
    }

    /// @notice Validates deposit in any ratio: single-sided token1.
    function test_Deposit_AnyRatio_SingleSidedToken1() public {
        // Alice initial deposit
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        // Bob deposits only token1 (single-sided)
        vm.prank(bob);
        uint256 bobShares = hook.deposit(0, 8 ether, 0);

        assertTrue(bobShares > 0, "Bob should receive shares for token1 deposit");
        assertEq(hook.idle0(), 10 ether, "idle0 should remain 10 ether");
        assertEq(hook.idle1(), 18 ether, "idle1 should now be 18 ether");
    }

    // =========================================================================
    // 3. Pro-Rata Withdrawals
    // =========================================================================

    /// @notice Validates pro-rata withdrawal from idle reserves.
    function test_Withdraw_ProRataIdleReserves() public {
        vm.prank(alice);
        uint256 aliceShares = hook.deposit(10 ether, 10 ether, 0);

        uint256 bal0Before = token0.balanceOf(alice);
        uint256 bal1Before = token1.balanceOf(alice);

        // Alice burns half her shares
        uint256 sharesToBurn = aliceShares / 2;
        vm.prank(alice);
        (uint256 out0, uint256 out1) = hook.withdraw(sharesToBurn, 0, 0);

        // Alice should receive approximately half the idle reserves
        assertApproxEqAbs(out0, 5 ether, 1000, "Withdrawn token0 should be ~5 ether");
        assertApproxEqAbs(out1, 5 ether, 1000, "Withdrawn token1 should be ~5 ether");

        assertEq(token0.balanceOf(alice), bal0Before + out0, "Alice token0 balance update");
        assertEq(token1.balanceOf(alice), bal1Before + out1, "Alice token1 balance update");

        assertEq(hook.shares(alice), aliceShares - sharesToBurn, "Alice remaining shares");
    }

    // =========================================================================
    // 4. Previews & Views
    // =========================================================================

    function test_PreviewDeposit_MatchesActual() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        uint256 preview = hook.previewDeposit(5 ether, 5 ether);
        vm.prank(bob);
        uint256 actual = hook.deposit(5 ether, 5 ether, 0);

        assertEq(preview, actual, "Preview deposit must match actual minted shares");
    }

    function test_PreviewWithdraw_MatchesActual() public {
        vm.prank(alice);
        uint256 sharesMinted = hook.deposit(10 ether, 10 ether, 0);

        (uint256 p0, uint256 p1) = hook.previewWithdraw(sharesMinted / 2);
        vm.prank(alice);
        (uint256 a0, uint256 a1) = hook.withdraw(sharesMinted / 2, 0, 0);

        assertEq(p0, a0, "Preview withdraw token0 mismatch");
        assertEq(p1, a1, "Preview withdraw token1 mismatch");
    }

    // =========================================================================
    // 5. Slippage & Error Checks
    // =========================================================================

    function test_Revert_Deposit_ZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IRangeFit.ZeroAmount.selector);
        hook.deposit(0, 0, 0);
    }

    function test_Revert_Deposit_SlippageMinShares() public {
        vm.prank(alice);
        uint256 expected = hook.previewDeposit(10 ether, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IRangeFit.InsufficientSharesMinted.selector, expected, expected + 1)
        );
        hook.deposit(10 ether, 10 ether, expected + 1);
    }

    function test_Revert_Withdraw_InsufficientBalance() public {
        vm.prank(alice);
        hook.deposit(10 ether, 10 ether, 0);

        vm.prank(bob); // Bob has 0 shares
        vm.expectRevert(abi.encodeWithSelector(IRangeFit.InsufficientSharesBalance.selector, 100, 0));
        hook.withdraw(100, 0, 0);
    }

    function test_Revert_Withdraw_SlippageMinAmounts() public {
        vm.prank(alice);
        uint256 sharesMinted = hook.deposit(10 ether, 10 ether, 0);

        (uint256 p0, ) = hook.previewWithdraw(sharesMinted);
        vm.prank(alice);
        vm.expectRevert();
        hook.withdraw(sharesMinted, p0 + 1 ether, 0);
    }

    // =========================================================================
    // 6. Security: First-Depositor / Share Inflation Attack Resilience
    // =========================================================================

    /// @notice Verifies that an attacker donating assets directly to the vault cannot dilute
    /// subsequent depositors into receiving 0 shares.
    function test_Security_InflationAttack_Fails() public {
        // Attacker deposits minimum allowed value
        vm.prank(attacker);
        uint256 attackerShares = hook.deposit(1000, 1001, 0);
        assertTrue(attackerShares > 0, "Attacker should mint shares");

        // Attacker attempts inflation attack by donating 100 ether directly to hook
        token0.mint(address(hook), 100 ether);
        token1.mint(address(hook), 100 ether);

        // Because dead shares are locked and totalShares is non-zero,
        // a legitimate user depositing normal funds still receives non-zero shares!
        vm.prank(bob);
        uint256 bobShares = hook.deposit(1 ether, 1 ether, 0);

        assertTrue(bobShares > 0, "Bob must receive non-zero shares despite donation");

        // Bob withdraws and recovers fair value
        vm.prank(bob);
        (uint256 out0, uint256 out1) = hook.withdraw(bobShares, 0, 0);
        assertTrue(out0 > 0 && out1 > 0, "Bob recovers tokens");
    }

    // =========================================================================
    // 7. Section 8.6 Invariants
    // =========================================================================

    /// @notice Invariant 1: Vault token balances >= idle0 and >= idle1.
    /// @notice Invariant 2: sum(shares[users]) + deadShares == totalShares.
    /// @notice Invariant 7: No cross-user leakage (withdrawn value <= pro-rata claim).
    function test_Invariants_1_2_7() public {
        // Multi-user deposits with asymmetric ratios
        vm.prank(alice);
        hook.deposit(10 ether, 20 ether, 0);

        vm.prank(bob);
        uint256 sBob = hook.deposit(15 ether, 5 ether, 0);

        vm.prank(charlie);
        hook.deposit(0, 30 ether, 0);

        // Invariant 1: token balance >= idle reserves
        assertGe(token0.balanceOf(address(hook)), hook.idle0(), "Invariant 1: token0 balance >= idle0");
        assertGe(token1.balanceOf(address(hook)), hook.idle1(), "Invariant 1: token1 balance >= idle1");

        // Invariant 2: sum(shares) + deadShares == totalShares
        uint256 sumUserShares = hook.shares(alice) + hook.shares(bob) + hook.shares(charlie);
        assertEq(sumUserShares + hook.DEAD_SHARES(), hook.totalShares(), "Invariant 2: Shares conservation");

        // Invariant 7: No cross-user leakage on withdrawal
        uint256 bobValBefore = hook.userValue(bob);
        vm.prank(bob);
        (uint256 b0, uint256 b1) = hook.withdraw(sBob, 0, 0);
        uint256 withdrawnVal = RangeMath.valueInToken1(b0, Constants.SQRT_PRICE_1_1) + b1;
        assertLe(withdrawnVal, bobValBefore + 1000, "Invariant 7: No cross-user value leakage");

        // Re-check Invariant 2 after withdrawal
        assertEq(
            hook.shares(alice) + hook.shares(bob) + hook.shares(charlie) + hook.DEAD_SHARES(),
            hook.totalShares(),
            "Invariant 2 holds after withdrawal"
        );
    }
}
