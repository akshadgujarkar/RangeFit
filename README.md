# RangeFit

**Swapless Concentrated Liquidity Re-Ranging on Uniswap v4**

RangeFit is an automated liquidity vault and Uniswap v4 hook that re-ranges concentrated liquidity positions **without executing token swaps**. By mathematically solving for the unique price range that fits current token inventory, RangeFit eliminates the swap fees, price impact, and loss-versus-rebalancing (LVR) that erode yields in traditional active LP strategies.

---

## The Problem: The "Swap Tax" of Active Liquidity Management

Concentrated liquidity (introduced in Uniswap v3 and expanded in Uniswap v4) allows liquidity providers (LPs) to allocate capital within customized price intervals $[p_a, p_b]$. This dramatically increases capital efficiency, but introduces a major operational challenge:

1. **Inventory Skew Out of Range:** When the market price exits the active range $[p_a, p_b]$, the position stops earning trading fees, and 100% of the capital is converted into the depreciating asset.
2. **Forced Rebalance Swaps:** To establish a new active range around the new market price, traditional automated liquidity managers (ALMs) force a swap of the excess token into the depleted token to match the required ratio of the target range.
3. **Yield Destruction:** Every rebalance swap incurs:
   - **Pool Trading Fees:** 0.05% to 0.30%+ paid directly to pool LPs.
   - **Price Impact & Slippage:** Losses from moving the pool price against the vault's own order.
   - **MEV / LVR (Loss-Versus-Rebalancing):** Arbitrageurs extract value before and after large rebalance swaps.

In volatile markets, active liquidity managers can rebalance dozens of times per week. The cumulative cost of these swaps often exceeds the fee income earned, leaving passive hold strategies more profitable than active management.

---

## The Solution: Swapless Inventory Fitting

RangeFit reverses the traditional paradigm:

$$\text{Traditional ALMs: Fix target range } [p_a, p_b] \longrightarrow \textbf{Swap} \text{ tokens to match ratio } X : Y$$

$$\textbf{RangeFit: } \text{Keep existing inventory } (X, Y) \longrightarrow \textbf{Solve} \text{ for the unique range } [p_a, p_b] \text{ that fits it}$$

By treating the token inventory $(X, Y)$ and current spot price $s$ as fixed inputs, RangeFit analytically solves for the asymmetric price boundaries $[p_a, p_b]$ that absorb the vault's assets with near-zero leftover dust—**executing zero swaps in the process**.

---

## Mathematical Formulation

In Uniswap concentrated liquidity, the relationship between liquidity $L$, spot price $s$, price bounds $[\sqrt{p_a}, \sqrt{p_b}]$, token0 amount $X$, and token1 amount $Y$ is defined by:

$$X = L \left( \frac{\sqrt{p_b} - \sqrt{s}}{\sqrt{s} \sqrt{p_b}} \right), \quad Y = L (\sqrt{s} - \sqrt{p_a})$$

Dividing $X$ by $Y$ yields the inventory ratio:

$$\frac{X}{Y} = \frac{\sqrt{p_b} - \sqrt{s}}{\sqrt{s} \sqrt{p_b} (\sqrt{s} - \sqrt{p_a})}$$

Let $u = \sqrt{p_a}$ (the lower boundary chosen based on desired range width) and $v = \sqrt{p_b}$ (the unknown upper boundary). Solving analytically for $v$:

$$v = \frac{s \cdot X}{X - \frac{Y}{s - u}}$$

### Feasibility Conditions
A valid concentrated liquidity position exists if and only if:
1. $u < s$ (lower boundary strictly below spot price)
2. $(s - u) \cdot X < Y$ (denominator remains strictly positive)

When feasible, this analytical solution uniquely determines the upper price bound $v$ that perfectly absorbs the vault's $(X, Y)$ inventory without needing numerical approximations or external solver iterations.

---

## Core System Architecture

RangeFit implements the Uniswap v4 **Hook-as-LP** architecture, unifying the vault and hook into a single smart contract.

