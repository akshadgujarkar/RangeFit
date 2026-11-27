import {
  Q96,
  MIN_SQRT_PRICE,
  MAX_SQRT_PRICE,
  floorTick,
  ceilTick,
  roundTick,
  getSqrtPriceAtTick,
  getTickAtSqrtPrice,
} from "./tickMath.js";

export const UINT128_MAX = 2n ** 128n - 1n;
export const UINT256_MAX = 2n ** 256n - 1n;

export interface RangeUsage {
  liquidity: bigint;
  amount0Used: bigint;
  amount1Used: bigint;
  dust0: bigint;
  dust1: bigint;
  dustBps: bigint;
}

export interface CandidateRange {
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
  dust0: bigint;
  dust1: bigint;
  dustBps: bigint;
}

/**
 * Computes floor(a * b / denominator) matching Solidity FullMath.mulDiv.
 */
export function mulDiv(a: bigint, b: bigint, denominator: bigint): bigint {
  if (denominator === 0n) {
    throw new Error("ZeroDivisionError: mulDiv denominator is zero");
  }
  return (a * b) / denominator;
}

/**
 * Solves for (liquidity, sqrtPriceUpperX96).
 * Closed-form analytical formula: v = (s * X) / (X - Y / (s - u)).
 */
export function solveRange(
  spotPriceX96: bigint,
  sqrtLowerX96: bigint,
  amount0: bigint,
  amount1: bigint
): { liquidity: bigint; sqrtUpperX96: bigint } {
  if (amount0 <= 0n || amount1 <= 0n) {
    throw new Error("ZeroInventory: amount0 and amount1 must be positive");
  }
  if (sqrtLowerX96 >= spotPriceX96) {
    throw new Error("LowerBoundGteCurrentPrice: lower bound must be below spot price");
  }
  if (sqrtLowerX96 < MIN_SQRT_PRICE) {
    throw new Error("LowerBoundBelowMin: lower bound below MIN_SQRT_PRICE");
  }

  const deltaLower = spotPriceX96 - sqrtLowerX96;
  const lVal = mulDiv(amount1, Q96, deltaLower);

  if (lVal > UINT128_MAX) {
    throw new Error("LiquidityOverflow: liquidity exceeds uint128");
  }

  const lQ96 = lVal << 96n;
  const productXS = amount0 * spotPriceX96;

  if (productXS > UINT256_MAX) {
    throw new Error("ProductXSOverflow: amount0 * spotPrice exceeds uint256");
  }

  if (lQ96 <= productXS) {
    throw new Error("UpperBoundNonPositive: denominator is non-positive, inventory infeasible");
  }

  const denominator = lQ96 - productXS;
  const rawUpper = mulDiv(lQ96, spotPriceX96, denominator);

  if (rawUpper > MAX_SQRT_PRICE) {
    throw new Error("UpperBoundAboveMax: upper bound exceeds MAX_SQRT_PRICE");
  }

  return { liquidity: lVal, sqrtUpperX96: rawUpper };
}

/**
 * Checks if a valid swapless range can be solved without throwing.
 */
export function isFeasible(
  spotPriceX96: bigint,
  sqrtLowerX96: bigint,
  amount0: bigint,
  amount1: bigint
): boolean {
  try {
    solveRange(spotPriceX96, sqrtLowerX96, amount0, amount1);
    return true;
  } catch {
    return false;
  }
}

export function getLiquidityForAmount0(
  sqrtRatioAX96: bigint,
  sqrtRatioBX96: bigint,
  amount0: bigint
): bigint {
  let [lower, upper] = sqrtRatioAX96 > sqrtRatioBX96 ? [sqrtRatioBX96, sqrtRatioAX96] : [sqrtRatioAX96, sqrtRatioBX96];
  const intermediate = mulDiv(lower, upper, Q96);
  return mulDiv(amount0, intermediate, upper - lower);
}

export function getLiquidityForAmount1(
  sqrtRatioAX96: bigint,
  sqrtRatioBX96: bigint,
  amount1: bigint
): bigint {
  let [lower, upper] = sqrtRatioAX96 > sqrtRatioBX96 ? [sqrtRatioBX96, sqrtRatioAX96] : [sqrtRatioAX96, sqrtRatioBX96];
  return mulDiv(amount1, Q96, upper - lower);
}

export function getLiquidityForAmounts(
  spotPriceX96: bigint,
  sqrtLowerX96: bigint,
  sqrtUpperX96: bigint,
  amount0: bigint,
  amount1: bigint
): bigint {
  let [lower, upper] = sqrtLowerX96 > sqrtUpperX96 ? [sqrtUpperX96, sqrtLowerX96] : [sqrtLowerX96, sqrtUpperX96];

  if (spotPriceX96 <= lower) {
    return getLiquidityForAmount0(lower, upper, amount0);
  } else if (spotPriceX96 < upper) {
    const l0 = getLiquidityForAmount0(spotPriceX96, upper, amount0);
    const l1 = getLiquidityForAmount1(lower, spotPriceX96, amount1);
    return l0 < l1 ? l0 : l1;
  } else {
    return getLiquidityForAmount1(lower, upper, amount1);
  }
}

