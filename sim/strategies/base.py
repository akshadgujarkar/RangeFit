"""Base Strategy class defining common portfolio state and lifecycle methods."""

import math
from typing import Dict, Any
from ..models.pool import PoolEnvironment
from ..models.math_core import get_amounts_for_liquidity

class BaseStrategy:
    def __init__(
        self,
        name: str,
        initial_eth: float,
        initial_usdc: float,
        initial_price: float
    ):
        self.name = name
        self.initial_eth = initial_eth
        self.initial_usdc = initial_usdc
        self.initial_price = initial_price

        # Portfolio assets
        self.idle_eth = initial_eth
        self.idle_usdc = initial_usdc
        self.position_liquidity = 0.0
        self.tick_lower = 0
        self.tick_upper = 0
        self.sqrt_lower = 0.0
        self.sqrt_upper = 0.0

        # Performance & accounting trackers
        self.lifetime_fees_earned_usd = 0.0
        self.unreinvested_fees_usd = 0.0
        self.cumulative_fees_usd = 0.0 # Kept for backward compatibility
        self.cumulative_gas_cost_usd = 0.0
        self.cumulative_swap_cost_usd = 0.0
        self.rebalance_count = 0
        self.time_in_range_steps = 0
        self.total_steps = 0
        self.last_rebalance_step = -999

        # Value history
        self.history_portfolio_value: list[float] = []
        self.history_spot_price: list[float] = []
        self.history_range_lower: list[float] = []
        self.history_range_upper: list[float] = []

    def get_portfolio_value(self, spot_price: float) -> float:
        """Computes total mark-to-market valuation across position, idle, and accrued fees."""
        curr_sqrt = math.sqrt(spot_price)
        pos_eth, pos_usdc = get_amounts_for_liquidity(
            curr_sqrt, self.sqrt_lower, self.sqrt_upper, self.position_liquidity
        )
        total_eth = pos_eth + self.idle_eth
        total_usdc = pos_usdc + self.idle_usdc + self.unreinvested_fees_usd
        return total_eth * spot_price + total_usdc

    def is_in_range(self, spot_price: float) -> bool:
        """Returns True if spot price is strictly inside the active range."""
        curr_sqrt = math.sqrt(spot_price)
        return self.sqrt_lower <= curr_sqrt <= self.sqrt_upper

    def step(
        self,
        spot_price: float,
        prev_price: float,
        pool_env: PoolEnvironment,
        dt_days: float,
        step_idx: int
    ) -> None:
        """Abstract step method executed on each time step."""
        raise NotImplementedError
