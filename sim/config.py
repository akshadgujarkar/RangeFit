"""Configuration and parameters for the RangeFit simulation benchmark suite."""

from dataclasses import dataclass

@dataclass
class SimConfig:
    # Asset parameters
    initial_eth_price: float = 2500.0   # $2,500 USDC per ETH
    initial_eth_amount: float = 100.0   # 100 ETH
    initial_usdc_amount: float = 250000.0 # 250,000 USDC ($500k total initial capital)

    # Pool & Protocol parameters
    base_fee_rate: float = 0.0005       # 0.05% fee tier (5 bps)
    tick_spacing: int = 60              # Uniswap v4 60 tick spacing
    background_liquidity_depth: float = 5_000_000.0 # $5M background depth for slippage modeling
    daily_volume_to_depth_ratio: float = 0.20 # 20% daily turnover on background liquidity

    # Simulation time parameters
    time_horizon_days: int = 30         # 30-day simulation
    steps_per_day: int = 24             # Hourly discrete steps (720 steps total)
    num_paths_per_regime: int = 200     # 200 Monte Carlo paths per market regime
    random_seed: int = 42               # Fixed seed for statistical reproducibility

    # Strategy Rebalancing thresholds
    edge_threshold_percent: float = 0.20 # Rebalance when spot is within 20% of range edge
    target_width_ticks: int = 240       # Standard ~2.4% range width (240 ticks)
    cooldown_steps: int = 4             # 4-hour cooldown between consecutive rebalances
    max_deviation_bps: int = 1000       # 10% maximum spot-to-EMA deviation band
    ema_alpha: float = 0.10             # EMA smoothing parameter

    # Gas economics (measured from Foundry traces)
    eth_gas_price_gwei: float = 25.0
    gas_rangefit_rebalance: int = 234_000 # Gas units from Foundry
    gas_baseline_rebalance: int = 350_000 # Rebalance + Router swap execution

    # Fee Skew parameters
    min_fee_rate: float = 0.0001        # 0.01% min clamped fee
    max_fee_rate: float = 0.0020        # 0.20% max clamped fee
    fee_skew_sensitivity: float = 0.50  # Sensitivity factor for directional fee skew

DEFAULT_CONFIG = SimConfig()
