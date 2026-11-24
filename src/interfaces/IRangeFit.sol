// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IRangeFit
/// @notice Core interface, errors, and events for the RangeFit hook and vault.
interface IRangeFit {
    // -------------------------------------------------------------------------
    // Custom Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when an unauthorized caller attempts to add liquidity directly to the pool.
    /// @dev Only the RangeFit hook/vault itself is authorized to add liquidity (hook-as-LP pattern).
    /// @param caller The unauthorized address that attempted to add liquidity.
    error UnauthorizedAddLiquidity(address caller);

    /// @notice Thrown when interacting with an unmanaged or invalid pool.
    error InvalidPool();

    /// @notice Thrown when the managed pool key has already been configured.
    error PoolAlreadyConfigured();

    /// @notice Thrown when attempting an action that requires a configured pool key.
    error PoolNotConfigured();

    /// @notice Thrown when a zero amount is passed where non-zero is required.
    error ZeroAmount();

    /// @notice Thrown when shares minted do not meet user's minShares slippage bound.
    /// @param minted Actual shares minted.
    /// @param minShares Minimum acceptable shares.
    error InsufficientSharesMinted(uint256 minted, uint256 minShares);

    /// @notice Thrown when withdrawal amounts do not meet user's slippage minimums.
    /// @param amount0 Actual token0 received.
    /// @param amount1 Actual token1 received.
    /// @param min0 Minimum token0 required.
    /// @param min1 Minimum token1 required.
    error InsufficientAmountsReceived(uint256 amount0, uint256 amount1, uint256 min0, uint256 min1);

    /// @notice Thrown when a user attempts to burn more shares than their balance.
    /// @param requested Shares requested to burn.
    /// @param available Available share balance.
    error InsufficientSharesBalance(uint256 requested, uint256 available);

    /// @notice Thrown when the initial deposit value does not exceed the minimum required dead shares.
    /// @param value Total value of initial deposit in token1 terms.
    /// @param minRequired Minimum required deposit value.
    error InitialDepositTooSmall(uint256 value, uint256 minRequired);

    /// @notice Thrown when a proposed tick is not an integer multiple of the pool's tick spacing.
    /// @param tick The invalid tick.
    /// @param tickSpacing Required spacing between ticks.
    error TicksNotAligned(int24 tick, int24 tickSpacing);

    /// @notice Thrown when lower tick is greater than or equal to upper tick.
    /// @param lower Proposed lower tick.
    /// @param upper Proposed upper tick.
    error InvalidTickRange(int24 lower, int24 upper);

    /// @notice Thrown when current pool spot price is outside the proposed range bounds.
    /// @param spotPriceX96 Current spot price in Q96.
    /// @param sqrtLowerX96 Lower tick price in Q96.
    /// @param sqrtUpperX96 Upper tick price in Q96.
    error PriceOutOfRange(uint160 spotPriceX96, uint160 sqrtLowerX96, uint160 sqrtUpperX96);

    /// @notice Thrown when inventory cannot form an active concentrated liquidity range at the current price.
    error InfeasibleInventory();

    /// @notice Thrown when computed liquidity does not meet keeper's minLiquidity slippage limit.
    /// @param actual Actual liquidity computed.
    /// @param minRequired Minimum required liquidity.
    error InsufficientLiquidityMinted(uint128 actual, uint128 minRequired);

    /// @notice Thrown when rebalance dust exceeds maximum allowed basis points.
    /// @param actualBps Actual dust in basis points.
    /// @param maxBps Maximum permitted dust basis points.
    error DustToleranceExceeded(uint256 actualBps, uint256 maxBps);

    /// @notice Thrown when computed liquidity is zero.
    error ZeroLiquidity();

    /// @notice Thrown when an unauthorized caller attempts to rebalance when keeperOnly is enabled.
    /// @param caller The unauthorized caller address.
    error UnauthorizedKeeper(address caller);

    /// @notice Thrown when a non-owner calls an owner-restricted admin function.
    /// @param caller The unauthorized caller address.
    error OnlyOwner(address caller);

    /// @notice Thrown when a rebalance is attempted before the cooldown period has elapsed.
    /// @param availableAt The timestamp when the next rebalance is permitted.
    /// @param currentTimestamp The current block timestamp.
    error CooldownActive(uint32 availableAt, uint32 currentTimestamp);

    /// @notice Thrown when the current spot price deviates excessively from the smoothed EMA price.
    /// @param spotPriceX96 The current pool spot price.
    /// @param emaSqrtPriceX96 The current smoothed EMA price.
    /// @param actualBps The actual deviation in basis points.
    /// @param maxBps The maximum allowed deviation in basis points.
    error PriceDeviationTooHigh(
        uint160 spotPriceX96,
        uint160 emaSqrtPriceX96,
        uint256 actualBps,
        uint256 maxBps
    );

    /// @notice Thrown when a proposed range width is narrower than minWidthTicks.
    /// @param width The proposed width in ticks.
    /// @param minWidth The minimum allowable width.
    error RangeTooNarrow(int24 width, int24 minWidth);

    /// @notice Thrown when a proposed range width is wider than maxWidthTicks.
    /// @param width The proposed width in ticks.
    /// @param maxWidth The maximum allowable width.
    error RangeTooWide(int24 width, int24 maxWidth);

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @notice Parameters supplied to trigger a swapless rebalance.
    struct RebalanceParams {
        int24 newTickLower;
        int24 newTickUpper;
        uint128 minLiquidity;
        uint256 maxDustBps;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when the hook is deployed and initialized with the PoolManager.
    /// @param poolManager Address of the Uniswap v4 PoolManager.
    /// @param flags Hook permission flags encoded in the hook address.
    event HookInitialized(address indexed poolManager, uint160 flags);

