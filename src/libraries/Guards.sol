// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IRangeFit} from "../interfaces/IRangeFit.sol";

/// @title Guards
/// @notice Security and manipulation defense library for RangeFit.
/// @dev Implements Exponential Moving Average (EMA) smoothing, price deviation checks,
///      and position width validation to protect against flash loans and MEV manipulation.
library Guards {
    /// @notice Updates an Exponential Moving Average (EMA) square-root price with a new observation.
    /// @dev New EMA = ((10000 - alpha) * currentEma + alpha * spotPrice) / 10000
    /// @param currentEmaX96 Current EMA square-root price in Q96.
    /// @param spotPriceX96 Current spot square-root price in Q96 from pool slot0.
    /// @param alphaBps Smoothing factor in basis points (e.g. 1000 = 10%).
    /// @return newEmaX96 Updated EMA square-root price in Q96.
    function updateEMA(
        uint160 currentEmaX96,
        uint160 spotPriceX96,
        uint16 alphaBps
    ) internal pure returns (uint160 newEmaX96) {
        if (currentEmaX96 == 0) return spotPriceX96;
        if (alphaBps >= 10_000) return spotPriceX96;
        if (alphaBps == 0) return currentEmaX96;

        uint256 weightOld = 10_000 - uint256(alphaBps);
        uint256 termOld = FullMath.mulDiv(uint256(currentEmaX96), weightOld, 10_000);
        uint256 termNew = FullMath.mulDiv(uint256(spotPriceX96), uint256(alphaBps), 10_000);

        uint256 sum = termOld + termNew;
        if (sum > type(uint160).max) {
            newEmaX96 = type(uint160).max;
        } else {
            newEmaX96 = uint160(sum);
        }
    }

    /// @notice Computes relative price deviation between spot price and EMA in basis points.
    /// @dev Deviation BPS = |spot - ema| * 10000 / ema
    /// @param spotPriceX96 Instantaneous spot square-root price in Q96.
    /// @param emaPriceX96 Smoothed EMA square-root price in Q96.
    /// @return deviationBps Deviation in basis points (1 = 0.01%, 100 = 1%).
    function computeDeviationBps(
        uint160 spotPriceX96,
        uint160 emaPriceX96
    ) internal pure returns (uint256 deviationBps) {
        if (emaPriceX96 == 0) return 0;
        uint256 diff = spotPriceX96 > emaPriceX96
            ? uint256(spotPriceX96 - emaPriceX96)
            : uint256(emaPriceX96 - spotPriceX96);

        deviationBps = FullMath.mulDiv(diff, 10_000, uint256(emaPriceX96));
    }

    /// @notice Verifies that spot price does not deviate excessively from the smoothed EMA price.
    /// @param spotPriceX96 Instantaneous spot price in Q96.
    /// @param emaPriceX96 Smoothed EMA price in Q96.
    /// @param maxDeviationBps Maximum permitted deviation in basis points.
    function checkDeviation(
        uint160 spotPriceX96,
        uint160 emaPriceX96,
        uint256 maxDeviationBps
    ) internal pure {
        if (maxDeviationBps == 0 || emaPriceX96 == 0) return;
        uint256 deviationBps = computeDeviationBps(spotPriceX96, emaPriceX96);
        if (deviationBps > maxDeviationBps) {
            revert IRangeFit.PriceDeviationTooHigh(
                spotPriceX96,
                emaPriceX96,
                deviationBps,
                maxDeviationBps
            );
        }
    }

    /// @notice Verifies that a proposed range width conforms to min/max safety boundaries.
    /// @param tickLower Proposed lower tick bound.
    /// @param tickUpper Proposed upper tick bound.
    /// @param minWidthTicks Minimum permissible width in ticks (0 to disable).
    /// @param maxWidthTicks Maximum permissible width in ticks (0 to disable).
    function checkWidth(
        int24 tickLower,
        int24 tickUpper,
        int24 minWidthTicks,
        int24 maxWidthTicks
    ) internal pure {
        int24 width = tickUpper - tickLower;
        if (width <= 0) revert IRangeFit.InvalidTickRange(tickLower, tickUpper);

        if (minWidthTicks > 0 && width < minWidthTicks) {
            revert IRangeFit.RangeTooNarrow(width, minWidthTicks);
        }
        if (maxWidthTicks > 0 && width > maxWidthTicks) {
            revert IRangeFit.RangeTooWide(width, maxWidthTicks);
        }
    }
}
