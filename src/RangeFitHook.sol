// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {IRangeFit} from "./interfaces/IRangeFit.sol";

/// @title RangeFitHook
/// @notice Uniswap v4 Hook that manages swapless concentrated liquidity re-ranging.
/// @dev Extends canonical Uniswap v4-periphery BaseHook and implements IUnlockCallback.
///      Enforces liquidity gating (only the hook can add liquidity to its managed pool)
///      and declares permissions for beforeSwap, afterSwap, and beforeAddLiquidity.
contract RangeFitHook is BaseHook, IRangeFit, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    /// @notice Deploy RangeFitHook bound to the singleton PoolManager.
    /// @param _poolManager The Uniswap v4 PoolManager contract.
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        emit HookInitialized(address(_poolManager), uint160(address(this)) & Hooks.ALL_HOOK_MASK);
    }

    /// @notice Specifies the hook permissions required by RangeFit.
    /// @dev Flags: beforeSwap (fee skew), afterSwap (price observation), beforeAddLiquidity (gating).
    /// @return permissions Struct defining active hook callbacks.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------------
    // PoolManager Unlock Callback
    // -------------------------------------------------------------------------

    /// @inheritdoc IUnlockCallback
    /// @notice Entry point invoked by the PoolManager upon unlocking.
    /// @dev Restricted to onlyPoolManager caller. Calls internal _unlockCallback.
    function unlockCallback(bytes calldata data) external virtual override onlyPoolManager returns (bytes memory) {
        return _unlockCallback(data);
    }

    /// @dev Internal unlock callback handler to be extended in Milestone 4.
    function _unlockCallback(bytes calldata /* data */) internal virtual returns (bytes memory) {
        return "";
    }

    // -------------------------------------------------------------------------
    // Hook Callbacks
    // -------------------------------------------------------------------------

    /// @notice Gating callback executed before adding liquidity to a pool.
    /// @dev Strictly enforces that only this contract can add liquidity, preserving the hook-as-LP pattern.
    /// @param sender The address initiating the liquidity addition.
    /// @return selector Function selector acknowledging successful callback.
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata /* key */,
        ModifyLiquidityParams calldata /* params */,
        bytes calldata /* hookData */
    ) internal virtual override returns (bytes4 selector) {
        if (sender != address(this)) {
            revert UnauthorizedAddLiquidity(sender);
        }
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @notice Callback executed before each swap.
    /// @dev Stub for Milestone 2; Milestone 6 introduces dynamic directional fee skew.
    /// @return selector Function selector acknowledging successful callback.
    /// @return delta Swap delta override (ZERO_DELTA).
    /// @return fee Dynamic LP fee override (0 for default pool fee).
    function _beforeSwap(
        address /* sender */,
        PoolKey calldata /* key */,
        SwapParams calldata /* params */,
        bytes calldata /* hookData */
    ) internal virtual override returns (bytes4 selector, BeforeSwapDelta delta, uint24 fee) {
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Callback executed after each swap.
    /// @dev Stub for Milestone 2; Milestone 5 introduces EMA spot price observation tracking.
    /// @return selector Function selector acknowledging successful callback.
    /// @return hookDelta Secondary delta returned by hook (0).
    function _afterSwap(
        address /* sender */,
        PoolKey calldata /* key */,
        SwapParams calldata /* params */,
        BalanceDelta /* delta */,
        bytes calldata /* hookData */
    ) internal virtual override returns (bytes4 selector, int128 hookDelta) {
        return (BaseHook.afterSwap.selector, 0);
    }
}
