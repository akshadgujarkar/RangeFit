import { describe, it, expect } from "vitest";
import {
  evaluateRebalance,
  computePriceDeviationBps,
  type PoolVaultState,
} from "../src/services/decisionEngine.js";
import { solveOptimalRange } from "../src/services/solverService.js";
import { Q96 } from "../src/math/tickMath.js";

function getBaseState(): PoolVaultState {
  return {
    currentTick: 0,
    spotPriceX96: Q96,
    emaPriceX96: Q96,
    tickLower: -120,
    tickUpper: 120,
    activeLiquidity: 1000n * 10n ** 18n,
    idle0: 10n ** 18n,
    idle1: 10n ** 18n,
    totalInv0: 100n * 10n ** 18n,
    totalInv1: 100n * 10n ** 18n,
    rebalanceDue: false,
    cooldown: 60,
    lastRebalance: 1000,
    currentTimestamp: 2000, // 1000s > 60s cooldown
    maxDeviationBps: 1000n, // 10%
    minWidthTicks: 60,
    maxWidthTicks: 887220,
    keeperOnly: false,
    isAuthorizedKeeper: true,
  };
}

describe("DecisionEngine Tests", () => {
  it("Deviation calculation matches formula", () => {
    const s = 1050n;
    const ema = 1000n;
    // |1050 - 1000| * 10000 / 1000 = 500 bps (5%)
    expect(computePriceDeviationBps(s, ema)).toBe(500n);

    // Identical prices -> 0 bps
    expect(computePriceDeviationBps(Q96, Q96)).toBe(0n);
  });

  it("Position healthy & centered does not trigger rebalance", () => {
    const state = getBaseState();
    const decision = evaluateRebalance(state, 0.20);
    expect(decision.shouldRebalance).toBe(false);
    expect(decision.isOutOfRange).toBe(false);
    expect(decision.isNearEdge).toBe(false);
  });

  it("Out-of-range position triggers rebalance", () => {
    const state = getBaseState();
    state.currentTick = 150; // upper bound is 120
    const decision = evaluateRebalance(state, 0.20);
    expect(decision.shouldRebalance).toBe(true);
    expect(decision.isOutOfRange).toBe(true);
    expect(decision.reason).toContain("Out of range");
  });

  it("Near-boundary position triggers rebalance", () => {
    const state = getBaseState();
    // width = 240, edgeTicks = 48 ticks
    // Upper bound is 120, tick 100 is within 20 ticks of boundary (< 48)
    state.currentTick = 105;
    const decision = evaluateRebalance(state, 0.20);
    expect(decision.shouldRebalance).toBe(true);
    expect(decision.isNearEdge).toBe(true);
    expect(decision.reason).toContain("Near boundary");
  });

  it("rebalanceDue flag triggers rebalance", () => {
    const state = getBaseState();
    state.currentTick = 0;
    state.rebalanceDue = true;
    const decision = evaluateRebalance(state, 0.20);
    expect(decision.shouldRebalance).toBe(true);
    expect(decision.isNearEdge).toBe(true);
  });

  it("Initial deposit with 0 active liquidity triggers rebalance", () => {
    const state = getBaseState();
    state.activeLiquidity = 0n;
    state.idle0 = 50n * 10n ** 18n;
    state.idle1 = 50n * 10n ** 18n;
    const decision = evaluateRebalance(state, 0.20);
    expect(decision.shouldRebalance).toBe(true);
    expect(decision.reason).toContain("Initial deployment");
  });

  it("Active cooldown blocks rebalance even when out of range", () => {
    const state = getBaseState();
    state.currentTick = 200; // Out of range!
    state.lastRebalance = 1000;
    state.cooldown = 120;
    state.currentTimestamp = 1050; // Only 50s elapsed < 120s!

    const decision = evaluateRebalance(state, 0.20);
    expect(decision.shouldRebalance).toBe(false);
    expect(decision.isCooldownActive).toBe(true);
    expect(decision.reason).toContain("Cooldown active");
  });

  it("Excessive price deviation blocks rebalance", () => {
    const state = getBaseState();
    state.currentTick = 200;
    // Spot is 15% higher than EMA -> 1500 bps > 1000 bps max
    state.spotPriceX96 = (Q96 * 115n) / 100n;
    state.emaPriceX96 = Q96;

    const decision = evaluateRebalance(state, 0.20);
    expect(decision.shouldRebalance).toBe(false);
    expect(decision.isDeviationExcessive).toBe(true);
    expect(decision.reason).toContain("Price deviation too high");
  });

  it("Unauthorized keeper blocked when keeperOnly is enabled", () => {
    const state = getBaseState();
    state.currentTick = 200;
    state.keeperOnly = true;
    state.isAuthorizedKeeper = false;

    const decision = evaluateRebalance(state, 0.20);
    expect(decision.shouldRebalance).toBe(false);
    expect(decision.reason).toContain("Unauthorized keeper");
  });
});

describe("SolverService Tests", () => {
  it("solveOptimalRange finds valid range conforming to spacing and dust tolerance", () => {
    const solved = solveOptimalRange({
      spotPriceX96: Q96,
      inv0: 100n * 10n ** 18n,
      inv1: 100n * 10n ** 18n,
      tickSpacing: 60,
      targetWidthTicks: 240,
      minWidthTicks: 60,
      maxWidthTicks: 887220,
      maxDustBps: 1000n,
    });

    expect(solved).not.toBeNull();
    expect(Math.abs(solved!.newTickLower % 60)).toBe(0);
    expect(Math.abs(solved!.newTickUpper % 60)).toBe(0);
    expect(solved!.newTickUpper).toBeGreaterThan(solved!.newTickLower);
    expect(solved!.expectedLiquidity).toBeGreaterThan(0n);
    expect(solved!.minLiquidity).toBeLessThanOrEqual(solved!.expectedLiquidity);
    expect(solved!.dustBps).toBeLessThanOrEqual(1000n);
  });
});
