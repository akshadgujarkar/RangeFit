"""Baseline A (Traditional ALM Strategy):
When price approaches boundary or exits range:
1. Withdraws existing position to idle.
2. Centers a symmetric range around current spot price.
3. Swaps tokens to achieve the exact required ratio (paying swap fee + slippage).
4. Deploys new symmetric position, paying baseline gas overhead (~350k gas).
"""

import math
from .base import BaseStrategy
from ..models.pool import PoolEnvironment
from ..models.math_core import (
    sqrt_price_to_tick,
    tick_to_sqrt_price,
    align_tick,
    get_amounts_for_liquidity,
    compute_range_usage_and_dust
)

class BaselineALMStrategy(BaseStrategy):
    def __init__(
        self,
        initial_eth: float,
        initial_usdc: float,
        initial_price: float,
        target_width_ticks: int = 240,
        edge_threshold_percent: float = 0.20,
        cooldown_steps: int = 4,
        tick_spacing: int = 60
    ):
        super().__init__("Baseline A (Swap ALM)", initial_eth, initial_usdc, initial_price)
        self.target_width_ticks = target_width_ticks
        self.edge_threshold_percent = edge_threshold_percent
        self.cooldown_steps = cooldown_steps
        self.tick_spacing = tick_spacing

        # Deploy initial symmetric position at genesis
        self._rebalance(initial_price, PoolEnvironment(), step_idx=0, is_initial=True)

    def _should_rebalance(self, spot_price: float, step_idx: int) -> bool:
        if step_idx - self.last_rebalance_step < self.cooldown_steps:
            return False

        curr_sqrt = math.sqrt(spot_price)
        if curr_sqrt <= self.sqrt_lower or curr_sqrt >= self.sqrt_upper:
            return True # Out of range

        # Boundary proximity check
        width_ticks = self.tick_upper - self.tick_lower
        edge_ticks = math.floor(width_ticks * self.edge_threshold_percent)
        curr_tick = sqrt_price_to_tick(curr_sqrt)

        return (curr_tick <= self.tick_lower + edge_ticks) or (curr_tick >= self.tick_upper - edge_ticks)

    def _rebalance(
        self,
        spot_price: float,
        pool_env: PoolEnvironment,
        step_idx: int,
        is_initial: bool = False
    ) -> None:
        curr_sqrt = math.sqrt(spot_price)

        # 1. Withdraw active position into inventory (compounding fees)
        if not is_initial:
            pos_eth, pos_usdc = get_amounts_for_liquidity(
                curr_sqrt, self.sqrt_lower, self.sqrt_upper, self.position_liquidity
            )
            self.idle_eth += pos_eth
            self.idle_usdc += pos_usdc + self.unreinvested_fees_usd
            self.unreinvested_fees_usd = 0.0 # Reinvested
            self.position_liquidity = 0.0

        # 2. Derive new symmetric range centered around spot tick
        curr_tick = sqrt_price_to_tick(curr_sqrt)
        half_width = self.target_width_ticks // 2
        new_lower_tick = align_tick(curr_tick - half_width, self.tick_spacing, "floor")
        new_upper_tick = new_lower_tick + self.target_width_ticks

        sqrt_lower = tick_to_sqrt_price(new_lower_tick)
        sqrt_upper = tick_to_sqrt_price(new_upper_tick)

        # 3. Compute required ratio to deploy 100% of capital symmetrically
        # At spot price s in range [u, v], required ratio Y / X = s * (s - u) / (1 - s/v)
        # Ratio of USD values: Val_ETH : Val_USDC
        weight_x = (sqrt_upper - curr_sqrt) / (curr_sqrt * sqrt_upper)
        weight_y = (curr_sqrt - sqrt_lower)
        target_val_ratio_0 = (weight_x * spot_price) / ((weight_x * spot_price) + weight_y)

        total_value_usd = self.idle_eth * spot_price + self.idle_usdc
        desired_val0 = total_value_usd * target_val_ratio_0
        desired_eth = desired_val0 / spot_price
        desired_usdc = total_value_usd - desired_val0

        # 4. Execute swap to match ratio
        if not is_initial:
            if self.idle_eth > desired_eth:
                # Sell excess ETH for USDC
                excess_eth = self.idle_eth - desired_eth
                swap_usd = excess_eth * spot_price
                fee_paid, slippage = pool_env.execute_baseline_swap(swap_usd, spot_price)
                self.idle_eth -= excess_eth
                self.idle_usdc += (swap_usd - fee_paid - slippage)
                swap_cost = fee_paid + slippage
            elif self.idle_usdc > desired_usdc:
                # Sell excess USDC for ETH
                excess_usdc = self.idle_usdc - desired_usdc
                swap_usd = excess_usdc
                fee_paid, slippage = pool_env.execute_baseline_swap(swap_usd, spot_price)
                self.idle_usdc -= excess_usdc
                self.idle_eth += (swap_usd - fee_paid - slippage) / spot_price
                swap_cost = fee_paid + slippage
            else:
                swap_cost = 0.0

            self.cumulative_swap_cost_usd += swap_cost
            gas_cost = pool_env.compute_gas_cost_usd(350_000, spot_price)
            self.cumulative_gas_cost_usd += gas_cost
            self.idle_usdc = max(0.0, self.idle_usdc - gas_cost)
            self.rebalance_count += 1
            self.last_rebalance_step = step_idx

        # 5. Deploy symmetric position
        usage = compute_range_usage_and_dust(
            curr_sqrt, sqrt_lower, sqrt_upper, self.idle_eth, self.idle_usdc
        )
        self.tick_lower = new_lower_tick
        self.tick_upper = new_upper_tick
        self.sqrt_lower = sqrt_lower
        self.sqrt_upper = sqrt_upper
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

        # Check rebalance condition
        if self._should_rebalance(spot_price, step_idx):
            self._rebalance(spot_price, pool_env, step_idx)

        in_range = self.is_in_range(spot_price)
        if in_range:
            self.time_in_range_steps += 1

        # Accrue fee
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
