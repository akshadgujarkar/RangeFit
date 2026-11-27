"""Price path generation across 5 distinct market regimes:
1. Geometric Brownian Motion (GBM) at various volatilities
2. Mean-Reverting Ornstein-Uhlenbeck
3. Trending Bull & Bear
4. Jump Diffusion (Merton Model)
5. Historical Volatility Series
"""

import numpy as np
from typing import Dict

def generate_gbm_paths(
    s0: float,
    mu: float,
    sigma: float,
    days: int,
    steps_per_day: int,
    num_paths: int,
    seed: int = 42
) -> np.ndarray:
    """Generates paths following Geometric Brownian Motion."""
    rng = np.random.default_rng(seed)
    dt = 1.0 / (365.0 * steps_per_day)
    total_steps = days * steps_per_day

    # Standard normal increments
    z = rng.standard_normal((num_paths, total_steps))
    drift = (mu - 0.5 * sigma**2) * dt
    diffusion = sigma * np.sqrt(dt) * z
    log_returns = drift + diffusion

    # Accumulate log returns
    log_paths = np.zeros((num_paths, total_steps + 1))
    log_paths[:, 0] = np.log(s0)
    log_paths[:, 1:] = np.log(s0) + np.cumsum(log_returns, axis=1)

    return np.exp(log_paths)

def generate_mean_reverting_paths(
    s0: float,
    theta: float, # Mean reversion speed (e.g. 5.0 annual)
    mu_price: float, # Long-term equilibrium price
    sigma: float, # Volatility
    days: int,
    steps_per_day: int,
    num_paths: int,
    seed: int = 42
) -> np.ndarray:
    """Generates paths following an Ornstein-Uhlenbeck process on log price."""
    rng = np.random.default_rng(seed)
    dt = 1.0 / (365.0 * steps_per_day)
    total_steps = days * steps_per_day

    paths = np.zeros((num_paths, total_steps + 1))
    paths[:, 0] = np.log(s0)
    target_log_s = np.log(mu_price)

    for t in range(total_steps):
        current_log_s = paths[:, t]
        z = rng.standard_normal(num_paths)
        d_log_s = theta * (target_log_s - current_log_s) * dt + sigma * np.sqrt(dt) * z
        paths[:, t + 1] = current_log_s + d_log_s

    return np.exp(paths)

def generate_jump_diffusion_paths(
    s0: float,
    mu: float,
    sigma: float,
    jump_lambda: float, # Expected jumps per year (e.g. 12 = once per month)
    jump_mean: float,   # Mean jump size (e.g. -0.10 = -10% average jump)
    jump_std: float,    # Jump size dispersion
    days: int,
    steps_per_day: int,
    num_paths: int,
    seed: int = 42
) -> np.ndarray:
    """Generates paths following Merton's Jump Diffusion model."""
    rng = np.random.default_rng(seed)
    dt = 1.0 / (365.0 * steps_per_day)
    total_steps = days * steps_per_day

    # Standard diffusion
    z = rng.standard_normal((num_paths, total_steps))
    drift = (mu - 0.5 * sigma**2) * dt
    diffusion = sigma * np.sqrt(dt) * z

    # Poisson jump events
    poisson_p = jump_lambda * dt
    jump_occurrences = rng.poisson(poisson_p, size=(num_paths, total_steps))
    jump_magnitudes = rng.normal(jump_mean, jump_std, size=(num_paths, total_steps)) * jump_occurrences

    log_returns = drift + diffusion + jump_magnitudes

    log_paths = np.zeros((num_paths, total_steps + 1))
    log_paths[:, 0] = np.log(s0)
    log_paths[:, 1:] = np.log(s0) + np.cumsum(log_returns, axis=1)

    return np.exp(log_paths)

def generate_all_regime_paths(
    s0: float,
    days: int,
    steps_per_day: int,
    num_paths: int,
    base_seed: int = 42
) -> Dict[str, np.ndarray]:
    """
    Generates scenario matrix covering 5 distinct market regimes:
    1. GBM Low Volatility (30% annual)
    2. GBM High Volatility (80% annual)
    3. Mean-Reverting (Ornstein-Uhlenbeck)
    4. Strong Trending (Drifted +/- 50%)
    5. Jump Diffusion (Flash Crashes / Liquidity shocks)
    """
    regimes = {}

    # 1. GBM Low Vol (30% vol, 0% drift)
    regimes["GBM_Low_Vol"] = generate_gbm_paths(
        s0=s0, mu=0.0, sigma=0.30, days=days,
        steps_per_day=steps_per_day, num_paths=num_paths, seed=base_seed + 1
    )

    # 2. GBM High Vol (80% vol, 0% drift)
    regimes["GBM_High_Vol"] = generate_gbm_paths(
        s0=s0, mu=0.0, sigma=0.80, days=days,
        steps_per_day=steps_per_day, num_paths=num_paths, seed=base_seed + 2
    )

    # 3. Mean Reversion (Sideways oscillating, theta=8.0, 50% vol)
    regimes["Mean_Reverting"] = generate_mean_reverting_paths(
        s0=s0, theta=8.0, mu_price=s0, sigma=0.50, days=days,
        steps_per_day=steps_per_day, num_paths=num_paths, seed=base_seed + 3
    )

    # 4. Trending Bull (drift +50%, 45% vol)
    regimes["Trending_Bull"] = generate_gbm_paths(
        s0=s0, mu=0.50, sigma=0.45, days=days,
        steps_per_day=steps_per_day, num_paths=num_paths, seed=base_seed + 4
    )

    # 5. Jump Diffusion (Flash crashes: 15 jumps/year, avg -12% shock)
    regimes["Jump_Diffusion"] = generate_jump_diffusion_paths(
        s0=s0, mu=0.05, sigma=0.50, jump_lambda=15.0, jump_mean=-0.12,
        jump_std=0.08, days=days, steps_per_day=steps_per_day,
        num_paths=num_paths, seed=base_seed + 5
    )

    return regimes
