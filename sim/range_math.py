"""
RangeMath Python Reference Oracle.
Mirrors the exact fixed-point Q96 arithmetic, analytical solver, tick alignment,
and dust calculations implemented in src/libraries/RangeMath.sol.
"""

import math
import json
from typing import Dict, Any, Tuple, Optional

Q96 = 2**96
MIN_TICK = -887272
MAX_TICK = 887272
MIN_SQRT_PRICE = 4295128739
MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342
UINT128_MAX = 2**128 - 1
UINT256_MAX = 2**256 - 1


def mul_div(a: int, b: int, denominator: int) -> int:
    """Integer division floor(a * b / denominator) matching Solidity FullMath.mulDiv."""
    if denominator == 0:
        raise ZeroDivisionError("mulDiv denominator is zero")
    return (a * b) // denominator


def get_sqrt_price_at_tick(tick: int) -> int:
    """Computes sqrt(1.0001^tick) * 2^96 using floating-point math converted to integer."""
    if not (MIN_TICK <= tick <= MAX_TICK):
        raise ValueError(f"Tick {tick} out of bounds")
    return int((1.0001 ** (tick / 2)) * Q96)


def get_tick_at_sqrt_price(sqrt_price_x96: int) -> int:
    """Computes tick for a given sqrtPriceX96."""
    if not (MIN_SQRT_PRICE <= sqrt_price_x96 <= MAX_SQRT_PRICE):
        raise ValueError(f"sqrtPriceX96 {sqrt_price_x96} out of bounds")
    price = (sqrt_price_x96 / Q96) ** 2
    tick = math.floor(math.log(price, 1.0001))
    return int(tick)


def floor_tick(tick: int, spacing: int) -> int:
    """Computes floor(tick / spacing) * spacing."""
    compressed = tick // spacing
    return compressed * spacing


def ceil_tick(tick: int, spacing: int) -> int:
    """Computes ceil(tick / spacing) * spacing."""
    compressed = tick // spacing
    if tick % spacing != 0:
        compressed += 1
    return compressed * spacing


def round_tick(tick: int, spacing: int) -> int:
    """Computes nearest multiple of spacing."""
    lower = floor_tick(tick, spacing)
    if tick - lower >= (spacing + 1) // 2:
        return lower + spacing
    return lower


def solve_range(
    sqrt_price_x96: int,
    sqrt_price_lower_x96: int,
    amount0: int,
    amount1: int,
) -> Tuple[int, int]:
    """
    Solves for (liquidity, sqrt_price_upper_x96).
    Matches RangeMath.solveRange() exactly.
    """
    if amount0 <= 0 or amount1 <= 0:
        raise ValueError("ZeroInventory")
    if sqrt_price_lower_x96 >= sqrt_price_x96:
        raise ValueError("LowerBoundGteCurrentPrice")
    if sqrt_price_lower_x96 < MIN_SQRT_PRICE:
        raise ValueError("LowerBoundBelowMin")

    delta_lower = sqrt_price_x96 - sqrt_price_lower_x96
    l_val = mul_div(amount1, Q96, delta_lower)
    if l_val > UINT128_MAX:
        raise OverflowError("LiquidityOverflow")

    l_q96 = l_val << 96
    product_xs = amount0 * sqrt_price_x96
    if product_xs > UINT256_MAX:
        raise OverflowError("ProductXS Overflow")

    if l_q96 <= product_xs:
        raise ValueError("UpperBoundNonPositive")

    denominator = l_q96 - product_xs
    raw_upper = mul_div(l_q96, sqrt_price_x96, denominator)

    if raw_upper > MAX_SQRT_PRICE:
        raise ValueError("UpperBoundAboveMax")

    return l_val, raw_upper


def is_feasible(
    sqrt_price_x96: int,
    sqrt_price_lower_x96: int,
    amount0: int,
    amount1: int,
) -> bool:
    """Checks feasibility without raising exceptions."""
    try:
        solve_range(sqrt_price_x96, sqrt_price_lower_x96, amount0, amount1)
        return True
    except Exception:
        return False


