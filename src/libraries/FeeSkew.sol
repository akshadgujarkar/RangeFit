// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {RangeMath} from "./RangeMath.sol";

/// @title FeeSkew
/// @notice Computes dynamic directional fee adjustments based on vault inventory skew.
/// @dev Implements the directional fee mechanism described in Section 9 of the RangeFit specification.
///      When the vault is overweight a token, swaps that add more of that token are charged a higher
///      fee, and swaps that remove that token are charged a lower fee.
library FeeSkew {
    /// @notice Computes inventory skew in basis points relative to a target ratio.
    /// @dev Skew = (value0 / totalValue) - targetRatio
    ///      A positive skew indicates overweight token0; negative indicates overweight token1.
    /// @param inv0 Total vault inventory of token0 (idle + active).
    /// @param inv1 Total vault inventory of token1 (idle + active).
    /// @param sqrtPriceX96 Price used for inventory valuation (typically smoothed EMA in Q96).
    /// @param targetRatioBps Target token0 share of portfolio in basis points (e.g. 5000 = 50%).
    /// @return skewBps Signed skew in basis points (e.g. +2000 = 20% overweight token0).
    function computeSkewBps(
        uint256 inv0,
        uint256 inv1,
        uint160 sqrtPriceX96,
        uint16 targetRatioBps
    ) internal pure returns (int256 skewBps) {
        if (sqrtPriceX96 == 0) return 0;
        uint256 val0 = RangeMath.valueInToken1(inv0, sqrtPriceX96);
        uint256 totalVal = val0 + inv1;
        if (totalVal == 0) return 0;

        uint256 ratio0Bps = FullMath.mulDiv(val0, 10_000, totalVal);
        skewBps = int256(ratio0Bps) - int256(uint256(targetRatioBps));
    }

    /// @notice Computes the dynamically adjusted swap fee for a specific swap direction.
    /// @param skewBps Inventory skew in basis points (+ = overweight token0, - = overweight token1).
    /// @param zeroForOne True if swap is token0 -> token1 (adds token0 to pool), false if token1 -> token0.
    /// @param baseFee Baseline pool fee in hundredths of a bip (pips, e.g. 3000 = 0.30%).
    /// @param sensitivity Fee adjustment sensitivity coefficient in pips per 100% skew.
    /// @param minFee Minimum permitted fee in pips.
    /// @param maxFee Maximum permitted fee in pips.
    /// @return fee Clamped dynamic swap fee in hundredths of a bip.
    function computeDirectionalFee(
        int256 skewBps,
        bool zeroForOne,
        uint24 baseFee,
        uint24 sensitivity,
        uint24 minFee,
        uint24 maxFee
    ) internal pure returns (uint24 fee) {
        if (skewBps == 0 || sensitivity == 0) {
            fee = baseFee;
        } else {
            uint256 absSkew = skewBps > 0 ? uint256(skewBps) : uint256(-skewBps);
            uint256 adjustment = FullMath.mulDiv(absSkew, uint256(sensitivity), 10_000);

            // Direction mapping:
            // zeroForOne == true: adds token0 to the pool.
            // If skewBps > 0 (overweight token0): adding token0 worsens skew -> higher fee.
            // If skewBps < 0 (underweight token0): adding token0 improves balance -> lower fee.
            // zeroForOne == false: removes token0 from the pool.
            // If skewBps > 0 (overweight token0): removing token0 improves balance -> lower fee.
            // If skewBps < 0 (underweight token0): removing token0 worsens skew -> higher fee.
            bool increaseFee = (zeroForOne && skewBps > 0) || (!zeroForOne && skewBps < 0);

            if (increaseFee) {
                uint256 uncapped = uint256(baseFee) + adjustment;
                fee = uncapped > type(uint24).max ? type(uint24).max : uint24(uncapped);
            } else {
                if (adjustment >= uint256(baseFee)) {
                    fee = 0;
                } else {
                    fee = uint24(uint256(baseFee) - adjustment);
                }
            }
        }

        // Clamp to [minFee, maxFee]
        if (fee < minFee) fee = minFee;
        if (fee > maxFee) fee = maxFee;
    }
}
