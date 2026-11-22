// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IRangeFit} from "./interfaces/IRangeFit.sol";
import {RangeMath} from "./libraries/RangeMath.sol";

/// @title RangeFitHook
/// @notice Uniswap v4 Hook and Vault managing swapless concentrated liquidity re-ranging.
/// @dev Extends canonical Uniswap v4-periphery BaseHook and implements IUnlockCallback.
///      Maintains pooled vault accounting where deposits in any ratio are accepted as idle reserves
///      and shares are minted by value evaluated at the moving-average / spot price.
contract RangeFitHook is BaseHook, IRangeFit, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants & Storage
    // -------------------------------------------------------------------------

    /// @notice Number of dead shares permanently burned on the first deposit to prevent share-inflation attacks.
    uint256 public constant DEAD_SHARES = 1000;

    /// @notice The managed pool key for this hook instance.
    PoolKey public poolKey;

    /// @notice The pool ID of the managed pool.
    PoolId public poolId;

    /// @notice Whether the managed pool key has been configured.
    bool public poolConfigured;

    /// @notice Idle token0 reserves held in the vault awaiting deployment in the next rebalance.
    uint256 public idle0;

    /// @notice Idle token1 reserves held in the vault awaiting deployment in the next rebalance.
    uint256 public idle1;

    /// @notice Total vault shares minted across all participants (including dead shares).
    uint256 public totalShares;

    /// @notice Mapping of user addresses to their vault share balances.
    mapping(address => uint256) public shares;

    /// @notice Exponential moving average square-root price in Q96 for manipulation-resistant valuation.
    uint160 public emaSqrtPriceX96;

    // -------------------------------------------------------------------------
    // Constructor & Permissions
    // -------------------------------------------------------------------------

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
    // Configuration
    // -------------------------------------------------------------------------

    /// @notice Configures the managed pool key for this vault hook.
    /// @dev May only be called once, and the hook in the pool key must be this contract.
    /// @param _poolKey The pool key identifying currencies, fee, tickSpacing, and hook.
    function setPoolKey(PoolKey calldata _poolKey) external {
        if (poolConfigured) revert PoolAlreadyConfigured();
        if (address(_poolKey.hooks) != address(this)) revert InvalidPool();

        poolKey = _poolKey;
        poolId = _poolKey.toId();
        poolConfigured = true;

        emit PoolConfigured(poolId);
    }

    // -------------------------------------------------------------------------
    // Valuation Helpers
    // -------------------------------------------------------------------------

    /// @notice Retrieves the current price used for portfolio valuation.
    /// @dev Uses emaSqrtPriceX96 if initialized; otherwise falls back to pool spot price.
    /// @return sqrtPriceX96 Valuation square-root price in Q96.
    function getValuationSqrtPriceX96() public view returns (uint160 sqrtPriceX96) {
        if (emaSqrtPriceX96 != 0) {
            return emaSqrtPriceX96;
        }
        if (!poolConfigured) revert PoolNotConfigured();
        (sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
    }

    /// @notice Computes total portfolio value in token1 terms.
    /// @dev Total Value = valueInToken1(totalToken0) + totalToken1.
    /// @return Total vault value denominated in token1 base units.
    function totalVaultValue() public view returns (uint256) {
        if (!poolConfigured) return 0;
        uint160 s = getValuationSqrtPriceX96();
        (uint256 inv0, uint256 inv1) = inventory();
        return RangeMath.valueInToken1(inv0, s) + inv1;
    }

    /// @notice Computes the pro-rata value of a user's share holdings in token1 terms.
    /// @param user Address of the user.
    /// @return Value of user's shares in token1 base units.
    function userValue(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return FullMath.mulDiv(totalVaultValue(), shares[user], totalShares);
    }

    /// @notice Returns current total inventory of the vault.
    /// @dev In Milestone 3, all inventory consists of idle tokens. Milestone 4 will add deployed position amounts.
    /// @return inv0 Total token0 held.
    /// @return inv1 Total token1 held.
    function inventory() public view returns (uint256 inv0, uint256 inv1) {
        return (idle0, idle1);
    }

    // -------------------------------------------------------------------------
    // User Entry Points: Deposit & Withdraw
    // -------------------------------------------------------------------------

    /// @notice Deposits tokens into the vault in any ratio, receiving pro-rata vault shares.
    /// @dev Tokens are added to idle reserves. The next swapless rebalance will solve for a range
    ///      that absorbs all accumulated idle tokens. Dead shares are minted on the first deposit.
    /// @param amount0 Amount of token0 to deposit.
    /// @param amount1 Amount of token1 to deposit.
    /// @param minShares Minimum acceptable shares to mint (slippage protection).
    /// @return sharesMinted Total shares credited to msg.sender.
    function deposit(
        uint256 amount0,
        uint256 amount1,
        uint256 minShares
    ) external nonReentrant returns (uint256 sharesMinted) {
        if (!poolConfigured) revert PoolNotConfigured();
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();

        uint160 s = getValuationSqrtPriceX96();
        uint256 depositVal = RangeMath.valueInToken1(amount0, s) + amount1;

        if (totalShares == 0) {
            if (depositVal <= DEAD_SHARES) {
                revert InitialDepositTooSmall(depositVal, DEAD_SHARES + 1);
            }
            totalShares = depositVal;
            shares[address(0)] = DEAD_SHARES;
            sharesMinted = depositVal - DEAD_SHARES;
        } else {
            uint256 vaultValueBefore = totalVaultValue();
            sharesMinted = FullMath.mulDiv(depositVal, totalShares, vaultValueBefore);
            totalShares += sharesMinted;
        }

        if (sharesMinted < minShares) {
            revert InsufficientSharesMinted(sharesMinted, minShares);
        }

        shares[msg.sender] += sharesMinted;
        idle0 += amount0;
        idle1 += amount1;

        // Pull tokens from depositor
        if (amount0 > 0) {
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(msg.sender, address(this), amount1);
        }

        emit Deposit(msg.sender, amount0, amount1, sharesMinted);
    }

    /// @notice Burns vault shares and withdraws pro-rata share of idle reserves.
    /// @dev In Milestone 4, this will also withdraw pro-rata share of the deployed pool position.
    /// @param sharesToBurn Amount of shares to burn.
    /// @param minAmount0 Minimum acceptable token0 to receive.
    /// @param minAmount1 Minimum acceptable token1 to receive.
    /// @return amount0Out Amount of token0 transferred to user.
    /// @return amount1Out Amount of token1 transferred to user.
    function withdraw(
        uint256 sharesToBurn,
        uint256 minAmount0,
        uint256 minAmount1
    ) external nonReentrant returns (uint256 amount0Out, uint256 amount1Out) {
        if (sharesToBurn == 0) revert ZeroAmount();
        if (shares[msg.sender] < sharesToBurn) {
            revert InsufficientSharesBalance(sharesToBurn, shares[msg.sender]);
        }

        amount0Out = FullMath.mulDiv(idle0, sharesToBurn, totalShares);
        amount1Out = FullMath.mulDiv(idle1, sharesToBurn, totalShares);

        if (amount0Out < minAmount0 || amount1Out < minAmount1) {
            revert InsufficientAmountsReceived(amount0Out, amount1Out, minAmount0, minAmount1);
        }

        shares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;
        idle0 -= amount0Out;
        idle1 -= amount1Out;

        // Transfer tokens to withdrawer
        if (amount0Out > 0) {
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(msg.sender, amount0Out);
        }
        if (amount1Out > 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(msg.sender, amount1Out);
        }

        emit Withdraw(msg.sender, sharesToBurn, amount0Out, amount1Out);
    }

    /// @notice Previews the number of shares minted for a proposed deposit.
    /// @param amount0 Amount of token0.
    /// @param amount1 Amount of token1.
    /// @return sharesMinted Estimated shares minted.
    function previewDeposit(uint256 amount0, uint256 amount1) external view returns (uint256 sharesMinted) {
        if (!poolConfigured || (amount0 == 0 && amount1 == 0)) return 0;
        uint160 s = getValuationSqrtPriceX96();
        uint256 depositVal = RangeMath.valueInToken1(amount0, s) + amount1;

        if (totalShares == 0) {
            if (depositVal <= DEAD_SHARES) return 0;
            return depositVal - DEAD_SHARES;
        }

        uint256 vaultValueBefore = totalVaultValue();
        if (vaultValueBefore == 0) return 0;
        return FullMath.mulDiv(depositVal, totalShares, vaultValueBefore);
    }

    /// @notice Previews token amounts returned for a proposed share burn.
    /// @param sharesToBurn Amount of shares to burn.
    /// @return amount0Out Estimated token0 received.
    /// @return amount1Out Estimated token1 received.
    function previewWithdraw(uint256 sharesToBurn) external view returns (uint256 amount0Out, uint256 amount1Out) {
        if (totalShares == 0 || sharesToBurn == 0) return (0, 0);
        amount0Out = FullMath.mulDiv(idle0, sharesToBurn, totalShares);
        amount1Out = FullMath.mulDiv(idle1, sharesToBurn, totalShares);
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
