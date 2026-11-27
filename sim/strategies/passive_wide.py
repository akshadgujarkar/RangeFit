"""Passive Wide LP Strategy:
Deploys across a static wide range [0.5 * S_0, 2.0 * S_0] at genesis and never rebalances.
Serves as the passive control benchmark.
"""

import math
from .base import BaseStrategy
from ..models.pool import PoolEnvironment
from ..models.math_core import (
    sqrt_price_to_tick,
    compute_range_usage_and_dust,
    tick_to_sqrt_price
)

class PassiveWideStrategy(BaseStrategy):
    def __init__(
        self,
        initial_eth: float,
        initial_usdc: float,
        initial_price: float,
        lower_multiplier: float = 0.50,
        upper_multiplier: float = 2.00
    ):
        super().__init__("Passive Wide LP", initial_eth, initial_usdc, initial_price)
        
        # Deploy wide static range
        s0 = math.sqrt(initial_price)
        p_lower = initial_price * lower_multiplier
        p_upper = initial_price * upper_multiplier
        
        self.sqrt_lower = math.sqrt(p_lower)
        self.sqrt_upper = math.sqrt(p_upper)
        self.tick_lower = sqrt_price_to_tick(self.sqrt_lower)
        self.tick_upper = sqrt_price_to_tick(self.sqrt_upper)
        self.sqrt_lower = tick_to_sqrt_price(self.tick_lower)
        self.sqrt_upper = tick_to_sqrt_price(self.tick_upper)

        usage = compute_range_usage_and_dust(
            s0, self.sqrt_lower, self.sqrt_upper, initial_eth, initial_usdc
        )
        self.position_liquidity = usage.liquidity
        self.idle_eth = usage.dust0
        self.idle_usdc = usage.dust1

    def step(
        self,
        spot_price: float,
        prev_price: float,
        pool_env: PoolEnvironment,
        dt_days: float,
        step_idx: int
    ) -> None:
        self.total_steps += 1
        in_range = self.is_in_range(spot_price)
        if in_range:
            self.time_in_range_steps += 1

        # Accrue fees if in range
        step_vol = pool_env.compute_step_volume(prev_price, spot_price, dt_days)
        fee = pool_env.compute_fee_income(
            step_vol, self.position_liquidity, spot_price,
            self.sqrt_lower, self.sqrt_upper, pool_env.base_fee_rate
        )
        self.lifetime_fees_earned_usd += fee
        self.unreinvested_fees_usd += fee
        self.cumulative_fees_usd += fee

        # Log history
        self.history_portfolio_value.append(self.get_portfolio_value(spot_price))
        self.history_spot_price.append(spot_price)
        self.history_range_lower.append(self.sqrt_lower**2)
        self.history_range_upper.append(self.sqrt_upper**2)
