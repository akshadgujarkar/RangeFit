// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {RangeFitHook} from "../src/RangeFitHook.sol";
import {IRangeFit} from "../src/interfaces/IRangeFit.sol";

/// @notice Helper contract simulating an unauthorized external actor attempting to modify pool liquidity.
contract ExternalLiquidityAdder is IUnlockCallback {
    IPoolManager immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity) external {
        poolManager.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, int256));
        poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams(tickLower, tickUpper, liquidity, 0),
            ""
        );
        return "";
    }
}

contract RangeFitHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    PoolId poolId;

    RangeFitHook hook;
    uint160 hookFlags;

    ExternalLiquidityAdder externalAdder;

    function setUp() public {
        // Deploy Permit2, PoolManager, PositionManager, and SwapRouter
        deployArtifactsAndLabel();

        (currency0, currency1) = deployCurrencyPair();

        // Target hook permission flags: beforeSwap, afterSwap, beforeAddLiquidity
        hookFlags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );

        // Mine a CREATE2 salt that produces a hook address matching the flags
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            hookFlags,
            type(RangeFitHook).creationCode,
            constructorArgs
        );

        // Deploy the hook using CREATE2 with the mined salt
        hook = new RangeFitHook{salt: salt}(poolManager);
        require(address(hook) == hookAddress, "Hook address does not match mined address");

        // Initialize a dynamic fee pool (fee = DYNAMIC_FEE_FLAG) with tickSpacing 60
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Configure managed pool key
        hook.setPoolKey(poolKey);

        // Deploy external actor helper
        externalAdder = new ExternalLiquidityAdder(poolManager);
    }

    // =========================================================================
    // 1. Permission & Address Flag Tests
    // =========================================================================

    /// @notice Validates that the hook declares exact required permissions.
    function test_HookPermissions_MatchAddressFlags() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();

        // Required flags must be true
        assertTrue(perms.beforeSwap, "beforeSwap must be true");
        assertTrue(perms.afterSwap, "afterSwap must be true");
        assertTrue(perms.beforeAddLiquidity, "beforeAddLiquidity must be true");

        // All other flags must be false
        assertFalse(perms.beforeInitialize, "beforeInitialize must be false");
        assertFalse(perms.afterInitialize, "afterInitialize must be false");
        assertFalse(perms.beforeRemoveLiquidity, "beforeRemoveLiquidity must be false");
        assertFalse(perms.afterRemoveLiquidity, "afterRemoveLiquidity must be false");
        assertFalse(perms.beforeDonate, "beforeDonate must be false");
        assertFalse(perms.afterDonate, "afterDonate must be false");
        assertFalse(perms.beforeSwapReturnDelta, "beforeSwapReturnDelta must be false");
        assertFalse(perms.afterSwapReturnDelta, "afterSwapReturnDelta must be false");
        assertFalse(perms.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta must be false");
        assertFalse(perms.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta must be false");

        // Address bottom 14 bits must match hookFlags
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK,
            hookFlags,
            "Deployed address bottom bits must match permission flags"
        );
    }

    // =========================================================================
    // 2. Pool Initialization Tests
    // =========================================================================

    /// @notice Validates that dynamic-fee pool initialized cleanly with the hook.
    function test_PoolInitialization_DynamicFee() public view {
        // Assert pool key settings
        assertEq(poolKey.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "Pool fee must be DYNAMIC_FEE_FLAG");
        assertEq(address(poolKey.hooks), address(hook), "Pool hooks must be set to RangeFitHook");
        assertEq(poolKey.tickSpacing, 60, "Tick spacing should be 60");

        // Read pool state from PoolManager
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);
        assertEq(sqrtPriceX96, Constants.SQRT_PRICE_1_1, "Initial spot price must be 1:1");
        assertEq(tick, 0, "Initial tick must be 0 for 1:1 price");
        assertEq(protocolFee, 0, "Initial protocol fee is 0");
        assertEq(lpFee, 0, "Dynamic pool initial fee in slot0 is 0");
    }

    // =========================================================================
    // 3. Liquidity Gating Tests
    // =========================================================================

    /// @notice Validates that direct liquidity addition from external callers is strictly blocked by the hook.
    function test_Revert_UnauthorizedAddLiquidity_ExternalCaller() public {
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        // When external contract attempts modifyLiquidity on the pool,
        // RangeFitHook._beforeAddLiquidity reverts with UnauthorizedAddLiquidity(sender).
        vm.expectRevert();
        externalAdder.addLiquidity(poolKey, tickLower, tickUpper, 10e18);
    }

    // =========================================================================
    // 4. Access Control Tests
    // =========================================================================

    /// @notice Validates that unlockCallback cannot be called by arbitrary external callers.
    function test_Revert_UnlockCallback_NotPoolManager() public {
        vm.expectRevert();
        hook.unlockCallback("");
    }
}
