"""Mathematical core for Uniswap v4 concentrated liquidity and RangeFit analytical solver.
Provides exact parity with RangeMath.sol and rangeMath.ts.
"""

import math
from typing import NamedTuple, Optional

TICK_BASE = 1.0001
MIN_TICK = -887272
MAX_TICK = 887272

class RangeUsage(NamedTuple):
    liquidity: float
    amount0_used: float
    amount1_used: float
    dust0: float
    dust1: float
    dust_bps: float # dust value as basis points of total inventory value

class SolvedRange(NamedTuple):
    tick_lower: int
    tick_upper: int
    sqrt_lower: float
    sqrt_upper: float
    liquidity: float
    dust0: float
    dust1: float
    dust_bps: float

def tick_to_sqrt_price(tick: int) -> float:
    """Converts a discrete tick index to square-root price sqrt(P)."""
    return math.pow(TICK_BASE, tick / 2.0)

def sqrt_price_to_tick(sqrt_p: float) -> int:
    """Converts a square-root price sqrt(P) to the nearest discrete tick."""
    if sqrt_p <= 0:
        raise ValueError("Price must be strictly positive")
    tick = round(2.0 * math.log(sqrt_p) / math.log(TICK_BASE))
    return max(MIN_TICK, min(MAX_TICK, int(tick)))

def align_tick(tick: int, spacing: int, mode: str = "round") -> int:
    """Aligns a tick to a multiple of tick spacing."""
    if spacing <= 0:
        return tick
    if mode == "floor":
        return math.floor(tick / spacing) * spacing
    elif mode == "ceil":
        return math.ceil(tick / spacing) * spacing
    else: # round
        return round(tick / spacing) * spacing

def is_feasible(s: float, u: float, x: float, y: float) -> bool:
    """
    Checks if current inventory (X, Y) can form an active in-range position
    at spot price s given lower bound u.
    Conditions:
      1. u < s (lower bound below spot)
      2. L > X * s, where L = Y / (s - u) (i.e. Y > X * s * (s - u))
    """
    if u <= 0 or s <= 0 or x <= 0 or y <= 0:
        return False
    if u >= s:
        return False
    l = y / (s - u)
    return l > (x * s)

def solve_range(s: float, u: float, x: float, y: float) -> float:
    """
    Closed-form analytical solver for the upper price boundary v = sqrt(p_b):
      L = Y / (s - u)
      v = (L * s) / (L - X * s) = (Y * s) / (Y - X * s * (s - u))
    """
    if not is_feasible(s, u, x, y):
        raise ValueError(f"Infeasible inventory for lower bound: s={s}, u={u}, x={x}, y={y}")
    
    l = y / (s - u)
    denom = l - (x * s)
    if denom <= 0:
        raise ValueError(f"Denominator non-positive in solve_range: {denom}")
    
    return (l * s) / denom

def compute_range_usage_and_dust(s: float, u: float, v: float, x: float, y: float) -> RangeUsage:
    """
    Calculates token consumption, deployable liquidity, and residual dust
    when placing inventory (X, Y) into range [u, v] at spot price s.
    """
    if u >= s or v <= s or u >= v:
        return RangeUsage(0.0, 0.0, 0.0, x, y, 10000.0)

    # Liquidity supported by Token0 (X) and Token1 (Y)
    l0 = x * (s * v) / (v - s) if (v - s) > 0 else 0.0
    l1 = y / (s - u) if (s - u) > 0 else 0.0
    liq = min(l0, l1)

    if liq <= 0:
        return RangeUsage(0.0, 0.0, 0.0, x, y, 10000.0)

    # Actual token consumption
    x_used = liq * (v - s) / (s * v)
    y_used = liq * (s - u)

    dust0 = max(0.0, x - x_used)
    dust1 = max(0.0, y - y_used)

    # Valuation at spot price s (price P = s^2)
    p_spot = s * s
    total_val = x * p_spot + y
    dust_val = dust0 * p_spot + dust1
    dust_bps = (dust_val / total_val * 10000.0) if total_val > 0 else 10000.0

    return RangeUsage(
        liquidity=liq,
        amount0_used=x_used,
        amount1_used=y_used,
        dust0=dust0,
        dust1=dust1,
        dust_bps=dust_bps
    )

def get_amounts_for_liquidity(s: float, u: float, v: float, liq: float) -> tuple[float, float]:
    """
    Returns the exact (amount0, amount1) tokens held by a position with liquidity L
    at current spot price s.
    """
    if liq <= 0:
        return 0.0, 0.0
    
    if s <= u:
        # Below lower bound: 100% token0
        return liq * (v - u) / (u * v), 0.0
    elif s >= v:
        # Above upper bound: 100% token1
        return 0.0, liq * (v - u)
    else:
        # In range: mixed token0 and token1
        x = liq * (v - s) / (s * v)
        y = liq * (s - u)
        return x, y

def search_neighbor_ticks(
    s: float,
    target_lower_tick: int,
    x: float,
    y: float,
    tick_spacing: int = 60,
    radius: int = 4,
    min_width_ticks: int = 60,
    max_width_ticks: int = 2400
) -> Optional[SolvedRange]:
    """
    Searches discrete candidate ticks around target_lower_tick to find the range
    with the lowest residual dust that satisfies width bounds.
    """
    current_tick = sqrt_price_to_tick(s)
    best_candidate: Optional[SolvedRange] = None

    for d in range(-radius, radius + 1):
        candidate_lower = target_lower_tick + d * tick_spacing
        if candidate_lower >= current_tick:
            continue

        sqrt_lower = tick_to_sqrt_price(candidate_lower)
        if not is_feasible(s, sqrt_lower, x, y):
            continue

        try:
            raw_upper = solve_range(s, sqrt_lower, x, y)
        except ValueError:
            continue

        solved_upper_tick = sqrt_price_to_tick(raw_upper)

        # Check floor, ceil, and round options for upper tick
        candidate_uppers = [
            align_tick(solved_upper_tick, tick_spacing, "floor"),
            align_tick(solved_upper_tick, tick_spacing, "ceil"),
            align_tick(solved_upper_tick, tick_spacing, "round"),
        ]

        for cand_upper in set(candidate_uppers):
            if cand_upper <= current_tick or cand_upper <= candidate_lower:
                continue

            width = cand_upper - candidate_lower
            if min_width_ticks > 0 and width < min_width_ticks:
                continue
            if max_width_ticks > 0 and width > max_width_ticks:
                continue

            sqrt_upper = tick_to_sqrt_price(cand_upper)
            usage = compute_range_usage_and_dust(s, sqrt_lower, sqrt_upper, x, y)

            if usage.liquidity <= 0:
                continue

            if best_candidate is None or usage.dust_bps < best_candidate.dust_bps:
                best_candidate = SolvedRange(
                    tick_lower=candidate_lower,
                    tick_upper=cand_upper,
                    sqrt_lower=sqrt_lower,
                    sqrt_upper=sqrt_upper,
                    liquidity=usage.liquidity,
                    dust0=usage.dust0,
                    dust1=usage.dust1,
                    dust_bps=usage.dust_bps
                )

    return best_candidate