    /// @notice Emitted when the managed pool key is configured.
    /// @param poolId The unique ID of the configured pool.
    event PoolConfigured(PoolId indexed poolId);

    /// @notice Emitted when a user deposits tokens into the vault.
    /// @param user The depositor address.
    /// @param amount0 Amount of token0 deposited into idle reserves.
    /// @param amount1 Amount of token1 deposited into idle reserves.
    /// @param shares Total vault shares minted to the user.
    event Deposit(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);

    /// @notice Emitted when a user burns vault shares to withdraw tokens.
    /// @param user The withdrawer address.
    /// @param shares Amount of shares burned.
    /// @param amount0 Amount of token0 returned to the user.
    /// @param amount1 Amount of token1 returned to the user.
    event Withdraw(address indexed user, uint256 shares, uint256 amount0, uint256 amount1);

    /// @notice Emitted when a swapless rebalance is executed.
    /// @param oldTickLower Previous lower tick bound.
    /// @param oldTickUpper Previous upper tick bound.
    /// @param oldLiquidity Previous active liquidity.
    /// @param newTickLower New lower tick bound.
    /// @param newTickUpper New upper tick bound.
    /// @param newLiquidity New active liquidity deployed.
    /// @param idle0 Leftover unallocated token0 held as idle dust.
    /// @param idle1 Leftover unallocated token1 held as idle dust.
    /// @param dustBps Dust value in basis points relative to total portfolio value.
    event Rebalanced(
        int24 oldTickLower,
        int24 oldTickUpper,
        uint128 oldLiquidity,
        int24 newTickLower,
        int24 newTickUpper,
        uint128 newLiquidity,
        uint256 idle0,
        uint256 idle1,
        uint256 dustBps
    );

    /// @notice Emitted when a keeper address's authorization status is updated.
    /// @param keeper The keeper address.
    /// @param allowed True if granted rebalance authorization, false if revoked.
    event KeeperUpdated(address indexed keeper, bool allowed);

    /// @notice Emitted when keeper-only enforcement is toggled.
    /// @param enabled True if only allowlisted keepers can rebalance, false if permissionless.
    event KeeperOnlyToggled(bool enabled);

    /// @notice Emitted when the rebalance cooldown is updated.
    /// @param oldCooldown Previous cooldown period in seconds.
    /// @param newCooldown New cooldown period in seconds.
    event CooldownUpdated(uint32 oldCooldown, uint32 newCooldown);

    /// @notice Emitted when the maximum price deviation tolerance is updated.
    /// @param oldDeviationBps Previous deviation tolerance in basis points.
    /// @param newDeviationBps New deviation tolerance in basis points.
    event MaxDeviationUpdated(uint256 oldDeviationBps, uint256 newDeviationBps);

    /// @notice Emitted when range width boundaries are updated.
    /// @param minWidth New minimum width in ticks.
    /// @param maxWidth New maximum width in ticks.
    event WidthBoundsUpdated(int24 minWidth, int24 maxWidth);

    /// @notice Emitted when the EMA smoothing factor is updated.
    /// @param oldAlphaBps Previous alpha factor in basis points.
    /// @param newAlphaBps New alpha factor in basis points.
    event EmaAlphaUpdated(uint16 oldAlphaBps, uint16 newAlphaBps);

    /// @notice Emitted when contract ownership is transferred.
    /// @param oldOwner Previous vault administrator address.
    /// @param newOwner New vault administrator address.
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    /// @notice Emitted when the Exponential Moving Average price updates.
    /// @param oldEma Previous EMA price in Q96.
    /// @param newEma Updated EMA price in Q96.
    event EmaUpdated(uint160 oldEma, uint160 newEma);

    // -------------------------------------------------------------------------
    // External View & State Functions
    // -------------------------------------------------------------------------

    /// @notice Rebalances vault inventory into a newly solved range without swapping.
    /// @param params Parameters specifying target ticks, minLiquidity, and maxDustBps.
    /// @return newLiquidity Total active liquidity established in the new range.
    function rebalance(RebalanceParams calldata params) external returns (uint128 newLiquidity);

    /// @notice Previews the outcome of rebalancing into a proposed tick range.
    /// @param newTickLower Proposed lower tick.
    /// @param newTickUpper Proposed upper tick.
    /// @return newLiquidity Potential liquidity to be minted.
    /// @return used0 Token0 amount absorbed into the position.
    /// @return used1 Token1 amount absorbed into the position.
    /// @return dust0 Unused token0 remaining as idle dust.
    /// @return dust1 Unused token1 remaining as idle dust.
    /// @return dustBps Dust in basis points.
    function previewRebalance(
        int24 newTickLower,
        int24 newTickUpper
    ) external view returns (
        uint128 newLiquidity,
        uint256 used0,
        uint256 used1,
        uint256 dust0,
        uint256 dust1,
        uint256 dustBps
    );

    /// @notice Returns current active position bounds and liquidity.
    /// @return currentTickLower Active lower tick.
    /// @return currentTickUpper Active upper tick.
    /// @return currentLiquidity Active liquidity in pool.
    function position() external view returns (int24 currentTickLower, int24 currentTickUpper, uint128 currentLiquidity);
}
