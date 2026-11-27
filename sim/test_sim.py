"""Test suite for the RangeFit Python simulation engine."""

import math
import numpy as np
import pytest

from sim.models.math_core import (
    tick_to_sqrt_price,
    sqrt_price_to_tick,
    is_feasible,
    solve_range,
    compute_range_usage_and_dust,
    get_amounts_for_liquidity,
    search_neighbor_ticks
)
from sim.models.pool import PoolEnvironment
from sim.strategies.baseline_alm import BaselineALMStrategy
from sim.strategies.rangefit_core import RangeFitCoreStrategy
from sim.strategies.rangefit_fee_skew import RangeFitFeeSkewStrategy
from sim.strategies.passive_wide import PassiveWideStrategy

def test_tick_math_roundtrip():
    for tick in [-1200, -60, 0, 60, 1200]:
        sqrt_p = tick_to_sqrt_price(tick)
        recovered_tick = sqrt_price_to_tick(sqrt_p)
        assert abs(recovered_tick - tick) <= 1

def test_solver_example_a():
    # Example A from PROJECT.md: s=1.0, u=0.5, X=4, Y=6 -> v=1.5
    s = 1.0
    u = 0.5
    x = 4.0
    y = 6.0
    assert is_feasible(s, u, x, y)
    v = solve_range(s, u, x, y)
    assert math.isclose(v, 1.5, rel_tol=1e-5)

def test_solver_infeasible_inventory():
    s = 1.0
    u = 0.9
    # (s - u) * X >= Y -> (0.1) * 100 = 10 >= 5
    assert not is_feasible(s, u, 100.0, 5.0)

def test_pool_slippage_and_swap():
    pool = PoolEnvironment(base_fee_rate=0.0005, background_liquidity_depth=1_000_000.0)
    fee, slippage = pool.execute_baseline_swap(swap_amount_usd=100_000.0, spot_price=2500.0)
    assert fee == 50.0 # 0.05% of 100k
    assert slippage > 0.0 # positive price impact

def test_all_strategies_single_step():
    p0 = 2500.0
    pool = PoolEnvironment()
    
    passive = PassiveWideStrategy(10.0, 25000.0, p0)
    baseline = BaselineALMStrategy(10.0, 25000.0, p0)
    rf_core = RangeFitCoreStrategy(10.0, 25000.0, p0)
    rf_skew = RangeFitFeeSkewStrategy(10.0, 25000.0, p0)

    for strat in [passive, baseline, rf_core, rf_skew]:
        strat.step(2550.0, 2500.0, pool, 1.0 / 24.0, 1)
        val = strat.get_portfolio_value(2550.0)
        assert val > 0.0
        assert not math.isnan(val)
