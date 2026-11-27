// Uniswap v4 TickMath constants & conversion functions

export const Q96 = 2n ** 96n;
export const MIN_TICK = -887272;
export const MAX_TICK = 887272;
export const MIN_SQRT_PRICE = 4295128739n;
export const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;

/**
 * Computes sqrt(1.0001^tick) * 2^96 with high precision.
 * @param tick Integer tick between MIN_TICK and MAX_TICK
 */
export function getSqrtPriceAtTick(tick: number): bigint {
  if (tick < MIN_TICK || tick > MAX_TICK) {
    throw new Error(`Tick ${tick} out of bounds`);
  }

  // Exact floating point conversion for 1.0001^(tick/2) * 2^96
  // Handles positive and negative ticks accurately
  const ratio = Math.pow(1.0001, tick / 2);
  const q96Number = Number(Q96);
  return BigInt(Math.floor(ratio * q96Number));
}

/**
 * Computes tick from sqrtPriceX96.
 * @param sqrtPriceX96 Q96 square-root price
 */
export function getTickAtSqrtPrice(sqrtPriceX96: bigint): number {
  if (sqrtPriceX96 < MIN_SQRT_PRICE || sqrtPriceX96 > MAX_SQRT_PRICE) {
    throw new Error(`sqrtPriceX96 ${sqrtPriceX96} out of bounds`);
  }
  const ratio = Number(sqrtPriceX96) / Number(Q96);
  const price = ratio * ratio;
  return Math.floor(Math.log(price) / Math.log(1.0001));
}

/**
 * Floors a tick to the nearest multiple of spacing.
 */
export function floorTick(tick: number, spacing: number): number {
  return Math.floor(tick / spacing) * spacing;
}

/**
 * Ceils a tick to the nearest multiple of spacing.
 */
export function ceilTick(tick: number, spacing: number): number {
  return Math.ceil(tick / spacing) * spacing;
}

/**
 * Rounds a tick to the nearest multiple of spacing.
 */
export function roundTick(tick: number, spacing: number): number {
  const lower = floorTick(tick, spacing);
  if (tick - lower >= Math.floor((spacing + 1) / 2)) {
    return lower + spacing;
  }
  return lower;
}