```
+-----------------------------------------------------------------------------------------+
|                                      RangeFitHook                                       |
|                                                                                         |
|  [User Deposits & Withdrawals]                                                          |
|    - Any-ratio deposits into idle reserves (single-sided or mixed)                      |
|    - ERC-4626 style fair valuation share minting at smoothed EMA price                  |
|    - Anti-inflation dead shares defense (1,000 dead shares to address(0))               |
|    - Pro-rata in-range withdrawals (active position + idle reserves)                    |
|    - Graceful degradation: withdrawals always work even when inventory is infeasible   |
|                                                                                         |
|  [Analytical Range Solver (RangeMath)]                                                  |
|    - Exact Q96 fixed-point closed-form solver                                           |
|    - Discrete tick spacing alignment & minimal-dust candidate search                    |
|    - 1-wei rounding overdraw safety clamp                                               |
|                                                                                         |
|  [Guards & Threat Protection (Guards)]                                                  |
|    - Continuous EMA price tracking in afterSwap                                         |
|    - Max price deviation guard (maxDeviationBps) against flash loans                   |
|    - Rebalance cooldown timing (cooldown)                                               |
|    - Gated keeper-only access control (keeperOnly, isKeeper)                            |
|    - Range width bounds validation (minWidthTicks, maxWidthTicks)                       |
|    - Boundary proximity detection (rebalanceDue flag)                                   |
|                                                                                         |
|  [Dynamic Directional Fee Skew (FeeSkew)]                                               |
|    - beforeSwap dynamic fee override using Uniswap v4 DYNAMIC_FEE_FLAG                 |
|    - Real-time inventory skew: skew = (value0 / totalValue) - targetRatio               |
|    - Direction mapping: swaps worsening skew pay higher fees; balance-restoring cheaper  |
|    - Safe override bit enforcement: protects against the Uniswap v4 "override with 0"   |
|                                                                                         |
|  [Uniswap v4 Flash Accounting Integration]                                              |
|    - Liquidity gating: beforeAddLiquidity (only hook can LP)                            |
|    - Atomic unlockCallback: Remove Old -> Verify -> Add New -> Settle Net               |
+-----------------------------------------------------------------------------------------+
                                           |
                       unlockCallback      |      modifyLiquidity / take / settle / swap
                                           v
+-----------------------------------------------------------------------------------------+
|                               Uniswap v4 PoolManager                                    |
|  - Flash accounting transient delta settlement                                          |
|  - Dynamic fee pool support (LPFeeLibrary.DYNAMIC_FEE_FLAG)                             |
+-----------------------------------------------------------------------------------------+
```

---

## Key Features & Functionality

### 1. Any-Ratio Vault Deposits & Fair Share Accounting
- Users can deposit tokens in **any proportion**—single-sided token0, single-sided token1, or arbitrary mixtures.
- Incoming tokens enter idle reserves without incurring immediate swaps or slippage.
- Shares are minted based on total vault valuation evaluated at the smoothed Exponential Moving Average (EMA) price, preventing flash-loan share manipulation.
- **Dead Shares Defense:** 1,000 dead shares are permanently burned to `address(0)` on the first deposit, neutralizing ERC-4626 first-depositor inflation attacks.

### 2. Swapless Rebalance Lifecycle (`unlockCallback`)
Rebalancing is executed atomically in a single Uniswap v4 unlock callback:
1. **Remove Existing Liquidity:** Calls `modifyLiquidity(-L)` on the old range. The returned delta credits principal and all accrued LP fees.
2. **Compute Total Inventory:** Combines idle reserves with returned principal and fees:
   $$\text{inv}_0 = \text{idle}_0 + \Delta_0, \quad \text{inv}_1 = \text{idle}_1 + \Delta_1$$
3. **Verify Proposed Range:** Checks tick spacing alignment, range ordering, spot price containment, range width bounds, and solver feasibility.
4. **Deviation Guard:** Confirms that the current pool spot price has not deviated beyond `maxDeviationBps` from the smoothed EMA price.
5. **1-Wei Round-Up Safety Clamp:** Clamps liquidity so that token requirements rounded up by the pool never exceed available inventory.
6. **Deploy Asymmetric Liquidity:** Calls `modifyLiquidity(+L')` on the new range to establish the swapless position.
7. **Settle Net Deltas:**
   - Positive net credits are withdrawn to the vault via `poolManager.take()`.
   - Negative net debts are paid from idle reserves via `poolManager.sync()`, token transfer, and `poolManager.settle()`.
   - All transient deltas in the `PoolManager` resolve to exact zero.

