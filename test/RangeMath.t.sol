// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RangeMath} from "../src/libraries/RangeMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Test harness contract exposing RangeMath internal methods as external calls
/// so that Foundry's vm.expectRevert can intercept custom errors at a lower call depth.
contract RangeMathHarness {
    function solveRange(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint256 amount0,
        uint256 amount1
    ) external pure returns (uint128 liquidity, uint160 sqrtPriceUpperX96) {
        return RangeMath.solveRange(sqrtPriceX96, sqrtPriceLowerX96, amount0, amount1);
    }

    function isFeasible(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint256 amount0,
        uint256 amount1
    ) external pure returns (bool) {
        return RangeMath.isFeasible(sqrtPriceX96, sqrtPriceLowerX96, amount0, amount1);
    }

    function computeRangeUsageAndDust(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) external pure returns (RangeMath.RangeUsage memory) {
        return RangeMath.computeRangeUsageAndDust(sqrtPriceX96, tickLower, tickUpper, amount0, amount1);
    }

    function findBestNeighborTicks(
        RangeMath.NeighborSearchParams memory params
    ) external pure returns (RangeMath.RangeUsage memory) {
        return RangeMath.findBestNeighborTicks(params);
    }
}

contract RangeMathTest is Test {
    uint256 constant Q96 = FixedPoint96.Q96;
    RangeMathHarness harness;

    function setUp() public {
        harness = new RangeMathHarness();
    }

    // =========================================================================
    // 1. Exact Vector Tests (Section 5 of docs/PROJECT.md)
    // =========================================================================

    /// @notice Test Example A from docs/PROJECT.md Section 5.1:
    /// P = 1 => s = Q96
    /// X = 4, Y = 6, u = 0.5 * Q96
    /// Expected: L = 12, v = 1.5 * Q96 (P_upper = 2.25)
    function test_ExampleA_ToyNormalized() public view {
        uint160 s = uint160(Q96);
        uint160 u = uint160(Q96 / 2); // 0.5
        uint256 x = 4;
        uint256 y = 6;

        (uint128 liquidity, uint160 v) = harness.solveRange(s, u, x, y);

        // Expected L = 12
        assertEq(liquidity, 12, "Example A: Liquidity should be 12");

        // Expected v = 1.5 * Q96
        uint256 expectedV = (3 * Q96) / 2;
        assertEq(v, expectedV, "Example A: v should be 1.5 * Q96");

        // Check feasibility view
        assertTrue(harness.isFeasible(s, u, x, y), "Example A should be feasible");
    }

    /// @notice Test Example B from docs/PROJECT.md Section 5.2 (Normalized units):
    /// ETH = $2,400 => s = sqrt(2400) = 48.98979485566356
    /// u = 40 (P_lower = 1600)
    /// X = 1.5 ETH, Y = 6400 USDC (in 18-decimal base)
    /// Expected: L = 711.9184 * 10^18, v = 54.6286 * Q96 (P_upper ~= 2984.28)
    function test_ExampleB_BobNormalized() public view {
        // Exact sqrt(2400) * Q96
        uint160 s = 3881371428364983746953216000000;
        // 40 * Q96
        uint160 u = 3169126500570573762985984000000;

        uint256 x = 1.5 ether; // 1.5 * 10^18
        uint256 y = 6400 ether; // 6400 * 10^18

        (uint128 liquidity, uint160 v) = harness.solveRange(s, u, x, y);

        // Expected L = 6400 / (48.98979486 - 40) ~= 711.918358 * 10^18
        uint256 expectedL = 711918358845308557839; // 711.918358 * 10^18
        assertApproxEqRel(liquidity, expectedL, 1e15, "Example B: Liquidity mismatch");

        // Expected v ~= 54.628595 * Q96
        uint256 expectedV = 4328123221056881793477995421827; // 54.628595 * Q96
        assertApproxEqRel(v, expectedV, 1e15, "Example B: Upper price v mismatch");

        // Upper price P_upper = v^2 / Q96^2
        uint256 pUpper = FullMath.mulDiv(v, v, Q96);
        pUpper = FullMath.mulDiv(pUpper, 1 ether, Q96);
        assertApproxEqRel(pUpper, 2984.28 ether, 1e15, "Example B: P_upper should be ~2984.28");
    }

    /// @notice Test Example B with Real Decimals (WETH 18 decimals, USDC 6 decimals):
    /// In Uniswap pools, token0 = WETH (18 dec), token1 = USDC (6 dec).
    /// Raw spot price P_raw = 2400 * 10^6 / 10^18 = 2400 * 10^-12.
    /// s_raw = sqrt(2400 * 10^-12) * Q96
    /// u_raw = sqrt(1600 * 10^-12) * Q96 = 40 * 10^-6 * Q96
    /// X = 1.5 * 10^18 (1.5 WETH)
    /// Y = 6400 * 10^6 (6400 USDC)
    function test_ExampleB_RealDecimals_WETH_USDC() public view {
        // Exact sqrt(2400 * 10^-12) * Q96
        uint160 s = 3881371428364983746953216;
        // Exact sqrt(1600 * 10^-12) * Q96
        uint160 u = 3169126500570573762985984;

        uint256 x = 1.5 ether; // 1.5 * 10^18
        uint256 y = 6400 * 1e6; // 6400 USDC (6 decimals)

        (uint128 liquidity, uint160 v) = harness.solveRange(s, u, x, y);

        // L_raw = 711918358845308
        uint256 expectedL = 711918358845308;
        assertApproxEqRel(liquidity, expectedL, 1e15, "RealDecimals: Liquidity L mismatch");

        // v_raw should be 4328123221056882313202968
        uint256 expectedV = 4328123221056882313202968;
        assertApproxEqRel(v, expectedV, 1e15, "RealDecimals: Upper price v mismatch");

        // Convert v to tick spacing 60 and calculate base dust
        int24 tickSpacing = 60;
        (int24 alignedLower, int24 alignedUpper) = RangeMath.alignTicksToSpacing(u, v, tickSpacing);

        // Verify ticks are multiples of 60
        assertEq(alignedLower % tickSpacing, 0, "Aligned lower tick must be multiple of 60");
        assertEq(alignedUpper % tickSpacing, 0, "Aligned upper tick must be multiple of 60");

        RangeMath.RangeUsage memory baseUsage = harness.computeRangeUsageAndDust(
            s, alignedLower, alignedUpper, x, y
        );

        // Consumed amounts cannot exceed inventory
        assertLe(baseUsage.amount0Used, x, "amount0Used must be <= x");
        assertLe(baseUsage.amount1Used, y, "amount1Used must be <= y");

        // Base rounded candidate dust is ~1.08% (108 bps), within Section 5.4 95th pct (1.53%)
        assertLt(baseUsage.dustBps, 150, "Base dust bps for spacing 60 should be < 1.50% (150 bps)");

        // Search neighbor candidates (Section 4.6 / 5.3) to minimize dust
        RangeMath.NeighborSearchParams memory params = RangeMath.NeighborSearchParams({
            sqrtPriceX96: s,
            baseLower: alignedLower,
            baseUpper: alignedUpper,
            tickSpacing: tickSpacing,
            amount0: x,
            amount1: y,
            numLowerSteps: 2,
            numUpperSteps: 6
        });
        RangeMath.RangeUsage memory bestUsage = harness.findBestNeighborTicks(params);

        // Best candidate achieves ~0.25% dust (25 bps)
        assertLe(bestUsage.dustBps, 30, "Optimized dust bps should be <= 0.30% (30 bps)");
        assertLe(bestUsage.amount0Used, x, "amount0Used must be <= x");
        assertLe(bestUsage.amount1Used, y, "amount1Used must be <= y");
    }

    // =========================================================================
    // 2. Revert & Feasibility Boundary Tests
    // =========================================================================

    function test_Revert_ZeroInventory_Amount0() public {
        uint160 s = uint160(Q96);
        uint160 u = uint160(Q96 / 2);
        vm.expectRevert(RangeMath.ZeroInventory.selector);
        harness.solveRange(s, u, 0, 100);
    }

    function test_Revert_ZeroInventory_Amount1() public {
        uint160 s = uint160(Q96);
        uint160 u = uint160(Q96 / 2);
        vm.expectRevert(RangeMath.ZeroInventory.selector);
        harness.solveRange(s, u, 100, 0);
    }

    function test_Revert_LowerBoundGteCurrentPrice() public {
        uint160 s = uint160(Q96);
        uint160 u = uint160(Q96); // u == s
        vm.expectRevert(abi.encodeWithSelector(RangeMath.LowerBoundGteCurrentPrice.selector, u, s));
        harness.solveRange(s, u, 100, 100);

        uint160 uGreater = uint160(Q96 + 1); // u > s
        vm.expectRevert(abi.encodeWithSelector(RangeMath.LowerBoundGteCurrentPrice.selector, uGreater, s));
        harness.solveRange(s, uGreater, 100, 100);
    }

    function test_Revert_LowerBoundBelowMin() public {
        uint160 s = uint160(Q96);
        uint160 u = TickMath.MIN_SQRT_PRICE - 1;
        vm.expectRevert(abi.encodeWithSelector(RangeMath.LowerBoundBelowMin.selector, u, TickMath.MIN_SQRT_PRICE));
        harness.solveRange(s, u, 100, 100);
    }

    /// @notice When u <= s - Y / (X * s), the denominator L * Q96 - X * s <= 0,
    /// so a positive upper bound does not exist.
    function test_Revert_UpperBoundNonPositive() public {
        uint160 s = uint160(Q96);
        // Let X = 10, Y = 1.
        // Y / (X * s) in raw terms is 1 / 10 = 0.1.
        // If s = 1.0, u must be > 1.0 - 0.1 = 0.9.
        // If we choose u = 0.8 (< 0.9), it must revert with UpperBoundNonPositive!
        uint160 uInfeasible = uint160((8 * Q96) / 10); // 0.8
        uint256 x = 10;
        uint256 y = 1;

        assertFalse(harness.isFeasible(s, uInfeasible, x, y), "u = 0.8 should be infeasible for X=10, Y=1");

        vm.expectRevert(abi.encodeWithSelector(RangeMath.UpperBoundNonPositive.selector, uInfeasible, 0));
        harness.solveRange(s, uInfeasible, x, y);

        // On the other hand, u = 0.95 (> 0.9) must succeed!
        uint160 uFeasible = uint160((95 * Q96) / 100); // 0.95
        assertTrue(harness.isFeasible(s, uFeasible, x, y), "u = 0.95 should be feasible");
        (uint128 L, uint160 v) = harness.solveRange(s, uFeasible, x, y);
        assertTrue(v > s, "v must be strictly greater than s");
        assertTrue(L > 0, "L must be positive");
    }

    // =========================================================================
    // 3. Tick Rounding Tests
    // =========================================================================

    function test_FloorTick() public pure {
        int24 spacing = 60;

        assertEq(RangeMath.floorTick(120, spacing), 120);
        assertEq(RangeMath.floorTick(125, spacing), 120);
        assertEq(RangeMath.floorTick(179, spacing), 120);
        assertEq(RangeMath.floorTick(0, spacing), 0);
        assertEq(RangeMath.floorTick(-1, spacing), -60);
        assertEq(RangeMath.floorTick(-59, spacing), -60);
        assertEq(RangeMath.floorTick(-60, spacing), -60);
        assertEq(RangeMath.floorTick(-61, spacing), -120);
    }

    function test_CeilTick() public pure {
        int24 spacing = 60;

        assertEq(RangeMath.ceilTick(120, spacing), 120);
        assertEq(RangeMath.ceilTick(121, spacing), 180);
        assertEq(RangeMath.ceilTick(0, spacing), 0);
        assertEq(RangeMath.ceilTick(-1, spacing), 0);
        assertEq(RangeMath.ceilTick(-59, spacing), 0);
        assertEq(RangeMath.ceilTick(-60, spacing), -60);
        assertEq(RangeMath.ceilTick(-61, spacing), -60);
    }

    function test_RoundTick() public pure {
        int24 spacing = 60;

        assertEq(RangeMath.roundTick(120, spacing), 120);
        assertEq(RangeMath.roundTick(149, spacing), 120);
        assertEq(RangeMath.roundTick(150, spacing), 180);
        assertEq(RangeMath.roundTick(179, spacing), 180);
        assertEq(RangeMath.roundTick(180, spacing), 180);
    }

    // =========================================================================
    // 4. Usage, Dust & Invariant Fuzz Tests
    // =========================================================================

    /// @notice Invariant: For any valid range usage, amountUsed <= amountAvailable
    /// and dust = amountAvailable - amountUsed.
    function testFuzz_RangeUsage_DustInvariant(
        uint160 s,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) public view {
        // Constrain price within normal pool boundaries
        vm.assume(s >= TickMath.MIN_SQRT_PRICE * 2 && s <= TickMath.MAX_SQRT_PRICE / 2);
        vm.assume(tickLower >= TickMath.MIN_TICK && tickUpper <= TickMath.MAX_TICK);
        vm.assume(tickLower < tickUpper);

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        vm.assume(sqrtLower < s && s < sqrtUpper);

        // Bound inventory to realistic levels
        amount0 = bound(amount0, 1e6, 1e24);
        amount1 = bound(amount1, 1e6, 1e24);

        RangeMath.RangeUsage memory usage = harness.computeRangeUsageAndDust(
            s, tickLower, tickUpper, amount0, amount1
        );

        assertLe(usage.amount0Used, amount0, "Invariant violation: amount0Used > amount0");
        assertLe(usage.amount1Used, amount1, "Invariant violation: amount1Used > amount1");
        assertEq(usage.dust0, amount0 - usage.amount0Used, "Invariant violation: dust0 calculation");
        assertEq(usage.dust1, amount1 - usage.amount1Used, "Invariant violation: dust1 calculation");
        assertLe(usage.dustBps, 10_000, "Dust bps cannot exceed 100%");
    }

    /// @notice Fuzz test for solveRange on valid feasible generated inputs.
    function testFuzz_SolveRange_Feasible(
        uint160 s,
        uint160 uOffset,
        uint256 x,
        uint256 y
    ) public view {
        // Bound s to a realistic price interval
        vm.assume(s >= 1e12 && s <= uint160(Q96 * 1e6));
        // u must be strictly less than s and above MIN_SQRT_PRICE
        uint160 minU = TickMath.MIN_SQRT_PRICE;
        vm.assume(s > minU + 1000);
        uint160 u = minU + uint160(bound(uint256(uOffset), 1, uint256(s - minU - 1)));

        // Bound inventory amounts
        x = bound(x, 1e6, 1e28);
        y = bound(y, 1e6, 1e28);

        if (harness.isFeasible(s, u, x, y)) {
            (uint128 L, uint160 v) = harness.solveRange(s, u, x, y);
            assertTrue(v > s, "v must be > s");
            assertTrue(v <= TickMath.MAX_SQRT_PRICE, "v must be <= MAX_SQRT_PRICE");
            assertTrue(L > 0, "L must be > 0");
        }
    }
}
