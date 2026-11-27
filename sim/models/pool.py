"""Uniswap v4 pool environment modeling:
- Concentrated liquidity depth & background market liquidity
- Volume generation per time step
- Fee accrual proportional to liquidity share
- Slippage & fee execution model for Baseline A swaps
- Gas overhead calculation from Foundry benchmarks
"""

import math
from typing import Tuple

class PoolEnvironment:
    def __init__(
        self,
        base_fee_rate: float = 0.0005, # 0.05%
        background_liquidity_depth: float = 5_000_000.0, # $5M TVL background
        daily_volume_to_depth_ratio: float = 0.20,
        gas_price_gwei: float = 25.0
    ):
        self.base_fee_rate = base_fee_rate
        self.background_depth = background_liquidity_depth
        self.daily_vol_ratio = daily_volume_to_depth_ratio
        self.gas_price_gwei = gas_price_gwei

    def compute_step_volume(self, prev_price: float, curr_price: float, dt_days: float) -> float:
        """
        Calculates swap volume generated during step dt.
        Volume is driven by base churn plus volatility:
          V = (base_daily_turnover * dt + vol_multiplier * |dP / P|) * background_depth
        """
        price_return = abs(curr_price - prev_price) / prev_price if prev_price > 0 else 0.0
        base_volume = self.background_depth * (self.daily_vol_ratio * dt_days)
        vol_driven_volume = self.background_depth * (price_return * 0.8)
        return base_volume + vol_driven_volume

    def compute_fee_income(
        self,
        step_volume: float,
        position_liquidity: float,
        spot_price: float,
        lower_sqrt: float,
        upper_sqrt: float,
        fee_rate: float
    ) -> float:
        """
        Calculates fee earned by an active position in dollar value ($).
        Fee is earned ONLY if spot price is strictly inside [lower, upper].
        """
        curr_sqrt = math.sqrt(spot_price)
        if curr_sqrt < lower_sqrt or curr_sqrt > upper_sqrt or position_liquidity <= 0:
            return 0.0

        # Background liquidity in concentrated L units
        # Depth D = 2 * L * sqrt(P) => L_bg = D / (2 * sqrt(P))
        l_bg = self.background_depth / (2.0 * curr_sqrt) if curr_sqrt > 0 else 1.0
        pool_share = position_liquidity / (position_liquidity + l_bg)

        # Total fee generated across pool
        total_pool_fee = step_volume * fee_rate
        return total_pool_fee * pool_share

    def execute_baseline_swap(
        self,
        swap_amount_usd: float,
        spot_price: float
    ) -> Tuple[float, float]:
        """
        Executes a rebalancing swap for Baseline A.
        Returns:
          (fee_paid_usd, slippage_loss_usd)
        Slippage model: quadratic price impact based on trade size relative to pool depth:
          Price Impact = swap_amount / (2 * background_depth)
          Slippage Loss = swap_amount * Price Impact
        """
        if swap_amount_usd <= 0:
            return 0.0, 0.0

        fee_paid = swap_amount_usd * self.base_fee_rate
        price_impact = swap_amount_usd / (2.0 * self.background_depth)
        slippage_loss = swap_amount_usd * price_impact

        return fee_paid, slippage_loss

    def compute_gas_cost_usd(self, gas_units: int, eth_price: float) -> float:
        """Calculates USD cost of a rebalance transaction."""
        eth_gas_cost = (gas_units * self.gas_price_gwei * 1e-9)
        return eth_gas_cost * eth_price
