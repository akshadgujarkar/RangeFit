"""Analytics and financial metrics computation for LP strategy evaluation."""

import numpy as np
import pandas as pd
from typing import Dict, Any
from ..strategies.base import BaseStrategy

def compute_path_metrics(
    strategy: BaseStrategy,
    price_path: np.ndarray,
    initial_eth: float,
    initial_usdc: float
) -> Dict[str, Any]:
    """Calculates summary performance metrics for a single simulation path."""
    final_price = price_path[-1]
    final_val = strategy.get_portfolio_value(final_price)
    hold_val = initial_eth * final_price + initial_usdc

    # Returns
    pnl_vs_hold_pct = ((final_val - hold_val) / hold_val) * 100.0 if hold_val > 0 else 0.0
    net_pnl_usd = final_val - hold_val

    # Drawdown
    val_series = np.array(strategy.history_portfolio_value)
    if len(val_series) > 0:
        cum_max = np.maximum.accumulate(val_series)
        drawdowns = (cum_max - val_series) / cum_max
        max_drawdown_pct = float(np.max(drawdowns)) * 100.0
    else:
        max_drawdown_pct = 0.0

    # Time in range
    time_in_range_pct = (
        (strategy.time_in_range_steps / strategy.total_steps) * 100.0
        if strategy.total_steps > 0 else 0.0
    )

    return {
        "strategy": strategy.name,
        "final_value_usd": final_val,
        "hold_value_usd": hold_val,
        "net_pnl_usd": net_pnl_usd,
        "pnl_vs_hold_pct": pnl_vs_hold_pct,
        "fees_earned_usd": strategy.lifetime_fees_earned_usd,
        "swap_costs_usd": strategy.cumulative_swap_cost_usd,
        "gas_costs_usd": strategy.cumulative_gas_cost_usd,
        "rebalance_count": strategy.rebalance_count,
        "time_in_range_pct": time_in_range_pct,
        "max_drawdown_pct": max_drawdown_pct,
    }

def summarize_benchmark_results(results_df: pd.DataFrame) -> pd.DataFrame:
    """Aggregates metrics by market regime and strategy."""
    grouped = results_df.groupby(["regime", "strategy"])
    summary = grouped.agg({
        "pnl_vs_hold_pct": ["median", "mean", "std"],
        "fees_earned_usd": ["median", "mean"],
        "swap_costs_usd": ["median", "mean"],
        "gas_costs_usd": ["median", "mean"],
        "rebalance_count": ["median", "mean"],
        "time_in_range_pct": ["median", "mean"],
        "max_drawdown_pct": ["median", "mean"],
    }).round(2)
    return summary