### 3. Continuous EMA Price Tracking & Flash-Loan Defense
- The hook tracks an Exponential Moving Average (EMA) square-root price in `_afterSwap` across all swaps:
  $$\text{EMA}_{\text{new}} = \frac{(10000 - \alpha) \cdot \text{EMA}_{\text{old}} + \alpha \cdot \text{Spot}}{10000}$$
- **Deviation Guard:** If an attacker attempts to manipulate the spot price with a large flash loan before calling `rebalance()`, the transaction reverts with `PriceDeviationTooHigh`.
- Rebalances are permitted only when the spot price is verified against the smoothed moving average.

### 4. Dynamic Directional Fee Skew
When the vault inventory becomes skewed (e.g. 70% token0 and 30% token1), normal swapless rebalancing produces an asymmetric range. To gently nudge inventory back toward balance, RangeFit applies a **directional fee skew** in `_beforeSwap`:
- **Swaps that worsen imbalance** (e.g. paying in token0 when the vault is already overweight token0) pay a **higher fee** (`baseFee + adjustment`).
- **Swaps that restore balance** (e.g. removing token0 from the pool when the vault is overweight token0) pay a **discounted fee** (`baseFee - adjustment`).
- Fees are strictly bounded within `[minFee, maxFee]`.
- Protected against the Uniswap v4 "override with 0" pitfall by explicitly managing `LPFeeLibrary.OVERRIDE_FEE_FLAG`.

### 5. Rebalance Cooldown & Keeper Allowlist Gating
- **Cooldown:** Enforces a minimum time interval between consecutive rebalances (`lastRebalance + cooldown`), preventing rapid position churn and gas depletion during volatile spikes.
- **Keeper Allowlist:** An optional `keeperOnly` mode restricts rebalance authorization to designated keeper bots and the vault owner, while allowing permissionless execution when disabled.
- **Boundary Proximity Alert:** Flags `rebalanceDue = true` in `_afterSwap` whenever the spot price approaches within 20% of the active range boundaries.

### 6. Dust Retention & Automatic Fee Compounding
- Fractional token amounts left over due to discrete tick spacing remain in the vault as `idle0` and `idle1`.
- When the next rebalance occurs, all previously retained dust plus accrued trading fees are automatically incorporated into the total inventory and redeployed into active liquidity.

### 7. Graceful Fallback & Fair Pro-Rata Withdrawals
- **No-Valid-Range Fallback:** If inventory becomes heavily one-sided (e.g. 100% token0 at 1:1 spot price) such that an active range containing the spot price cannot be formed without swapping, `rebalance()` reverts safely with `InfeasibleInventory()`.
- **Guaranteed Withdrawals:** User withdrawals never lock up. Users can burn their shares and withdraw their exact pro-rata assets from idle reserves and active liquidity at any time, with zero cross-user leakage.

### 8. Hook-as-LP Access Gating
- `beforeAddLiquidity` callback strictly restricts pool liquidity additions to `sender == address(this)`. External liquidity providers cannot inject liquidity directly into the pool, preserving pool inventory ratios and protecting vault management from outside manipulation.

---

## Contract Structure

```
src/
├── RangeFitHook.sol          # Unified Uniswap v4 hook, vault accounting, fee skew, and unlock callback
├── interfaces/
│   └── IRangeFit.sol         # Core vault errors, events, structs, and public interfaces
└── libraries/
    ├── RangeMath.sol         # Fixed-point Q96 analytical solver, tick alignment, and dust math
    ├── Guards.sol            # EMA price smoothing, deviation guards, and width validation
    └── FeeSkew.sol           # Inventory skew calculation and dynamic directional fee adjustment
```

