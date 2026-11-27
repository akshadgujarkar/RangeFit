"""RangeFit + Dynamic Directional Fee Skew Strategy:
Combines RangeFit swapless re-ranging with Uniswap v4 dynamic directional LP fees:
- When vault is overweight token0 (ETH), swaps adding ETH pay higher fees (penalizing worsening flow).
- Swaps taking ETH pay discounted fees (incentivizing rebalancing flow).
- Fee adjustment captures higher yield during trending market runs.
"""

import math
from .rangefit_core import RangeFitCoreStrategy
from ..models.pool import PoolEnvironment
from ..models.math_core import get_amounts_for_liquidity

class RangeFitFeeSkewStrategy(RangeFitCoreStrategy):
    def __init__(
        self,
        initial_eth: float,
        initial_usdc: float,
        initial_price: float,
        target_width_ticks: int = 240,
        edge_threshold_percent: float = 0.20,
        cooldown_steps: int = 4,
        tick_spacing: int = 60,
        ema_alpha: float = 0.10,
        max_deviation_bps: int = 1000,
        fee_sensitivity: float = 0.50,
        min_fee_rate: float = 0.0001,
        max_fee_rate: float = 0.0020
    ):
        super().__init__(
            initial_eth=initial_eth,
            initial_usdc=initial_usdc,
            initial_price=initial_price,
            target_width_ticks=target_width_ticks,
            edge_threshold_percent=edge_threshold_percent,
            cooldown_steps=cooldown_steps,
            tick_spacing=tick_spacing,
            ema_alpha=ema_alpha,
            max_deviation_bps=max_deviation_bps
        )
        self.name = "RangeFit + Fee Skew"
        self.fee_sensitivity = fee_sensitivity
        self.min_fee_rate = min_fee_rate
        self.max_fee_rate = max_fee_rate

    def _compute_effective_fee_rate(self, spot_price: float, base_fee_rate: float) -> float:
        """
        Dynamically adjusts fee based on current portfolio inventory skew:
          skew = |val0 / total_val - 0.50|
          effective_fee = base_fee * (1.0 + sensitivity * skew * 2.0)
        Clamped to [min_fee_rate, max_fee_rate].
        """
        curr_sqrt = math.sqrt(spot_price)
        pos_eth, pos_usdc = get_amounts_for_liquidity(
            curr_sqrt, self.sqrt_lower, self.sqrt_upper, self.position_liquidity
        )
        total_eth = pos_eth + self.idle_eth
        total_usdc = pos_usdc + self.idle_usdc

        val0 = total_eth * spot_price
        total_val = val0 + total_usdc
        if total_val <= 0:
            return base_fee_rate

        ratio0 = val0 / total_val
        skew = abs(ratio0 - 0.50) # Degree of inventory imbalance [0, 0.50]

        # Higher fee captured from traders trading in the dominant flow direction
        fee_mult = 1.0 + (skew * 2.0 * self.fee_sensitivity)
        adj_fee = base_fee_rate * fee_mult
        return max(self.min_fee_rate, min(self.max_fee_rate, adj_fee))

    def step(
        self,
        spot_price: float,
        prev_price: float,
        pool_env: PoolEnvironment,
        dt_days: float,
        step_idx: int
    ) -> None:
        self.total_steps += 1
        curr_sqrt = math.sqrt(spot_price)
        self._update_ema(curr_sqrt)

        # Check rebalance condition
        if self._should_rebalance(spot_price, step_idx):
            self._rebalance(spot_price, pool_env, step_idx)

        in_range = self.is_in_range(spot_price)
        if in_range:
            self.time_in_range_steps += 1

        # Dynamic fee calculation
        effective_fee_rate = self._compute_effective_fee_rate(spot_price, pool_env.base_fee_rate)

        # Accrue fee at dynamic rate
        step_vol = pool_env.compute_step_volume(prev_price, spot_price, dt_days)
        fee = pool_env.compute_fee_income(
            step_vol, self.position_liquidity, spot_price,
            self.sqrt_lower, self.sqrt_upper, effective_fee_rate
        )
        self.lifetime_fees_earned_usd += fee
        self.unreinvested_fees_usd += fee
        self.cumulative_fees_usd += fee

        # Log history
        self.history_portfolio_value.append(self.get_portfolio_value(spot_price))
        self.history_spot_price.append(spot_price)
        self.history_range_lower.append(self.sqrt_lower**2)
        self.history_range_upper.append(self.sqrt_upper**2)
