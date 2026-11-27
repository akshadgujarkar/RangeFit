"""RangeFit Core Strategy:
Swapless concentrated liquidity automated re-ranging.
When price approaches boundary or exits range:
1. Withdraws active position into inventory (compounding fees).
2. Analytically solves for the unique asymmetric range [u, v] that fits current inventory (X, Y).
3. Zero swaps executed -> strictly 0 swap fees and 0 slippage.
4. Gas overhead grounded in Foundry benchmark (234,000 gas units).
"""

import math
from .base import BaseStrategy
from ..models.pool import PoolEnvironment
from ..models.math_core import (
    sqrt_price_to_tick,
    tick_to_sqrt_price,
    align_tick,
    get_amounts_for_liquidity,
    search_neighbor_ticks
)

class RangeFitCoreStrategy(BaseStrategy):
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
        max_deviation_bps: int = 1000
    ):
        super().__init__("RangeFit (Swapless)", initial_eth, initial_usdc, initial_price)
        self.target_width_ticks = target_width_ticks
        self.edge_threshold_percent = edge_threshold_percent
        self.cooldown_steps = cooldown_steps
        self.tick_spacing = tick_spacing
        self.ema_alpha = ema_alpha
        self.max_deviation_bps = max_deviation_bps

        # EMA tracker
        self.ema_sqrt_price = math.sqrt(initial_price)

        # Deploy initial position at genesis
        self._rebalance(initial_price, PoolEnvironment(), step_idx=0, is_initial=True)

    def _update_ema(self, spot_sqrt: float) -> None:
        self.ema_sqrt_price = (1.0 - self.ema_alpha) * self.ema_sqrt_price + self.ema_alpha * spot_sqrt

    def _should_rebalance(self, spot_price: float, step_idx: int) -> bool:
        if step_idx - self.last_rebalance_step < self.cooldown_steps:
            return False

        curr_sqrt = math.sqrt(spot_price)

        # Check deviation guard against smoothed EMA
        dev_bps = abs(curr_sqrt - self.ema_sqrt_price) / self.ema_sqrt_price * 10000.0
        if dev_bps > self.max_deviation_bps:
            return False # Guard blocks rebalance during flash crash/spike

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

        # 2. Derive target lower tick based on target width
        curr_tick = sqrt_price_to_tick(curr_sqrt)
        half_width = self.target_width_ticks // 2
        target_lower_tick = align_tick(curr_tick - half_width, self.tick_spacing, "floor")

        # 3. Analytically solve for optimal asymmetric bounds fitting current inventory
        solved = search_neighbor_ticks(
            s=curr_sqrt,
            target_lower_tick=target_lower_tick,
            x=self.idle_eth,
            y=self.idle_usdc,
            tick_spacing=self.tick_spacing,
            radius=4,
            min_width_ticks=60,
            max_width_ticks=3000
        )

        if solved is None:
            # Infeasible fallback: keep capital idle until price returns
            return

        # 4. Deploy swapless position
        self.tick_lower = solved.tick_lower
        self.tick_upper = solved.tick_upper
        self.sqrt_lower = solved.sqrt_lower
        self.sqrt_upper = solved.sqrt_upper
        self.position_liquidity = solved.liquidity
        self.idle_eth = solved.dust0
        self.idle_usdc = solved.dust1

        if not is_initial:
            gas_cost = pool_env.compute_gas_cost_usd(234_000, spot_price)
            self.cumulative_gas_cost_usd += gas_cost
            self.idle_usdc = max(0.0, self.idle_usdc - gas_cost)
            self.rebalance_count += 1
            self.last_rebalance_step = step_idx

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