def get_liquidity_for_amount0(sqrt_ratio_a_x96: int, sqrt_ratio_b_x96: int, amount0: int) -> int:
    if sqrt_ratio_a_x96 > sqrt_ratio_b_x96:
        sqrt_ratio_a_x96, sqrt_ratio_b_x96 = sqrt_ratio_b_x96, sqrt_ratio_a_x96
    intermediate = mul_div(sqrt_ratio_a_x96, sqrt_ratio_b_x96, Q96)
    return mul_div(amount0, intermediate, sqrt_ratio_b_x96 - sqrt_ratio_a_x96)


def get_liquidity_for_amount1(sqrt_ratio_a_x96: int, sqrt_ratio_b_x96: int, amount1: int) -> int:
    if sqrt_ratio_a_x96 > sqrt_ratio_b_x96:
        sqrt_ratio_a_x96, sqrt_ratio_b_x96 = sqrt_ratio_b_x96, sqrt_ratio_a_x96
    return mul_div(amount1, Q96, sqrt_ratio_b_x96 - sqrt_ratio_a_x96)


def get_liquidity_for_amounts(
    sqrt_price_x96: int,
    sqrt_lower_x96: int,
    sqrt_upper_x96: int,
    amount0: int,
    amount1: int,
) -> int:
    """Calculates max consumable liquidity for amounts."""
    if sqrt_lower_x96 > sqrt_upper_x96:
        sqrt_lower_x96, sqrt_upper_x96 = sqrt_upper_x96, sqrt_lower_x96

    if sqrt_price_x96 <= sqrt_lower_x96:
        return get_liquidity_for_amount0(sqrt_lower_x96, sqrt_upper_x96, amount0)
    elif sqrt_price_x96 < sqrt_upper_x96:
        l0 = get_liquidity_for_amount0(sqrt_price_x96, sqrt_upper_x96, amount0)
        l1 = get_liquidity_for_amount1(sqrt_lower_x96, sqrt_price_x96, amount1)
        return min(l0, l1)
    else:
        return get_liquidity_for_amount1(sqrt_lower_x96, sqrt_upper_x96, amount1)


def get_amount0_delta(sqrt_ratio_a_x96: int, sqrt_ratio_b_x96: int, liquidity: int) -> int:
    if sqrt_ratio_a_x96 > sqrt_ratio_b_x96:
        sqrt_ratio_a_x96, sqrt_ratio_b_x96 = sqrt_ratio_b_x96, sqrt_ratio_a_x96
    numerator1 = liquidity << 96
    numerator2 = sqrt_ratio_b_x96 - sqrt_ratio_a_x96
    return mul_div(mul_div(numerator1, numerator2, sqrt_ratio_b_x96), 1, sqrt_ratio_a_x96)


def get_amount1_delta(sqrt_ratio_a_x96: int, sqrt_ratio_b_x96: int, liquidity: int) -> int:
    if sqrt_ratio_a_x96 > sqrt_ratio_b_x96:
        sqrt_ratio_a_x96, sqrt_ratio_b_x96 = sqrt_ratio_b_x96, sqrt_ratio_a_x96
    return mul_div(liquidity, sqrt_ratio_b_x96 - sqrt_ratio_a_x96, Q96)


def value_in_token1(amount0: int, sqrt_price_x96: int) -> int:
    """Evaluates amount0 in token1 units using spot price: amount0 * s^2 / Q96^2."""
    if amount0 == 0 or sqrt_price_x96 == 0:
        return 0
    inter = mul_div(amount0, sqrt_price_x96, Q96)
    return mul_div(inter, sqrt_price_x96, Q96)


