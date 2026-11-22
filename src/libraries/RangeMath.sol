// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title RangeMath
/// @notice Pure mathematics library for swapless concentrated liquidity re-ranging.
/// @dev Solves for the unique upper bound and liquidity that absorbs 100% of available inventory
///      (X of token0 and Y of token1) at current spot price s given chosen lower bound u.
library RangeMath {
    // -------------------------------------------------------------------------
    // Custom Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when inventory of either token is zero.
    error ZeroInventory();

    /// @notice Thrown when lower bound is greater than or equal to spot price.
    error LowerBoundGteCurrentPrice(uint160 sqrtPriceLowerX96, uint160 sqrtPriceX96);

    /// @notice Thrown when lower bound is below minimum allowable Uniswap tick price.
    error LowerBoundBelowMin(uint160 sqrtPriceLowerX96, uint160 minSqrtPriceX96);

    /// @notice Thrown when inventory skew renders positive upper bound mathematically impossible (u <= s - Y / (X * s)).
    error UpperBoundNonPositive(uint160 sqrtPriceLowerX96, uint160 minFeasibleLowerBoundX96);

    /// @notice Thrown when solved upper bound exceeds maximum allowable Uniswap tick price.
    error UpperBoundAboveMax(uint160 sqrtPriceUpperX96, uint160 maxSqrtPriceX96);

    /// @notice Thrown when solved liquidity exceeds uint128 capacity.
    error LiquidityOverflow();

    /// @notice Thrown when tick boundaries violate ordering or spacing.
    error InvalidTickOrdering(int24 tickLower, int24 tickUpper);

    // -------------------------------------------------------------------------
    // Data Structures
    // -------------------------------------------------------------------------

    /// @notice Structure containing evaluated range usage, consumed token amounts, and leftover dust.
    struct RangeUsage {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Used;
        uint256 amount1Used;
        uint256 dust0;
        uint256 dust1;
        uint256 dustBps; // Dust value as fraction of total inventory value in basis points (1 bps = 0.01%)
    }

    /// @notice Parameters for searching neighbor ticks to minimize rounding dust.
    struct NeighborSearchParams {
        uint160 sqrtPriceX96;
        int24 baseLower;
        int24 baseUpper;
        int24 tickSpacing;
        uint256 amount0;
        uint256 amount1;
        uint8 numLowerSteps;
        uint8 numUpperSteps;
    }

    // -------------------------------------------------------------------------
    // Analytical Solver
    // -------------------------------------------------------------------------

    /// @notice Solves for the exact upper price bound and liquidity that fully consumes inventory amounts X and Y.
    /// @dev Closed form:
    ///      L = Y * Q96 / (s - u)
    ///      v = L * Q96 * s / (L * Q96 - X * s)
    /// @param sqrtPriceX96 Current pool spot square-root price in Q96 (s)
    /// @param sqrtPriceLowerX96 Chosen lower bound square-root price in Q96 (u)
    /// @param amount0 Available inventory of token0 (X)
    /// @param amount1 Available inventory of token1 (Y)
    /// @return liquidity The solved liquidity L
    /// @return sqrtPriceUpperX96 The solved upper bound square-root price in Q96 (v)
    function solveRange(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity, uint160 sqrtPriceUpperX96) {
        if (amount0 == 0 || amount1 == 0) revert ZeroInventory();
        if (sqrtPriceLowerX96 >= sqrtPriceX96) {
            revert LowerBoundGteCurrentPrice(sqrtPriceLowerX96, sqrtPriceX96);
        }
        if (sqrtPriceLowerX96 < TickMath.MIN_SQRT_PRICE) {
            revert LowerBoundBelowMin(sqrtPriceLowerX96, TickMath.MIN_SQRT_PRICE);
        }

        // L = Y * Q96 / (s - u)
        uint256 deltaLower = uint256(sqrtPriceX96) - uint256(sqrtPriceLowerX96);
        uint256 rawL = FullMath.mulDiv(amount1, FixedPoint96.Q96, deltaLower);
        if (rawL > type(uint128).max) revert LiquidityOverflow();
        liquidity = uint128(rawL);

        // Denominator = L * Q96 - X * s
        // Feasibility requirement: L * Q96 > X * s
        uint256 lQ96 = uint256(liquidity) << 96;

        // Check if X * s would overflow uint256 or exceed lQ96
        if (amount0 > type(uint256).max / sqrtPriceX96) {
            revert UpperBoundNonPositive(sqrtPriceLowerX96, 0);
        }
        uint256 productXs = amount0 * uint256(sqrtPriceX96);

        if (lQ96 <= productXs) {
            revert UpperBoundNonPositive(sqrtPriceLowerX96, 0);
        }

        uint256 denominator = lQ96 - productXs;

        // v = (L * Q96 * s) / denominator
        uint256 rawUpper = FullMath.mulDiv(lQ96, uint256(sqrtPriceX96), denominator);

        if (rawUpper > TickMath.MAX_SQRT_PRICE) {
            revert UpperBoundAboveMax(uint160(rawUpper), TickMath.MAX_SQRT_PRICE);
        }

        sqrtPriceUpperX96 = uint160(rawUpper);
    }

    /// @notice Evaluates whether a chosen lower bound u is feasible for the given inventory and spot price.
    /// @param sqrtPriceX96 Current pool spot square-root price (s)
    /// @param sqrtPriceLowerX96 Proposed lower bound square-root price (u)
    /// @param amount0 Available inventory of token0 (X)
    /// @param amount1 Available inventory of token1 (Y)
    /// @return feasible True if a valid upper bound v > s exists within pool tick limits
    function isFeasible(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (bool feasible) {
        if (amount0 == 0 || amount1 == 0) return false;
        if (sqrtPriceLowerX96 >= sqrtPriceX96 || sqrtPriceLowerX96 < TickMath.MIN_SQRT_PRICE) return false;

        uint256 deltaLower = uint256(sqrtPriceX96) - uint256(sqrtPriceLowerX96);
        uint256 rawL = FullMath.mulDiv(amount1, FixedPoint96.Q96, deltaLower);
        if (rawL > type(uint128).max || rawL == 0) return false;

        uint256 lQ96 = rawL << 96;
        if (amount0 > type(uint256).max / sqrtPriceX96) return false;
        uint256 productXs = amount0 * uint256(sqrtPriceX96);
        if (lQ96 <= productXs) return false;

        uint256 denominator = lQ96 - productXs;
        uint256 rawUpper = FullMath.mulDiv(lQ96, uint256(sqrtPriceX96), denominator);

        return (rawUpper <= TickMath.MAX_SQRT_PRICE && rawUpper > sqrtPriceX96);
    }

    // -------------------------------------------------------------------------
    // Tick Rounding Helpers
    // -------------------------------------------------------------------------

    /// @notice Computes floor(tick / tickSpacing) * tickSpacing, handling negative ticks correctly.
    /// @param tick The tick to round down
    /// @param tickSpacing The pool tick spacing
    /// @return floored The greatest multiple of tickSpacing <= tick
    function floorTick(int24 tick, int24 tickSpacing) internal pure returns (int24 floored) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && (tick % tickSpacing != 0)) {
            compressed--;
        }
        floored = compressed * tickSpacing;
    }

    /// @notice Computes ceil(tick / tickSpacing) * tickSpacing, handling negative ticks correctly.
    /// @param tick The tick to round up
    /// @param tickSpacing The pool tick spacing
    /// @return ceiled The smallest multiple of tickSpacing >= tick
    function ceilTick(int24 tick, int24 tickSpacing) internal pure returns (int24 ceiled) {
        int24 compressed = tick / tickSpacing;
        if (tick > 0 && (tick % tickSpacing != 0)) {
            compressed++;
        }
        ceiled = compressed * tickSpacing;
    }

    /// @notice Computes round(tick / tickSpacing) * tickSpacing (nearest multiple).
    /// @param tick The tick to round
    /// @param tickSpacing The pool tick spacing
    /// @return rounded The nearest multiple of tickSpacing to tick
    function roundTick(int24 tick, int24 tickSpacing) internal pure returns (int24 rounded) {
        int24 lower = floorTick(tick, tickSpacing);
        if (tick - lower >= (tickSpacing + 1) / 2) {
            rounded = lower + tickSpacing;
        } else {
            rounded = lower;
        }
    }

    /// @notice Converts exact solved prices to aligned pool ticks.
    /// @dev Lower tick is floored to preserve or widen the lower boundary. Upper tick is ceiled.
    /// @param sqrtPriceLowerX96 Lower bound square root price
    /// @param sqrtPriceUpperX96 Upper bound square root price
    /// @param tickSpacing Pool tick spacing
    /// @return alignedLower Valid tick <= lower price tick
    /// @return alignedUpper Valid tick >= upper price tick
    function alignTicksToSpacing(
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        int24 tickSpacing
    ) internal pure returns (int24 alignedLower, int24 alignedUpper) {
        int24 rawLower = TickMath.getTickAtSqrtPrice(sqrtPriceLowerX96);
        int24 rawUpper = TickMath.getTickAtSqrtPrice(sqrtPriceUpperX96);

        alignedLower = floorTick(rawLower, tickSpacing);
        alignedUpper = ceilTick(rawUpper, tickSpacing);

        // Clamp to pool boundaries
        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);

        if (alignedLower < minTick) alignedLower = minTick;
        if (alignedUpper > maxTick) alignedUpper = maxTick;

        if (alignedLower >= alignedUpper) revert InvalidTickOrdering(alignedLower, alignedUpper);
    }

    // -------------------------------------------------------------------------
    // Safe Liquidity Calculation (avoids SafeCast panics on extreme inputs)
    // -------------------------------------------------------------------------

    /// @notice Computes max consumable liquidity without reverting on uint128 overflow.
    function getLiquidityForAmountsSafe(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = getLiquidityForAmount0Safe(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 l0 = getLiquidityForAmount0Safe(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 l1 = getLiquidityForAmount1Safe(sqrtPriceAX96, sqrtPriceX96, amount1);
            liquidity = l0 < l1 ? l0 : l1;
        } else {
            liquidity = getLiquidityForAmount1Safe(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }

    function getLiquidityForAmount0Safe(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        unchecked {
            if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
            uint256 delta = sqrtPriceBX96 - sqrtPriceAX96;
            if (delta == 0) return 0;
            uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
            uint256 rawL = FullMath.mulDiv(amount0, intermediate, delta);
            liquidity = rawL > type(uint128).max ? type(uint128).max : uint128(rawL);
        }
    }

    function getLiquidityForAmount1Safe(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        unchecked {
            if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
            uint256 delta = sqrtPriceBX96 - sqrtPriceAX96;
            if (delta == 0) return 0;
            uint256 rawL = FullMath.mulDiv(amount1, FixedPoint96.Q96, delta);
            liquidity = rawL > type(uint128).max ? type(uint128).max : uint128(rawL);
        }
    }

    // -------------------------------------------------------------------------
    // Usage and Dust Computation
    // -------------------------------------------------------------------------

    /// @notice Computes consumable liquidity, actual token amounts used, and leftover dust for a given tick range.
    /// @param sqrtPriceX96 Current pool spot square-root price (s)
    /// @param tickLower Aligned lower tick
    /// @param tickUpper Aligned upper tick
    /// @param amount0 Total available inventory token0
    /// @param amount1 Total available inventory token1
    /// @return usage RangeUsage struct populated with liquidity, consumed amounts, dust, and dust basis points
    function computeRangeUsageAndDust(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (RangeUsage memory usage) {
        if (tickLower >= tickUpper) revert InvalidTickOrdering(tickLower, tickUpper);

        usage.tickLower = tickLower;
        usage.tickUpper = tickUpper;

        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // Compute max liquidity affordable by both balances using safe overflow guards
        usage.liquidity = getLiquidityForAmountsSafe(
            sqrtPriceX96,
            sqrtLowerX96,
            sqrtUpperX96,
            amount0,
            amount1
        );

        // Compute exact amounts consumed by this liquidity (round down to never exceed inventory)
        if (usage.liquidity > 0) {
            usage.amount0Used = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpperX96, usage.liquidity, false);
            usage.amount1Used = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtPriceX96, usage.liquidity, false);
        }

        // Safety clamps: used cannot exceed available
        if (usage.amount0Used > amount0) usage.amount0Used = amount0;
        if (usage.amount1Used > amount1) usage.amount1Used = amount1;

        usage.dust0 = amount0 - usage.amount0Used;
        usage.dust1 = amount1 - usage.amount1Used;

        // Compute dust value in basis points relative to total inventory value in token1 terms
        usage.dustBps = computeDustBps(sqrtPriceX96, amount0, amount1, usage.dust0, usage.dust1);
    }

    /// @notice Searches a grid of candidate neighbor ticks around base aligned ticks to find the range that minimizes dust.
    /// @param params NeighborSearchParams containing price, base ticks, spacing, inventory, and search steps
    /// @return bestUsage RangeUsage struct for candidate yielding lowest dust basis points
    function findBestNeighborTicks(
        NeighborSearchParams memory params
    ) internal pure returns (RangeUsage memory bestUsage) {
        int24 minTick = TickMath.minUsableTick(params.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(params.tickSpacing);

        bool initialized = false;

        for (uint8 i = 0; i <= params.numLowerSteps; i++) {
            int24 candLower = params.baseLower - int24(uint24(i)) * params.tickSpacing;
            if (candLower < minTick) continue;
            if (TickMath.getSqrtPriceAtTick(candLower) >= params.sqrtPriceX96) continue;

            for (uint8 j = 0; j <= params.numUpperSteps; j++) {
                int24 candUpper = params.baseUpper + int24(uint24(j)) * params.tickSpacing;
                if (candUpper > maxTick || candLower >= candUpper) continue;
                if (params.sqrtPriceX96 >= TickMath.getSqrtPriceAtTick(candUpper)) continue;

                RangeUsage memory candidate = computeRangeUsageAndDust(
                    params.sqrtPriceX96, candLower, candUpper, params.amount0, params.amount1
                );

                if (!initialized || candidate.dustBps < bestUsage.dustBps) {
                    bestUsage = candidate;
                    initialized = true;
                    // Early exit if dust is zero
                    if (bestUsage.dustBps == 0) return bestUsage;
                }
            }
        }
    }

    /// @notice Evaluates dust as basis points of total inventory value (denominated in token1 units).
    /// @dev Total value in token1 = amount0 * P + amount1, where P = (sqrtPriceX96 / Q96)^2
    /// @param sqrtPriceX96 Spot square-root price in Q96
    /// @param amount0 Total inventory token0
    /// @param amount1 Total inventory token1
    /// @param dust0 Leftover dust token0
    /// @param dust1 Leftover dust token1
    /// @return dustBps Dust value in basis points (1 = 0.01%, 10000 = 100%)
    function computeDustBps(
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1,
        uint256 dust0,
        uint256 dust1
    ) internal pure returns (uint256 dustBps) {
        // Value of token0 amounts converted to token1 terms: amount0 * s^2 / Q96^2
        uint256 val0Total = valueInToken1(amount0, sqrtPriceX96);
        uint256 totalValue = val0Total + amount1;

        if (totalValue == 0) return 0;

        uint256 val0Dust = valueInToken1(dust0, sqrtPriceX96);
        uint256 totalDustValue = val0Dust + dust1;

        dustBps = FullMath.mulDiv(totalDustValue, 10_000, totalValue);
    }

    /// @notice Computes amounts of token0 and token1 held by a given liquidity amount at current spot price.
    /// @param sqrtPriceX96 Current pool spot price in Q96.
    /// @param sqrtLowerX96 Lower tick price in Q96.
    /// @param sqrtUpperX96 Upper tick price in Q96.
    /// @param liquidity Amount of active liquidity.
    /// @return amount0 Token0 held by liquidity.
    /// @return amount1 Token1 held by liquidity.
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) return (0, 0);
        if (sqrtPriceX96 <= sqrtLowerX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLowerX96, sqrtUpperX96, liquidity, false);
            amount1 = 0;
        } else if (sqrtPriceX96 < sqrtUpperX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpperX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtPriceX96, liquidity, false);
        } else {
            amount0 = 0;
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtUpperX96, liquidity, false);
        }
    }

    /// @notice Helper to value an amount of token0 in terms of token1 using spot sqrtPriceX96.
    /// @dev amount0 * (sqrtPriceX96 / Q96)^2
    /// @param amount0 Amount of token0
    /// @param sqrtPriceX96 Spot square-root price in Q96
    /// @return value1 Equivalent value in token1
    function valueInToken1(uint256 amount0, uint160 sqrtPriceX96) internal pure returns (uint256 value1) {
        if (amount0 == 0 || sqrtPriceX96 == 0) return 0;
        uint256 intermediate = FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96);
        value1 = FullMath.mulDiv(intermediate, sqrtPriceX96, FixedPoint96.Q96);
    }
}
