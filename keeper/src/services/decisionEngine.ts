import { type Address } from "viem";

export interface PoolVaultState {
  currentTick: number;
  spotPriceX96: bigint;
  emaPriceX96: bigint;
  tickLower: number;
  tickUpper: number;
  activeLiquidity: bigint;
  idle0: bigint;
  idle1: bigint;
  totalInv0: bigint;
  totalInv1: bigint;
  rebalanceDue: boolean;
  cooldown: number;
  lastRebalance: number;
  currentTimestamp: number;
  maxDeviationBps: bigint;
  minWidthTicks: number;
  maxWidthTicks: number;
  keeperOnly: boolean;
  isAuthorizedKeeper: boolean;
}

export interface RebalanceDecision {
  shouldRebalance: boolean;
  reason: string;
  isOutOfRange: boolean;
  isNearEdge: boolean;
  isCooldownActive: boolean;
  isDeviationExcessive: boolean;
  deviationBps: bigint;
}

/**
 * Computes price deviation in basis points between spot and smoothed EMA.
 * deviationBps = |spot - ema| * 10000 / ema
 */
export function computePriceDeviationBps(spotPriceX96: bigint, emaPriceX96: bigint): bigint {
  if (emaPriceX96 === 0n) return 0n;
  const diff = spotPriceX96 > emaPriceX96 ? spotPriceX96 - emaPriceX96 : emaPriceX96 - spotPriceX96;
  return (diff * 10000n) / emaPriceX96;
}

/**
 * Evaluates whether a swapless rebalance should be executed based on Section 10 rules.
 */
export function evaluateRebalance(
  state: PoolVaultState,
  edgeThresholdPercent: number = 0.20
): RebalanceDecision {
  // 1. Guard check: Keeper allowlist
  if (state.keeperOnly && !state.isAuthorizedKeeper) {
    return {
      shouldRebalance: false,
      reason: "Unauthorized keeper: keeperOnly mode is active and caller is not allowlisted",
      isOutOfRange: false,
      isNearEdge: false,
      isCooldownActive: false,
      isDeviationExcessive: false,
      deviationBps: 0n,
    };
  }

  // 2. Guard check: Cooldown
  const cooldownElapsed = state.currentTimestamp >= state.lastRebalance + state.cooldown;
  const isCooldownActive = !cooldownElapsed;
  if (isCooldownActive) {
    const remaining = state.lastRebalance + state.cooldown - state.currentTimestamp;
    return {
      shouldRebalance: false,
      reason: `Cooldown active: ${remaining}s remaining before next rebalance permitted`,
      isOutOfRange: false,
      isNearEdge: false,
      isCooldownActive: true,
      isDeviationExcessive: false,
      deviationBps: 0n,
    };
  }

  // 3. Guard check: Price deviation against smoothed EMA
  const deviationBps = computePriceDeviationBps(state.spotPriceX96, state.emaPriceX96);
  const isDeviationExcessive = state.maxDeviationBps > 0n && deviationBps > state.maxDeviationBps;
  if (isDeviationExcessive) {
    return {
      shouldRebalance: false,
      reason: `Price deviation too high: spot deviates ${deviationBps} bps > max ${state.maxDeviationBps} bps`,
      isOutOfRange: false,
      isNearEdge: false,
      isCooldownActive: false,
      isDeviationExcessive: true,
      deviationBps,
    };
  }

  // 4. Initial deployment check: liquidity is 0 but idle funds exist
  if (state.activeLiquidity === 0n && (state.idle0 > 0n || state.idle1 > 0n)) {
    return {
      shouldRebalance: true,
      reason: "Initial deployment: position has 0 active liquidity and pending idle deposits",
      isOutOfRange: true,
      isNearEdge: false,
      isCooldownActive: false,
      isDeviationExcessive: false,
      deviationBps,
    };
  }

  // 5. Position boundary check
  const isOutOfRange =
    state.currentTick < state.tickLower || state.currentTick >= state.tickUpper;

  if (isOutOfRange) {
    return {
      shouldRebalance: true,
      reason: `Out of range: current tick ${state.currentTick} outside [${state.tickLower}, ${state.tickUpper}]`,
      isOutOfRange: true,
      isNearEdge: false,
      isCooldownActive: false,
      isDeviationExcessive: false,
      deviationBps,
    };
  }

  // 6. Near-boundary proximity check
  const width = state.tickUpper - state.tickLower;
  const edgeTicks = Math.floor(width * edgeThresholdPercent);
  const isNearEdge =
    state.rebalanceDue ||
    state.currentTick <= state.tickLower + edgeTicks ||
    state.currentTick >= state.tickUpper - edgeTicks;

  if (isNearEdge) {
    return {
      shouldRebalance: true,
      reason: `Near boundary: tick ${state.currentTick} within edge threshold of [${state.tickLower}, ${state.tickUpper}]`,
      isOutOfRange: false,
      isNearEdge: true,
      isCooldownActive: false,
      isDeviationExcessive: false,
      deviationBps,
    };
  }

  return {
    shouldRebalance: false,
    reason: `Position healthy and centered in range [${state.tickLower}, ${state.tickUpper}]`,
    isOutOfRange: false,
    isNearEdge: false,
    isCooldownActive: false,
    isDeviationExcessive: false,
    deviationBps,
  };
}
