import { describe, it, expect } from "vitest";
import {
  mulDiv,
  solveRange,
  isFeasible,
  computeRangeUsageAndDust,
  searchNeighborTicks,
} from "../src/math/rangeMath.js";
import {
  Q96,
  getSqrtPriceAtTick,
  getTickAtSqrtPrice,
  floorTick,
  ceilTick,
  roundTick,
} from "../src/math/tickMath.js";

describe("RangeMath TypeScript Parity Tests", () => {
  it("mulDiv matches Solidity FullMath", () => {
    expect(mulDiv(10n, 20n, 5n)).toBe(40n);
    expect(mulDiv(100n, 1n, 3n)).toBe(33n); // floor
    expect(() => mulDiv(10n, 20n, 0n)).toThrow();
  });

  it("Tick conversion utilities", () => {
    expect(floorTick(125, 60)).toBe(120);
    expect(ceilTick(125, 60)).toBe(180);
    expect(roundTick(125, 60)).toBe(120);
    expect(roundTick(155, 60)).toBe(180);

    const sqrtAt0 = getSqrtPriceAtTick(0);
    // tick 0 sqrtPrice is 1.0 * 2^96
    expect(sqrtAt0).toBe(Q96);
    expect(getTickAtSqrtPrice(Q96)).toBe(0);
  });

  it("Example A: Toy normalized test vector (s=1.0, u=0.5, x=4, y=6)", () => {
    // In Q96 fixed point:
    const s = Q96; // 1.0 * Q96
    const u = Q96 / 2n; // 0.5 * Q96
    const x = 4n;
    const y = 6n;

    expect(isFeasible(s, u, x, y)).toBe(true);

    const { liquidity, sqrtUpperX96 } = solveRange(s, u, x, y);
    expect(liquidity).toBe(12n); // L = Y * Q96 / (s - u) = 6 / 0.5 = 12

    // Expected v = 1.5 * Q96
    const expectedV = (3n * Q96) / 2n;
    expect(sqrtUpperX96).toBe(expectedV);
  });

  it("Example B: Bob with ETH/USDC at $2,400 (normalized values)", () => {
    // Exact sqrt(2400) * Q96
    const s = 3881371428364983746953216000000n;
    // 40 * Q96
    const u = 3169126500570573762985984000000n;
    const x = 1500000000000000000n; // 1.5 * 10^18
    const y = 6400000000000000000000n; // 6400 * 10^18

    expect(isFeasible(s, u, x, y)).toBe(true);

    const { liquidity, sqrtUpperX96 } = solveRange(s, u, x, y);
    // Expected L ~= 711.918358 * 10^18
    const expectedL = 711918358845308557839n;
    const diffL = liquidity > expectedL ? liquidity - expectedL : expectedL - liquidity;
    expect(Number((diffL * 10000n) / expectedL)).toBeLessThan(1); // < 0.01%

    // Expected upper bound v ≈ 54.6286 * Q96
    const expectedV = 4328123221056881793477995421827n;
    const diffV = sqrtUpperX96 > expectedV ? sqrtUpperX96 - expectedV : expectedV - sqrtUpperX96;
    expect(Number((diffV * 10000n) / expectedV)).toBeLessThan(1); // < 0.01%
  });

  it("Rejects infeasible inputs", () => {
    const s = Q96;
    const u = (Q96 * 9n) / 10n;

    // Zero inventory
    expect(isFeasible(s, u, 0n, 100n)).toBe(false);
    expect(isFeasible(s, u, 100n, 0n)).toBe(false);

    // Lower bound >= spot
    expect(isFeasible(s, s, 100n, 100n)).toBe(false);
    expect(isFeasible(s, s + 100n, 100n, 100n)).toBe(false);

    // Infeasible ratio (X too large for Y, denominator <= 0)
    expect(isFeasible(s, u, 1000n * 10n ** 18n, 1n)).toBe(false);
  });

  it("searchNeighborTicks returns minimal dust range", () => {
    const s = Q96;
    const amount0 = 100n * 10n ** 18n;
    const amount1 = 100n * 10n ** 18n;
    const tickSpacing = 60;
    const targetLower = -120;

    const candidate = searchNeighborTicks(s, targetLower, amount0, amount1, tickSpacing, 2);
    expect(candidate).not.toBeNull();
    expect(candidate!.tickLower).toBeLessThan(0);
    expect(candidate!.tickUpper).toBeGreaterThan(0);
    expect(candidate!.dustBps).toBeLessThan(500n); // < 5% dust
    expect(candidate!.liquidity).toBeGreaterThan(0n);
  });
});
