import {
  searchNeighborTicks,
  type CandidateRange,
} from "../math/rangeMath.js";
import { floorTick, getTickAtSqrtPrice } from "../math/tickMath.js";

export interface SolverParams {
  spotPriceX96: bigint;
  inv0: bigint;
  inv1: bigint;
  tickSpacing: number;
  targetWidthTicks: number;
  minWidthTicks: number;
  maxWidthTicks: number;
  maxDustBps: bigint;
  slippageTolerancePercent?: number; // default 0.05 = 5%
}

export interface SolvedRebalanceParams {
  newTickLower: number;
  newTickUpper: number;
  minLiquidity: bigint;
  maxDustBps: bigint;
  expectedLiquidity: bigint;
  dust0: bigint;
  dust1: bigint;
  dustBps: bigint;
}

/**
 * Finds the optimal tick boundaries that minimize residual dust for the current inventory.
 */
export function solveOptimalRange(params: SolverParams): SolvedRebalanceParams | null {
  const currentTick = getTickAtSqrtPrice(params.spotPriceX96);
  const halfWidth = Math.floor(params.targetWidthTicks / 2);
  const targetLowerTick = floorTick(currentTick - halfWidth, params.tickSpacing);

  // Search candidate ticks around target lower bound respecting width bounds
  const bestCandidate: CandidateRange | null = searchNeighborTicks(
    params.spotPriceX96,
    targetLowerTick,
    params.inv0,
    params.inv1,
    params.tickSpacing,
    4, // search radius: +/- 4 tick spacings
    params.minWidthTicks,
    params.maxWidthTicks
  );

  if (!bestCandidate) {
    return null;
  }

  // Validate range width bounds
  const width = bestCandidate.tickUpper - bestCandidate.tickLower;
  if (params.minWidthTicks > 0 && width < params.minWidthTicks) {
    return null;
  }
  if (params.maxWidthTicks > 0 && width > params.maxWidthTicks) {
    return null;
  }

  // Validate dust tolerance
  if (bestCandidate.dustBps > params.maxDustBps) {
    return null;
  }

  // Calculate minLiquidity slippage threshold (e.g. 95% of expected liquidity)
  const slippageFactor = 100n - BigInt(Math.floor((params.slippageTolerancePercent ?? 0.05) * 100));
  const minLiquidity = (bestCandidate.liquidity * slippageFactor) / 100n;

  return {
    newTickLower: bestCandidate.tickLower,
    newTickUpper: bestCandidate.tickUpper,
    minLiquidity,
    maxDustBps: params.maxDustBps,
    expectedLiquidity: bestCandidate.liquidity,
    dust0: bestCandidate.dust0,
    dust1: bestCandidate.dust1,
    dustBps: bestCandidate.dustBps,
  };
}
