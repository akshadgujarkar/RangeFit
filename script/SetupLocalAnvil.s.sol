// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {RangeFitHook} from "../src/RangeFitHook.sol";
import {IRangeFit} from "../src/interfaces/IRangeFit.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SimpleSwapHelper} from "../test/RangeFitRebalance.t.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Sets up a complete local Uniswap v4 environment on Anvil for keeper integration testing.
contract SetupLocalAnvilScript is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    function run() external {
        uint256 deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Anvil account 0
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Deploy PoolManager directly without etching
        IPoolManager poolManager = IPoolManager(V4PoolManagerDeployer.deploy(deployer));

        // 2. Deploy Currency Pair
        MockERC20 rawTokenA = new MockERC20("Token A", "TKNA", 18);
        MockERC20 rawTokenB = new MockERC20("Token B", "TKNB", 18);
        rawTokenA.mint(deployer, 1_000_000 ether);
        rawTokenB.mint(deployer, 1_000_000 ether);

        (MockERC20 token0, MockERC20 token1) = address(rawTokenA) < address(rawTokenB)
            ? (rawTokenA, rawTokenB)
            : (rawTokenB, rawTokenA);

        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));

        // 3. Mine and Deploy RangeFitHook using Foundry CREATE2 Deployer Proxy
        uint160 hookFlags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        (address hookAddress, bytes32 salt) = HookMiner.find(
            create2Deployer,
            hookFlags,
            type(RangeFitHook).creationCode,
            constructorArgs
        );

        RangeFitHook hook = new RangeFitHook{salt: salt}(poolManager);
        require(address(hook) == hookAddress, "Hook address mismatch");

        // 4. Initialize Pool
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        hook.setPoolKey(poolKey);

        // 5. Fund hook with initial deposit (1:3 ratio matching [-180, 60])
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        hook.deposit(100 ether, 300 ether, 0);

        // Deploy initial position [-180, 60]
        hook.rebalance(IRangeFit.RebalanceParams({
            newTickLower: -180,
            newTickUpper: 60,
            minLiquidity: 1 ether,
            maxDustBps: 1000
        }));

        // 6. Deploy SwapHelper & execute a swap to push tick near boundary and shift inventory
        SimpleSwapHelper swapHelper = new SimpleSwapHelper(poolManager);
        token0.approve(address(swapHelper), type(uint256).max);

        // Swap 150 ether token0 to push tick into near-boundary region (tick ~ -140)
        swapHelper.swap(
            poolKey,
            true, // zeroForOne
            150 ether,
            TickMath.MIN_SQRT_PRICE + 1
        );

        vm.stopBroadcast();

        // Log output for keeper configuration
        console2.log("=== DEPLOYMENT OUTPUT ===");
        console2.log("POOL_MANAGER:", address(poolManager));
        console2.log("HOOK_ADDRESS:", address(hook));
        console2.log("TOKEN0:", Currency.unwrap(currency0));
        console2.log("TOKEN1:", Currency.unwrap(currency1));
        console2.log("POOL_ID:", vm.toString(PoolId.unwrap(poolKey.toId())));
    }
}