### `RangeFitHook.sol`
The primary entry point implementing `BaseHook`, `IRangeFit`, `IUnlockCallback`, and `ReentrancyGuard`:
- `deposit(uint256 amount0, uint256 amount1, uint256 minShares)`: Accepts any token ratio and mints proportional shares.
- `withdraw(uint256 shares, uint256 min0, uint256 min1)`: Burns shares and returns pro-rata idle and position tokens.
- `rebalance(RebalanceParams calldata params)`: Triggers swapless re-ranging through `poolManager.unlock()`.
- `previewDeposit`, `previewWithdraw`, `previewRebalance`: View functions providing simulations down to the wei.
- `inventory()` & `totalVaultValue()`: Real-time accounting across idle reserves and concentrated liquidity.
- `setFeeSkewEnabled`, `setFeeParams`, `setKeeper`, `setKeeperOnly`, `setCooldown`, `setMaxDeviationBps`, `setWidthBounds`: Governance controls.

### `RangeMath.sol`
Pure mathematical library operating entirely in Q96 fixed-point and integer arithmetic (`FullMath`):
- `solveRange`: Analytical solver deriving upper price $v$ from lower price $u$, spot price $s$, and inventory amounts $(X, Y)$.
- `isFeasible`: Determines if inventory can form an active in-range position at the given price.
- `alignTicksToSpacing`: Rounds continuous solver prices to valid Uniswap v4 tick spacing multiples.
- `computeRangeUsageAndDust`: Calculates token consumption, residual dust, and dust basis points.
- `getAmountsForLiquidity`: Computes exact $(X, Y)$ tokens held by a given liquidity amount at current spot price.

### `Guards.sol`
Security and manipulation defense library:
- `updateEMA`: Exponential Moving Average square-root price smoothing.
- `computeDeviationBps` & `checkDeviation`: Relative price deviation checking against flash loans.
- `checkWidth`: Validates that position widths satisfy minimum and maximum tick bounds.

### `FeeSkew.sol`
Directional fee adjustment library:
- `computeSkewBps`: Evaluates inventory imbalance relative to a target ratio.
- `computeDirectionalFee`: Adjusts swap fee based on swap direction and inventory skew, clamped between min and max bounds.

---

## Verification & Invariant Properties

RangeFit is validated by comprehensive Foundry test suites enforcing the following mathematical and economic invariants:

1. **Shares Conservation:** $\sum_u \text{shares}[u] + \text{DeadShares} = \text{TotalShares}$ (all user shares plus permanently burned `DEAD_SHARES` strictly equal `totalShares`).
2. **Zero Swap in Rebalancing:** During `rebalance()`, the pool swap counter and spot price remain strictly unchanged. The vault never trades against the pool.
3. **Value Preservation:** Total vault valuation after rebalance satisfies $\text{Value}_{\text{after}} \ge \text{Value}_{\text{before}} \times (1 - \epsilon)$, where $\epsilon$ covers discrete tick rounding dust only.
4. **Transient Delta Settlement:** Every currency delta in `PoolManager` settles to exact zero; rebalances never revert with `CurrencyNotSettled`.
5. **No Cross-User Leakage:** Withdrawals receive exact pro-rata claims; burning shares never reduces the per-share value of remaining holders.
6. **Price Manipulation Resilience:** Price deviations beyond `maxDeviationBps` from the smoothed EMA revert, preventing flash-loan exploits.
7. **Directional Fee Invariant:** When overweight token0, swaps that add token0 pay strictly higher fees than swaps that remove token0.

---

## Getting Started

### Prerequisites
- [Foundry](https://book.getfoundry.sh/) (stable release)
- Solidity `0.8.26+` with Cancun EVM support (`via_ir = true`)

### Installation & Build

```bash
# Clone the repository
git clone https://github.com/akshadgujarkar/RangeFit.git
cd RangeFit

# Install dependencies
forge install

# Build contracts
forge build
```

### Running Tests

```bash
# Run all test suites across the project (68 tests)
forge test

# Run with verbose traces
forge test -vvv

# Run specific test suites
forge test --match-contract RangeFitRebalanceTest -vv
forge test --match-contract RangeFitGuardsTest -vv
forge test --match-contract RangeFitFeeSkewTest -vv
```

---

## License

MIT
