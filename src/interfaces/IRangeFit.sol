// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IRangeFit
/// @notice Core interface, errors, and events for the RangeFit hook and vault.
interface IRangeFit {
    /// @notice Thrown when an unauthorized caller attempts to add liquidity directly to the pool.
    /// @dev Only the RangeFit hook/vault itself is authorized to add liquidity (hook-as-LP pattern).
    /// @param caller The unauthorized address that attempted to add liquidity.
    error UnauthorizedAddLiquidity(address caller);

    /// @notice Thrown when interacting with an unmanaged or invalid pool.
    error InvalidPool();

    /// @notice Emitted when the hook is deployed and initialized with the PoolManager.
    /// @param poolManager Address of the Uniswap v4 PoolManager.
    /// @param flags Hook permission flags encoded in the hook address.
    event HookInitialized(address indexed poolManager, uint160 flags);
}
