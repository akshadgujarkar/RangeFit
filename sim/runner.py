"""Main simulation orchestrator running Monte Carlo benchmark across all strategies and regimes."""

import os
import sys
import argparse
import time
import numpy as np
import pandas as pd
from typing import List, Dict

from .config import DEFAULT_CONFIG, SimConfig
from .models.pool import PoolEnvironment
from .models.price_paths import generate_all_regime_paths
from .strategies.passive_wide import PassiveWideStrategy
from .strategies.baseline_alm import BaselineALMStrategy
from .strategies.rangefit_core import RangeFitCoreStrategy
from .strategies.rangefit_fee_skew import RangeFitFeeSkewStrategy
from .analytics.metrics import compute_path_metrics, summarize_benchmark_results
from .analytics.visualizer import (
    plot_pnl_comparison,
    plot_cumulative_economics,
    plot_price_and_asymmetric_range
)

def run_simulation_suite(
    config: SimConfig = DEFAULT_CONFIG,
    num_paths: int = 100,
    days: int = 30
) -> pd.DataFrame:
    print(f"=== RangeFit Simulation & Benchmark Suite ===")
    print(f"Capital: {config.initial_eth_amount} ETH + ${config.initial_usdc_amount:,.0f} USDC (${config.initial_eth_amount * config.initial_eth_price + config.initial_usdc_amount:,.0f} Total)")
    print(f"Regimes: 5 | Paths per Regime: {num_paths} | Horizon: {days} Days ({days * config.steps_per_day} steps)")
    print(f"Pool: 0.05% Fee Tier | ${config.background_liquidity_depth / 1e6:.1f}M Background Depth")
    print("-------------------------------------------------------------")

    # 1. Generate scenario matrix
    print("• Generating stochastic price paths...")
    regimes = generate_all_regime_paths(
        s0=config.initial_eth_price,
        days=days,
        steps_per_day=config.steps_per_day,
        num_paths=num_paths,
        base_seed=config.random_seed
    )

    all_records: List[Dict] = []
    sample_baseline = None
    sample_rangefit = None

    start_time = time.time()
    total_runs = len(regimes) * num_paths

    # 2. Execute simulation across regimes
    for regime_name, paths in regimes.items():
        print(f"  -> Simulating Regime: {regime_name} ({num_paths} paths)...")
        pool_env = PoolEnvironment(
            base_fee_rate=config.base_fee_rate,
            background_liquidity_depth=config.background_liquidity_depth,
            daily_volume_to_depth_ratio=config.daily_volume_to_depth_ratio,
            gas_price_gwei=config.eth_gas_price_gwei
        )

        dt_days = 1.0 / config.steps_per_day
        total_steps = days * config.steps_per_day

        for path_idx in range(num_paths):
            path = paths[path_idx]

            # Instantiate 4 strategies with identical starting state
            strat_passive = PassiveWideStrategy(
                config.initial_eth_amount, config.initial_usdc_amount, path[0]
            )
            strat_baseline = BaselineALMStrategy(
                config.initial_eth_amount, config.initial_usdc_amount, path[0],
                target_width_ticks=config.target_width_ticks,
                edge_threshold_percent=config.edge_threshold_percent,
                cooldown_steps=config.cooldown_steps,
                tick_spacing=config.tick_spacing
            )
            strat_rangefit = RangeFitCoreStrategy(
                config.initial_eth_amount, config.initial_usdc_amount, path[0],
                target_width_ticks=config.target_width_ticks,
                edge_threshold_percent=config.edge_threshold_percent,
                cooldown_steps=config.cooldown_steps,
                tick_spacing=config.tick_spacing,
                ema_alpha=config.ema_alpha,
                max_deviation_bps=config.max_deviation_bps
            )
            strat_skew = RangeFitFeeSkewStrategy(
                config.initial_eth_amount, config.initial_usdc_amount, path[0],
                target_width_ticks=config.target_width_ticks,
                edge_threshold_percent=config.edge_threshold_percent,
                cooldown_steps=config.cooldown_steps,
                tick_spacing=config.tick_spacing,
                ema_alpha=config.ema_alpha,
                max_deviation_bps=config.max_deviation_bps,
                fee_sensitivity=config.fee_skew_sensitivity,
                min_fee_rate=config.min_fee_rate,
                max_fee_rate=config.max_fee_rate
            )

            # Step through each hour
            for step_idx in range(total_steps):
                prev_p = path[step_idx]
                curr_p = path[step_idx + 1]

                strat_passive.step(curr_p, prev_p, pool_env, dt_days, step_idx)
                strat_baseline.step(curr_p, prev_p, pool_env, dt_days, step_idx)
                strat_rangefit.step(curr_p, prev_p, pool_env, dt_days, step_idx)
                strat_skew.step(curr_p, prev_p, pool_env, dt_days, step_idx)

            # Compute and record metrics
            for strat in [strat_passive, strat_baseline, strat_rangefit, strat_skew]:
                m = compute_path_metrics(
                    strat, path, config.initial_eth_amount, config.initial_usdc_amount
                )
                m["regime"] = regime_name
                m["path_idx"] = path_idx
                all_records.append(m)

            # Keep sample runs for visualization
            if sample_baseline is None and regime_name == "Mean_Reverting":
                sample_baseline = strat_baseline
                sample_rangefit = strat_rangefit

    elapsed = time.time() - start_time
    print(f"✓ Simulation completed in {elapsed:.2f} seconds ({len(all_records)} total strategy-path runs).")

    df_results = pd.DataFrame(all_records)

    # 3. Save artifacts
    results_dir = os.path.join(os.path.dirname(__file__), "results")
    figures_dir = os.path.join(results_dir, "figures")
    os.makedirs(figures_dir, exist_ok=True)

    csv_path = os.path.join(results_dir, "simulation_results.csv")
    df_results.to_csv(csv_path, index=False)
    print(f"• Saved raw results to: {csv_path}")

    # Generate charts
    print("• Generating publication comparison figures...")
    plot_pnl_comparison(df_results, os.path.join(figures_dir, "pnl_comparison.png"))
    if sample_baseline and sample_rangefit:
        plot_cumulative_economics(
            sample_baseline, sample_rangefit, os.path.join(figures_dir, "cumulative_fees_swaps.png")
        )
        plot_price_and_asymmetric_range(
            sample_rangefit, os.path.join(figures_dir, "price_path_rebalance.png")
        )

    # Print summary table
    summary_df = summarize_benchmark_results(df_results)
    print("\n=== BENCHMARK SUMMARY (Median Performance) ===")
    median_table = df_results.groupby(["regime", "strategy"])[
        ["pnl_vs_hold_pct", "fees_earned_usd", "swap_costs_usd", "rebalance_count", "time_in_range_pct"]
    ].median().round(2)
    print(median_table.to_string())

    return df_results

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run RangeFit Simulation Benchmark")
    parser.add_argument("--paths", type=int, default=100, help="Number of paths per regime")
    parser.add_argument("--days", type=int, default=30, help="Simulation time horizon in days")
    args = parser.parse_args()

    run_simulation_suite(num_paths=args.paths, days=args.days)
