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
}
