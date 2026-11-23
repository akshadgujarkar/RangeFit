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
+--------------------------------------------------------------------------------+
|                                  RangeFitHook                                  |
|                                                                                |
|  [User Deposits & Withdrawals]                                                 |
|    - Any-ratio deposits into idle reserves (single-sided or mixed)             |
|    - ERC-4626 style fair valuation share minting                               |
|    - Anti-inflation dead shares defense                                        |
|    - Pro-rata in-range withdrawals (active position + idle reserves)           |
|                                                                                |
|  [Analytical Range Solver (RangeMath)]                                         |
|    - Exact Q96 fixed-point solver                                              |
|    - Spacing tick alignment & minimal-dust candidate search                    |
|    - 1-wei rounding overdraw safety clamp                                      |
|                                                                                |
|  [Uniswap v4 Flash Accounting Integration]                                     |
|    - Liquidity gating: beforeAddLiquidity (only hook can LP)                   |
|    - Atomic unlockCallback: Remove Old -> Verify -> Add New -> Settle Net      |
+--------------------------------------------------------------------------------+
                                       |
                   unlockCallback      |      modifyLiquidity / take / settle
                                       v
+--------------------------------------------------------------------------------+
|                           Uniswap v4 PoolManager                               |
|  - Flash accounting transient delta settlement                                 |
|  - Dynamic fee pool support                                                    |
+--------------------------------------------------------------------------------+
```

---

## Key Features & Functionality

### 1. Any-Ratio Vault Deposits
- Users can deposit tokens in **any proportion**—including single-sided token0, single-sided token1, or asymmetric ratios.
- Incoming tokens are placed in idle reserves without undergoing immediate swaps.
- Shares are minted based on the real-time valuation of the vault's total assets (active position + idle reserves) denominated in token1 terms.
- **Dead Shares Defense:** $1,000$ dead shares are permanently minted to `address(0)` on the first deposit, neutralizing ERC-4626 first-depositor inflation attacks.

### 2. Swapless Rebalance Lifecycle (`unlockCallback`)
Rebalancing is executed atomically in a single Uniswap v4 unlock callback:
1. **Remove Existing Liquidity:** Calls `modifyLiquidity(-L)` on the old range. The returned delta credits principal and all accrued LP fees.
2. **Compute Total Inventory:** Combines idle reserves with returned principal and fees:
   $$\text{inv}_0 = \text{idle}_0 + \Delta_0, \quad \text{inv}_1 = \text{idle}_1 + \Delta_1$$
3. **Verify Proposed Range:** Checks tick spacing alignment, range ordering, spot price containment, and solver feasibility.
4. **1-Wei Round-Up Safety Clamp:** Clamps liquidity so that token requirements rounded up by the pool never exceed available inventory.
5. **Deploy Asymmetric Liquidity:** Calls `modifyLiquidity(+L')` on the new range to establish the swapless position.
6. **Settle Net Deltas:**
   - Positive net credits are withdrawn to the vault via `poolManager.take()`.
   - Negative net debts are paid from idle reserves via `poolManager.sync()`, token transfer, and `poolManager.settle()`.
   - Net transient deltas in the `PoolManager` resolve to zero.

### 3. Dust Retention & Fee Compounding
- Any fractional token amounts left over due to tick spacing discrete steps remain in the vault as `idle0` and `idle1`.
- When the next rebalance occurs, all previously retained dust plus accrued trading fees are automatically incorporated into the total inventory and redeployed into liquidity.

### 4. Fair Pro-Rata Withdrawals (Zero Cross-User Leakage)
- When a user burns vault shares while liquidity is deployed, the vault calculates their proportional claim on both idle reserves and the active pool position:
  $$\Delta L = \frac{L \times \text{shares}}{\text{totalShares}}$$
- The hook removes $\Delta L$ from the pool, receives the underlying tokens, and transfers both the pool tokens and pro-rata idle tokens directly to the user.
- Remaining depositors' share valuations and active pool concentrations are completely unaffected.

### 5. Hook-as-LP Access Gating
- `beforeAddLiquidity` hook callback enforces `sender == address(this)`. External liquidity providers cannot inject liquidity directly into the pool, preserving pool inventory ratios and protecting vault management from outside manipulation.

---

## Contract Structure

```
src/
├── RangeFitHook.sol          # Unified Uniswap v4 hook, vault accounting, and unlock callback
├── interfaces/
│   └── IRangeFit.sol         # Core vault errors, events, structs, and public interfaces
└── libraries/
    └── RangeMath.sol         # Fixed-point Q96 analytical solver, tick alignment, and dust math
```

### `RangeFitHook.sol`
The primary entry point implementing `BaseHook`, `IRangeFit`, `IUnlockCallback`, and `ReentrancyGuard`:
- `deposit(uint256 amount0, uint256 amount1, uint256 minShares)`: Accepts any token ratio and mints proportional shares.
- `withdraw(uint256 shares, uint256 min0, uint256 min1)`: Burns shares and returns pro-rata idle and position tokens.
- `rebalance(RebalanceParams calldata params)`: Triggers swapless re-ranging through `poolManager.unlock()`.
- `previewDeposit`, `previewWithdraw`, `previewRebalance`: View functions providing exact simulations down to the wei.
- `inventory()` & `totalVaultValue()`: Real-time accounting across idle reserves and concentrated liquidity.

### `RangeMath.sol`
Pure mathematical library operating entirely in Q96 fixed-point and integer arithmetic (`FullMath`):
- `solveRange`: Analytical solver deriving upper price $v$ from lower price $u$, spot price $s$, and amounts $(X, Y)$.
- `isFeasible`: Determines if inventory can form an active in-range position at the given price.
- `alignTicksToSpacing`: Rounds continuous solver prices to valid Uniswap v4 tick spacing multiples.
- `computeRangeUsageAndDust`: Calculates token consumption, residual dust, and dust basis points.
- `getAmountsForLiquidity`: Computes exact $(X, Y)$ tokens held by a given liquidity amount at current spot price.

---

## Verification & Invariant Properties

RangeFit is validated by comprehensive Foundry test suites enforcing the following mathematical and economic invariants:

1. **Shares Conservation:** $\sum \text{shares}[u] + \text{DEAD\_SHARES} = \text{totalShares}$.
2. **Zero Swap in Rebalancing:** During `rebalance()`, the pool swap counter and spot price remain strictly unchanged. The vault never trades against the pool.
3. **Value Preservation:** Total vault valuation after rebalance satisfies $\text{Value}_{\text{after}} \ge \text{Value}_{\text{before}} \times (1 - \epsilon)$, where $\epsilon$ covers discrete tick rounding dust only.
4. **Transient Delta Settlement:** Every currency delta in `PoolManager` settles to exact zero; rebalances never revert with `CurrencyNotSettled`.
5. **No Cross-User Leakage:** Withdrawals receive exact pro-rata claims; burning shares never reduces the per-share value of remaining holders.

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
# Run all test suites
forge test

# Run with verbose traces
forge test -vvv

# Run specific rebalance integration tests
forge test --match-contract RangeFitRebalanceTest -vv
```

---

## License

MIT