export function getAmount0Delta(
  sqrtRatioAX96: bigint,
  sqrtRatioBX96: bigint,
  liquidity: bigint
): bigint {
  let [lower, upper] = sqrtRatioAX96 > sqrtRatioBX96 ? [sqrtRatioBX96, sqrtRatioAX96] : [sqrtRatioAX96, sqrtRatioBX96];
  const numerator1 = liquidity << 96n;
  const numerator2 = upper - lower;
  return mulDiv(mulDiv(numerator1, numerator2, upper), 1n, lower);
}

export function getAmount1Delta(
  sqrtRatioAX96: bigint,
  sqrtRatioBX96: bigint,
  liquidity: bigint
): bigint {
  let [lower, upper] = sqrtRatioAX96 > sqrtRatioBX96 ? [sqrtRatioBX96, sqrtRatioAX96] : [sqrtRatioAX96, sqrtRatioBX96];
  return mulDiv(liquidity, upper - lower, Q96);
}

export function valueInToken1(amount0: bigint, sqrtPriceX96: bigint): bigint {
  if (amount0 === 0n || sqrtPriceX96 === 0n) return 0n;
  const inter = mulDiv(amount0, sqrtPriceX96, Q96);
  return mulDiv(inter, sqrtPriceX96, Q96);
}

/**
 * Computes exact liquidity, token consumption, leftover dust, and dust basis points.
 */
export function computeRangeUsageAndDust(
  spotPriceX96: bigint,
  sqrtLowerX96: bigint,
  sqrtUpperX96: bigint,
  amount0: bigint,
  amount1: bigint
): RangeUsage {
  const liquidity = getLiquidityForAmounts(spotPriceX96, sqrtLowerX96, sqrtUpperX96, amount0, amount1);

  let amount0Used = liquidity > 0n ? getAmount0Delta(spotPriceX96, sqrtUpperX96, liquidity) : 0n;
  let amount1Used = liquidity > 0n ? getAmount1Delta(sqrtLowerX96, spotPriceX96, liquidity) : 0n;

  if (amount0Used > amount0) amount0Used = amount0;
  if (amount1Used > amount1) amount1Used = amount1;

  const dust0 = amount0 - amount0Used;
  const dust1 = amount1 - amount1Used;

  const val0Total = valueInToken1(amount0, spotPriceX96);
  const totalVal = val0Total + amount1;

  const val0Dust = valueInToken1(dust0, spotPriceX96);
  const totalDustVal = val0Dust + dust1;

  const dustBps = totalVal > 0n ? mulDiv(totalDustVal, 10000n, totalVal) : 0n;

  return {
    liquidity,
    amount0Used,
    amount1Used,
    dust0,
    dust1,
    dustBps,
  };
}

/**
 * Searches neighboring tick combinations around a target lower bound to minimize dust.
 */
export function searchNeighborTicks(
  spotPriceX96: bigint,
  targetLowerTick: number,
  amount0: bigint,
  amount1: bigint,
  tickSpacing: number,
  radius: number = 2,
  minWidthTicks?: number,
  maxWidthTicks?: number
): CandidateRange | null {
  const currentTick = getTickAtSqrtPrice(spotPriceX96);
  let bestCandidate: CandidateRange | null = null;

  // Search lower ticks around target lower bound (stepping by tickSpacing)
  for (let dLower = -radius; dLower <= radius; dLower++) {
    const candidateLower = targetLowerTick + dLower * tickSpacing;
    if (candidateLower >= currentTick) continue;

    const sqrtLower = getSqrtPriceAtTick(candidateLower);
    if (!isFeasible(spotPriceX96, sqrtLower, amount0, amount1)) continue;

    const { sqrtUpperX96: rawUpper } = solveRange(spotPriceX96, sqrtLower, amount0, amount1);
    const solvedUpperTick = getTickAtSqrtPrice(rawUpper);

    // Try floor, ceil, and round for upper tick
    const candidateUpperOptions = [
      floorTick(solvedUpperTick, tickSpacing),
      ceilTick(solvedUpperTick, tickSpacing),
      roundTick(solvedUpperTick, tickSpacing),
    ];

    for (const candidateUpper of candidateUpperOptions) {
      if (candidateUpper <= currentTick || candidateUpper <= candidateLower) continue;

      const width = candidateUpper - candidateLower;
      if (minWidthTicks && minWidthTicks > 0 && width < minWidthTicks) continue;
      if (maxWidthTicks && maxWidthTicks > 0 && width > maxWidthTicks) continue;

      const sqrtUpper = getSqrtPriceAtTick(candidateUpper);
      const usage = computeRangeUsageAndDust(spotPriceX96, sqrtLower, sqrtUpper, amount0, amount1);

      if (usage.liquidity === 0n) continue;

      if (!bestCandidate || usage.dustBps < bestCandidate.dustBps) {
        bestCandidate = {
          tickLower: candidateLower,
          tickUpper: candidateUpper,
          liquidity: usage.liquidity,
          dust0: usage.dust0,
          dust1: usage.dust1,
          dustBps: usage.dustBps,
        };
      }
    }
  }

  return bestCandidate;
}
