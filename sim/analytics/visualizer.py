"""Publication-quality chart generation using Matplotlib:
1. PnL vs. Hold distribution across market regimes (boxplots)
2. Cumulative fees vs swap costs over time
3. Price trajectory with dynamic asymmetric range boundaries
"""

import os
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# Style settings for clean publication diagrams
plt.style.use("seaborn-v0_8-whitegrid" if "seaborn-v0_8-whitegrid" in plt.style.available else "default")
plt.rcParams.update({
    "font.size": 11,
    "axes.labelsize": 12,
    "axes.titlesize": 13,
    "xtick.labelsize": 10,
    "ytick.labelsize": 10,
    "legend.fontsize": 10,
    "figure.titlesize": 14,
    "figure.dpi": 300
})

def plot_pnl_comparison(results_df: pd.DataFrame, output_path: str) -> None:
    """Creates a multi-panel boxplot comparing Net PnL vs Hold across market regimes."""
    regimes = results_df["regime"].unique()
    strategies = [
        "Baseline A (Swap ALM)",
        "Passive Wide LP",
        "RangeFit (Swapless)",
        "RangeFit + Fee Skew"
    ]
    colors = ["#e74c3c", "#95a5a6", "#2ecc71", "#3498db"]

    fig, axes = plt.subplots(1, len(regimes), figsize=(18, 5), sharey=True)
    if len(regimes) == 1:
        axes = [axes]

    for ax, regime in zip(axes, regimes):
        regime_data = results_df[results_df["regime"] == regime]
        plot_data = [
            regime_data[regime_data["strategy"] == strat]["pnl_vs_hold_pct"].dropna()
            for strat in strategies
        ]

        bplot = ax.boxplot(
            plot_data,
            patch_artist=True,
            medianprops=dict(color="black", linewidth=1.5),
            widths=0.6
        )

        for patch, color in zip(bplot['boxes'], colors):
            patch.set_facecolor(color)
            patch.set_alpha(0.7)

        ax.axhline(0, color="gray", linestyle="--", linewidth=0.8, alpha=0.7)
        ax.set_title(regime.replace("_", " "), fontweight="bold")
        ax.set_xticklabels(["Baseline", "Passive", "RangeFit", "RF+Skew"], rotation=20)
        ax.set_xlabel("")

    axes[0].set_ylabel("Net PnL vs. Hold (%)", fontweight="bold")
    fig.suptitle("Strategy Performance Benchmark Across Market Regimes (Net PnL vs. Hold)", fontweight="bold", y=1.02)
    fig.tight_layout()
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    fig.savefig(output_path, bbox_inches="tight")
    plt.close(fig)

def plot_cumulative_economics(
    baseline_strat,
    rangefit_strat,
    output_path: str
) -> None:
    """Plots cumulative fees earned vs rebalancing costs (swaps + gas) over time."""
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5))

    steps = np.arange(len(baseline_strat.history_portfolio_value))
    hours = steps # 1 step = 1 hour

    # Panel 1: Portfolio Values
    ax1.plot(hours, baseline_strat.history_portfolio_value, label="Baseline A (Swap ALM)", color="#e74c3c", linewidth=1.8)
    ax1.plot(hours, rangefit_strat.history_portfolio_value, label="RangeFit (Swapless)", color="#2ecc71", linewidth=1.8)
    ax1.set_title("Portfolio Valuation Over Time", fontweight="bold")
    ax1.set_xlabel("Time (Hours)")
    ax1.set_ylabel("Portfolio Value ($)")
    ax1.legend(loc="best")

    # Panel 2: Rebalancing Overhead (Swap Cost + Gas)
    cum_costs_baseline = baseline_strat.cumulative_swap_cost_usd + baseline_strat.cumulative_gas_cost_usd
    cum_costs_rangefit = rangefit_strat.cumulative_swap_cost_usd + rangefit_strat.cumulative_gas_cost_usd

    bar_labels = ["Baseline A", "RangeFit"]
    swap_costs = [baseline_strat.cumulative_swap_cost_usd, rangefit_strat.cumulative_swap_cost_usd]
    gas_costs = [baseline_strat.cumulative_gas_cost_usd, rangefit_strat.cumulative_gas_cost_usd]

    ax2.bar(bar_labels, swap_costs, label="Swap Fees & Slippage", color="#e74c3c", alpha=0.85, width=0.5)
    ax2.bar(bar_labels, gas_costs, bottom=swap_costs, label="Gas Overhead", color="#f39c12", alpha=0.85, width=0.5)
    ax2.set_title("Cumulative Rebalancing Costs (USD)", fontweight="bold")
    ax2.set_ylabel("Cost Incurred ($)")
    ax2.legend(loc="upper right")

    fig.suptitle("Comparative Economics: RangeFit Swapless vs Traditional ALM Swapping", fontweight="bold", y=1.02)
    fig.tight_layout()
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    fig.savefig(output_path, bbox_inches="tight")
    plt.close(fig)

def plot_price_and_asymmetric_range(
    rangefit_strat,
    output_path: str
) -> None:
    """Plots a price trajectory with dynamic asymmetric RangeFit boundaries."""
    fig, ax = plt.subplots(figsize=(12, 5))

    hours = np.arange(len(rangefit_strat.history_spot_price))
    prices = np.array(rangefit_strat.history_spot_price)
    lowers = np.array(rangefit_strat.history_range_lower)
    uppers = np.array(rangefit_strat.history_range_upper)

    ax.plot(hours, prices, label="Spot Price (ETH/USDC)", color="#2c3e50", linewidth=1.8, zorder=4)
    ax.fill_between(hours, lowers, uppers, color="#2ecc71", alpha=0.25, label="RangeFit Active Bounds [u, v]", zorder=2)
    ax.plot(hours, lowers, color="#27ae60", linestyle="--", linewidth=1.0, alpha=0.8, zorder=3)
    ax.plot(hours, uppers, color="#27ae60", linestyle="--", linewidth=1.0, alpha=0.8, zorder=3)

    ax.set_title("RangeFit Dynamic Asymmetric Range Morphing Without Swapping", fontweight="bold")
    ax.set_xlabel("Time (Hours)")
    ax.set_ylabel("Price ($)")
    ax.legend(loc="best")

    fig.tight_layout()
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    fig.savefig(output_path, bbox_inches="tight")
    plt.close(fig)
