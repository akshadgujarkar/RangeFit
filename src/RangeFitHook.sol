// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

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

    /// @notice Fixed position salt identifying the managed pooled position in the PoolManager.
    bytes32 public constant POSITION_SALT = bytes32(0);

    /// @notice Action discriminator passed to unlockCallback.
    enum CallbackAction { REBALANCE, WITHDRAW }

    /// @notice Active lower tick bound of the managed position.
    int24 public tickLower;

    /// @notice Active upper tick bound of the managed position.
    int24 public tickUpper;

    /// @notice Active liquidity currently deployed in the pool.
    uint128 public liquidity;

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

    /// @notice Returns current active position bounds and liquidity.
    /// @return currentTickLower Active lower tick.
    /// @return currentTickUpper Active upper tick.
    /// @return currentLiquidity Active liquidity in pool.
    function position() external view returns (int24 currentTickLower, int24 currentTickUpper, uint128 currentLiquidity) {
        return (tickLower, tickUpper, liquidity);
    }

    /// @notice Returns current total inventory of the vault across idle reserves and active deployed position.
    /// @return inv0 Total token0 held.
    /// @return inv1 Total token1 held.
    function inventory() public view returns (uint256 inv0, uint256 inv1) {
        if (!poolConfigured) return (0, 0);
        if (liquidity == 0) {
            return (idle0, idle1);
        }
        (uint160 spotPriceX96, , , ) = poolManager.getSlot0(poolId);
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        (uint256 pos0, uint256 pos1) = RangeMath.getAmountsForLiquidity(
            spotPriceX96,
            sqrtLowerX96,
            sqrtUpperX96,
            liquidity
        );
        return (idle0 + pos0, idle1 + pos1);
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

    /// @notice Burns vault shares and withdraws pro-rata share of both idle reserves and active position liquidity.
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
        if (!poolConfigured) revert PoolNotConfigured();
        if (sharesToBurn == 0) revert ZeroAmount();
        if (shares[msg.sender] < sharesToBurn) {
            revert InsufficientSharesBalance(sharesToBurn, shares[msg.sender]);
        }

        uint256 proRataIdle0 = FullMath.mulDiv(idle0, sharesToBurn, totalShares);
        uint256 proRataIdle1 = FullMath.mulDiv(idle1, sharesToBurn, totalShares);
        uint128 proRataLiquidity = liquidity > 0
            ? uint128(FullMath.mulDiv(uint256(liquidity), sharesToBurn, totalShares))
            : 0;

        uint256 posAmount0 = 0;
        uint256 posAmount1 = 0;

        if (proRataLiquidity > 0) {
            bytes memory returnData = poolManager.unlock(
                abi.encode(CallbackAction.WITHDRAW, proRataLiquidity)
            );
            (int128 d0, int128 d1) = abi.decode(returnData, (int128, int128));
            posAmount0 = d0 > 0 ? uint128(d0) : 0;
            posAmount1 = d1 > 0 ? uint128(d1) : 0;
            liquidity -= proRataLiquidity;
        }

        amount0Out = proRataIdle0 + posAmount0;
        amount1Out = proRataIdle1 + posAmount1;

        if (amount0Out < minAmount0 || amount1Out < minAmount1) {
            revert InsufficientAmountsReceived(amount0Out, amount1Out, minAmount0, minAmount1);
        }

        idle0 -= proRataIdle0;
        idle1 -= proRataIdle1;
        shares[msg.sender] -= sharesToBurn;
        totalShares -= sharesToBurn;

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

    /// @notice Previews token amounts returned for a proposed share burn across idle and deployed position.
    /// @param sharesToBurn Amount of shares to burn.
    /// @return amount0Out Estimated token0 received.
    /// @return amount1Out Estimated token1 received.
    function previewWithdraw(uint256 sharesToBurn) external view returns (uint256 amount0Out, uint256 amount1Out) {
        if (totalShares == 0 || sharesToBurn == 0) return (0, 0);
        uint256 proRataIdle0 = FullMath.mulDiv(idle0, sharesToBurn, totalShares);
        uint256 proRataIdle1 = FullMath.mulDiv(idle1, sharesToBurn, totalShares);

        if (liquidity == 0) {
            return (proRataIdle0, proRataIdle1);
        }

        (uint160 spotPriceX96, , , ) = poolManager.getSlot0(poolId);
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        (uint256 pos0, uint256 pos1) = RangeMath.getAmountsForLiquidity(
            spotPriceX96,
            sqrtLowerX96,
            sqrtUpperX96,
            liquidity
        );
        uint256 proRataPos0 = FullMath.mulDiv(pos0, sharesToBurn, totalShares);
        uint256 proRataPos1 = FullMath.mulDiv(pos1, sharesToBurn, totalShares);

        return (proRataIdle0 + proRataPos0, proRataIdle1 + proRataPos1);
    }

    // -------------------------------------------------------------------------
    // Rebalance Execution & Previews
    // -------------------------------------------------------------------------

    /// @inheritdoc IRangeFit
    function rebalance(RebalanceParams calldata params) external nonReentrant returns (uint128 newLiquidity) {
        if (!poolConfigured) revert PoolNotConfigured();
        bytes memory result = poolManager.unlock(abi.encode(CallbackAction.REBALANCE, params));
        newLiquidity = abi.decode(result, (uint128));
    }

    /// @inheritdoc IRangeFit
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
    ) {
        if (!poolConfigured) revert PoolNotConfigured();
        (uint256 inv0, uint256 inv1) = inventory();
        (uint160 spotPriceX96, , , ) = poolManager.getSlot0(poolId);
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(newTickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(newTickUpper);

        if (spotPriceX96 <= sqrtLowerX96 || spotPriceX96 >= sqrtUpperX96) {
            return (0, 0, 0, inv0, inv1, 10_000);
        }

        if (!RangeMath.isFeasible(spotPriceX96, sqrtLowerX96, inv0, inv1)) {
            return (0, 0, 0, inv0, inv1, 10_000);
        }

        RangeMath.RangeUsage memory usage = RangeMath.computeRangeUsageAndDust(
            spotPriceX96,
            newTickLower,
            newTickUpper,
            inv0,
            inv1
        );

        while (usage.liquidity > 0) {
            uint256 req0 = SqrtPriceMath.getAmount0Delta(spotPriceX96, sqrtUpperX96, usage.liquidity, true);
            uint256 req1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, spotPriceX96, usage.liquidity, true);
            if (req0 <= inv0 && req1 <= inv1) {
                usage.amount0Used = req0;
                usage.amount1Used = req1;
                usage.dust0 = inv0 - req0;
                usage.dust1 = inv1 - req1;
                break;
            }
            usage.liquidity--;
        }

        return (
            usage.liquidity,
            usage.amount0Used,
            usage.amount1Used,
            usage.dust0,
            usage.dust1,
            usage.dustBps
        );
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

    /// @dev Internal unlock callback handler executing rebalance or withdrawal operations.
    function _unlockCallback(bytes calldata data) internal virtual returns (bytes memory) {
        CallbackAction action = abi.decode(data, (CallbackAction));

        if (action == CallbackAction.REBALANCE) {
            (, RebalanceParams memory params) = abi.decode(data, (CallbackAction, RebalanceParams));
            return _handleRebalance(params);
        } else if (action == CallbackAction.WITHDRAW) {
            (, uint128 proRataLiquidity) = abi.decode(data, (CallbackAction, uint128));
            return _handleWithdraw(proRataLiquidity);
        }

        return "";
    }

    /// @dev Executes rebalancing logic inside the poolManager unlock context.
    function _handleRebalance(RebalanceParams memory params) internal returns (bytes memory) {
        if (params.newTickLower >= params.newTickUpper) {
            revert InvalidTickRange(params.newTickLower, params.newTickUpper);
        }
        if (params.newTickLower % poolKey.tickSpacing != 0) {
            revert TicksNotAligned(params.newTickLower, poolKey.tickSpacing);
        }
        if (params.newTickUpper % poolKey.tickSpacing != 0) {
            revert TicksNotAligned(params.newTickUpper, poolKey.tickSpacing);
        }

        // Step 1: Remove old liquidity if present (realizing principal + accrued fees)
        BalanceDelta d1 = BalanceDeltaLibrary.ZERO_DELTA;
        int24 oldLower = tickLower;
        int24 oldUpper = tickUpper;
        uint128 oldLiq = liquidity;
        if (oldLiq > 0) {
            (d1, ) = poolManager.modifyLiquidity(
                poolKey,
                ModifyLiquidityParams({
                    tickLower: oldLower,
                    tickUpper: oldUpper,
                    liquidityDelta: -int256(uint256(oldLiq)),
                    salt: POSITION_SALT
                }),
                ""
            );
        }

        // Step 2: Compute total inventory available for deployment (idle + returned principal/fees)
        uint256 inv0 = idle0 + (d1.amount0() > 0 ? uint128(d1.amount0()) : 0);
        uint256 inv1 = idle1 + (d1.amount1() > 0 ? uint128(d1.amount1()) : 0);

        // Step 3: Spot price and solver verification
        (uint160 spotPriceX96, , , ) = poolManager.getSlot0(poolId);
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(params.newTickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(params.newTickUpper);

        if (spotPriceX96 <= sqrtLowerX96 || spotPriceX96 >= sqrtUpperX96) {
            revert PriceOutOfRange(spotPriceX96, sqrtLowerX96, sqrtUpperX96);
        }

        if (!RangeMath.isFeasible(spotPriceX96, sqrtLowerX96, inv0, inv1)) {
            revert InfeasibleInventory();
        }

        RangeMath.RangeUsage memory usage = RangeMath.computeRangeUsageAndDust(
            spotPriceX96,
            params.newTickLower,
            params.newTickUpper,
            inv0,
            inv1
        );

        // Ensure required amounts with roundUp = true never exceed available inventory (prevents 1-wei rounding overdraw)
        while (usage.liquidity > 0) {
            uint256 req0 = SqrtPriceMath.getAmount0Delta(spotPriceX96, sqrtUpperX96, usage.liquidity, true);
            uint256 req1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, spotPriceX96, usage.liquidity, true);
            if (req0 <= inv0 && req1 <= inv1) {
                usage.amount0Used = req0;
                usage.amount1Used = req1;
                usage.dust0 = inv0 - req0;
                usage.dust1 = inv1 - req1;
                break;
            }
            usage.liquidity--;
        }

        if (usage.liquidity == 0) revert ZeroLiquidity();
        if (usage.liquidity < params.minLiquidity) {
            revert InsufficientLiquidityMinted(usage.liquidity, params.minLiquidity);
        }
        if (params.maxDustBps > 0 && usage.dustBps > params.maxDustBps) {
            revert DustToleranceExceeded(usage.dustBps, params.maxDustBps);
        }

        // Step 4: Add new asymmetric liquidity to pool
        (BalanceDelta d2, ) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: params.newTickLower,
                tickUpper: params.newTickUpper,
                liquidityDelta: int256(uint256(usage.liquidity)),
                salt: POSITION_SALT
            }),
            ""
        );

        // Step 5: Update state
        tickLower = params.newTickLower;
        tickUpper = params.newTickUpper;
        liquidity = usage.liquidity;
        idle0 = usage.dust0;
        idle1 = usage.dust1;

        // Step 6: Settle net deltas (take positive credits, settle negative debts)
        _settleNet(poolKey.currency0, d1.amount0() + d2.amount0());
        _settleNet(poolKey.currency1, d1.amount1() + d2.amount1());

        // Step 7: Emit Rebalanced event
        emit Rebalanced(
            oldLower,
            oldUpper,
            oldLiq,
            params.newTickLower,
            params.newTickUpper,
            usage.liquidity,
            usage.dust0,
            usage.dust1,
            usage.dustBps
        );

        return abi.encode(usage.liquidity);
    }

    /// @dev Executes pro-rata liquidity removal for a withdrawal inside poolManager unlock context.
    function _handleWithdraw(uint128 proRataLiquidity) internal returns (bytes memory) {
        (BalanceDelta d, ) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(proRataLiquidity)),
                salt: POSITION_SALT
            }),
            ""
        );

        if (d.amount0() > 0) {
            poolManager.take(poolKey.currency0, address(this), uint256(uint128(d.amount0())));
        }
        if (d.amount1() > 0) {
            poolManager.take(poolKey.currency1, address(this), uint256(uint128(d.amount1())));
        }

        return abi.encode(d.amount0(), d.amount1());
    }

    /// @notice Settles a net balance delta for a specific currency with the PoolManager.
    /// @dev If net > 0, takes tokens from pool. If net < 0, pays debt by transferring tokens and calling settle().
    /// @param currency Currency being settled.
    /// @param netDelta Net balance delta.
    function _settleNet(Currency currency, int128 netDelta) internal {
        if (netDelta > 0) {
            poolManager.take(currency, address(this), uint256(uint128(netDelta)));
        } else if (netDelta < 0) {
            uint256 debt = uint256(uint128(-netDelta));
            if (currency.isAddressZero()) {
                poolManager.sync(currency);
                poolManager.settle{value: debt}();
            } else {
                poolManager.sync(currency);
                IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), debt);
                poolManager.settle();
            }
        }
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

    /// @notice Allows the vault to receive native ETH from PoolManager when settling native currency.
    receive() external payable {}
}