def compute_range_usage_and_dust(
    sqrt_price_x96: int,
    sqrt_lower_x96: int,
    sqrt_upper_x96: int,
    amount0: int,
    amount1: int,
) -> Dict[str, Any]:
    """Computes liquidity, consumed amounts, dust, and dust basis points."""
    liquidity = get_liquidity_for_amounts(sqrt_price_x96, sqrt_lower_x96, sqrt_upper_x96, amount0, amount1)
    amount0_used = get_amount0_delta(sqrt_price_x96, sqrt_upper_x96, liquidity) if liquidity > 0 else 0
    amount1_used = get_amount1_delta(sqrt_lower_x96, sqrt_price_x96, liquidity) if liquidity > 0 else 0

    amount0_used = min(amount0_used, amount0)
    amount1_used = min(amount1_used, amount1)

    dust0 = amount0 - amount0_used
    dust1 = amount1 - amount1_used

    val0_total = value_in_token1(amount0, sqrt_price_x96)
    total_val = val0_total + amount1

    val0_dust = value_in_token1(dust0, sqrt_price_x96)
    total_dust_val = val0_dust + dust1

    dust_bps = mul_div(total_dust_val, 10000, total_val) if total_val > 0 else 0

    return {
        "liquidity": liquidity,
        "amount0_used": amount0_used,
        "amount1_used": amount1_used,
        "dust0": dust0,
        "dust1": dust1,
        "dust_bps": dust_bps,
    }


def run_example_a() -> Dict[str, Any]:
    """
    Example A from docs/PROJECT.md Section 5.1:
    P = 1 => s = Q96
    X = 4, Y = 6
    u = 0.5 * Q96
    Expected: L = 12, v = 1.5 * Q96
    """
    s = Q96
    u = Q96 // 2
    x = 4
    y = 6
    liq, v = solve_range(s, u, x, y)
    v_float = v / Q96
    return {
        "name": "Example A",
        "s": s,
        "u": u,
        "x": x,
        "y": y,
        "liquidity": liq,
        "v": v,
        "v_float": v_float,
        "expected_l": 12,
        "expected_v_float": 1.5,
    }


def run_example_b() -> Dict[str, Any]:
    """
    Example B from docs/PROJECT.md Section 5.2 (Bob with real numbers):
    ETH = $2,400, s = sqrt(2400) = 48.98979486
    X = 1.5 ETH, Y = 6400 USDC
    u = 40 (P_lower = 1600)
    Expected: L = 711.918, v = 54.6286 (P_upper = 2984.28)
    """
    # Scaling to Q96
    p_float = 2400.0
    s_float = math.sqrt(p_float)
    u_float = 40.0
    s_x96 = int(s_float * Q96)
    u_x96 = int(u_float * Q96)
    # Using normalized 18 decimals for test:
    x = int(1.5 * 10**18)
    y = int(6400.0 * 10**18)

    liq, v = solve_range(s_x96, u_x96, x, y)
    l_float = liq / 10**18
    v_float = v / Q96
    p_upper_float = v_float**2

    return {
        "name": "Example B",
        "p_float": p_float,
        "s_float": s_float,
        "u_float": u_float,
        "x": x,
        "y": y,
        "liquidity": liq,
        "l_float": l_float,
        "v_float": v_float,
        "p_upper_float": p_upper_float,
    }


if __name__ == "__main__":
    ex_a = run_example_a()
    print("--- Example A Results ---")
    print(f"Liquidity: {ex_a['liquidity']} (Expected: {ex_a['expected_l']})")
    print(f"Upper v: {ex_a['v_float']:.6f} (Expected: {ex_a['expected_v_float']:.6f})")

    ex_b = run_example_b()
    print("\n--- Example B Results ---")
    print(f"Liquidity: {ex_b['l_float']:.4f} (Expected ~711.918)")
    print(f"Upper v: {ex_b['v_float']:.4f} (Expected ~54.6286)")
    print(f"Upper Price: ${ex_b['p_upper_float']:.2f} (Expected ~$2,984)")
