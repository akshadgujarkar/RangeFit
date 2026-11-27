import {
  createPublicClient,
  createWalletClient,
  http,
  encodePacked,
  keccak256,
  toHex,
  type PublicClient,
  type WalletClient,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { RangeFitHookAbi } from "../abi/RangeFitHookAbi.js";
import { IPoolManagerAbi } from "../abi/IPoolManagerAbi.js";
import { type KeeperConfig } from "../config/config.js";
import {
  evaluateRebalance,
  type PoolVaultState,
  type RebalanceDecision,
} from "./decisionEngine.js";
import {
  solveOptimalRange,
  type SolvedRebalanceParams,
} from "./solverService.js";

export function computePoolStateSlot(poolId: Hex): Hex {
  // Uniswap v4 POOLS_SLOT = 6
  return keccak256(
    encodePacked(
      ["bytes32", "bytes32"],
      [poolId, toHex(6n, { size: 32 })]
    )
  );
}

export function parseSlot0(data: Hex): { spotPriceX96: bigint; currentTick: number } {
  const dataBigInt = BigInt(data);
  const spotPriceX96 = dataBigInt & ((1n << 160n) - 1n);
  let rawTick = Number((dataBigInt >> 160n) & 0xffffffn);
  // Sign extend 24-bit signed integer
  if (rawTick >= 0x800000) {
    rawTick -= 0x1000000;
  }
  return { spotPriceX96, currentTick: rawTick };
}

export class KeeperService {
  private config: KeeperConfig;
  private publicClient: PublicClient;
  private walletClient?: WalletClient;
  private keeperAddress?: Address;

  constructor(config: KeeperConfig) {
    this.config = config;
    this.publicClient = createPublicClient({
      transport: http(config.rpcUrl),
    });

    if (config.privateKey) {
      const account = privateKeyToAccount(config.privateKey);
      this.keeperAddress = account.address;
      this.walletClient = createWalletClient({
        account,
        transport: http(config.rpcUrl),
      });
    }
  }

  /**
   * Fetches the complete real-time state of the vault and pool.
   */
  async fetchState(): Promise<PoolVaultState> {
    const hook = this.config.hookAddress;

    // Read poolKey & poolId
    const [currency0, currency1, fee, tickSpacing, hookAddr] =
      await this.publicClient.readContract({
        address: hook,
        abi: RangeFitHookAbi,
        functionName: "poolKey",
      });

    const poolId = await this.publicClient.readContract({
      address: hook,
      abi: RangeFitHookAbi,
      functionName: "poolId",
    });

    // Read PoolManager address from hook or config
    const poolManagerAddress = this.config.poolManagerAddress;
    if (!poolManagerAddress) {
      throw new Error("PoolManager address must be configured or passed in config");
    }

    // Read slot0 from PoolManager via extsload
    const stateSlot = computePoolStateSlot(poolId);
    const rawSlot0 = (await this.publicClient.readContract({
      address: poolManagerAddress,
      abi: IPoolManagerAbi,
      functionName: "extsload",
      args: [stateSlot],
    })) as Hex;
    const { spotPriceX96, currentTick } = parseSlot0(rawSlot0);

    // Read hook state
    const [tickLower, tickUpper, activeLiquidity] =
      await this.publicClient.readContract({
        address: hook,
        abi: RangeFitHookAbi,
        functionName: "position",
      });

    const [inv0, inv1] = await this.publicClient.readContract({
      address: hook,
      abi: RangeFitHookAbi,
      functionName: "inventory",
    });

    const idle0 = await this.publicClient.readContract({
      address: hook,
      abi: RangeFitHookAbi,
      functionName: "idle0",
    });

    const idle1 = await this.publicClient.readContract({
      address: hook,
      abi: RangeFitHookAbi,
      functionName: "idle1",
    });

    const emaPriceX96 = await this.publicClient.readContract({
      address: hook,
      abi: RangeFitHookAbi,
      functionName: "emaSqrtPriceX96",
    });

    const cooldown = await this.publicClient.readContract({
      address: hook,
      abi: RangeFitHookAbi,
      functionName: "cooldown",
    });

    const lastRebalance = await this.publicClient.readContract({
      address: hook,
      abi: RangeFitHookAbi,
      functionName: "lastRebalance",
    });

    const maxDeviationBps = await this.publicClient.readContract({
      address: hook,
      abi: RangeFitHookAbi,
      functionName: "maxDeviationBps",
    });

    const minWidthTicks = await this.publicClient.readContract({
      address: hook,
      abi: RangeFitHookAbi,
      functionName: "minWidthTicks",
    });

    const maxWidthTicks = await this.publicClient.readContract({
      address: hook,
      abi: RangeFitHookAbi,
      functionName: "maxWidthTicks",
    });

    const rebalanceDue = await this.publicClient.readContract({
      address: hook,
      abi: RangeFitHookAbi,
      functionName: "rebalanceDue",
    });

    const keeperOnly = await this.publicClient.readContract({
      address: hook,
      abi: RangeFitHookAbi,
      functionName: "keeperOnly",
    });

    let isAuthorizedKeeper = true;
    if (keeperOnly && this.keeperAddress) {
      isAuthorizedKeeper = await this.publicClient.readContract({
        address: hook,
        abi: RangeFitHookAbi,
        functionName: "isKeeper",
        args: [this.keeperAddress],
      });
    }

    const currentBlock = await this.publicClient.getBlock();
    const currentTimestamp = Number(currentBlock.timestamp);

    return {
      currentTick,
      spotPriceX96,
      emaPriceX96: emaPriceX96 === 0n ? spotPriceX96 : emaPriceX96,
      tickLower,
      tickUpper,
      activeLiquidity,
      idle0,
      idle1,
      totalInv0: inv0,
      totalInv1: inv1,
      rebalanceDue,
      cooldown: Number(cooldown),
      lastRebalance: Number(lastRebalance),
      currentTimestamp,
      maxDeviationBps,
      minWidthTicks,
      maxWidthTicks,
      keeperOnly,
      isAuthorizedKeeper,
    };
  }

  /**
   * Executes a single monitoring cycle.
   */
  async runCycle(): Promise<void> {
    console.log(`[${new Date().toISOString()}] Polling RangeFit vault state...`);
    const state = await this.fetchState();

    console.log(
      `  • Spot Tick: ${state.currentTick} | Active Range: [${state.tickLower}, ${state.tickUpper}] | Liquidity: ${state.activeLiquidity}`
    );
    console.log(
      `  • Inventory: Token0=${state.totalInv0} (idle: ${state.idle0}) | Token1=${state.totalInv1} (idle: ${state.idle1})`
    );

    const decision: RebalanceDecision = evaluateRebalance(
      state,
      this.config.edgeThresholdPercent
    );

    console.log(`  • Decision: ${decision.reason}`);

    if (!decision.shouldRebalance) {
      return;
    }

    // Solve for lowest-dust optimal range
    const solved = solveOptimalRange({
      spotPriceX96: state.spotPriceX96,
      inv0: state.totalInv0,
      inv1: state.totalInv1,
      tickSpacing: 60, // standard spacing
      targetWidthTicks: this.config.targetWidthTicks,
      minWidthTicks: this.config.minWidthTicks ?? state.minWidthTicks,
      maxWidthTicks: this.config.maxWidthTicks ?? state.maxWidthTicks,
      maxDustBps: this.config.maxDustBps,
    });

    if (!solved) {
      console.warn("  [!] Solver could not find a feasible range conforming to dust & width limits.");
      return;
    }

    console.log(
      `  • Solved Target Range: [${solved.newTickLower}, ${solved.newTickUpper}] (Width: ${
        solved.newTickUpper - solved.newTickLower
      } ticks)`
    );
    console.log(
      `  • Expected Liquidity: ${solved.expectedLiquidity} (min: ${solved.minLiquidity}) | Residual Dust: ${solved.dustBps} bps`
    );

    const rebalanceArgs = [
      {
        newTickLower: solved.newTickLower,
        newTickUpper: solved.newTickUpper,
        minLiquidity: solved.minLiquidity,
        maxDustBps: solved.maxDustBps,
      },
    ] as const;

    // Pre-flight on-chain simulation
    console.log("  • Simulating rebalance transaction via eth_call...");
    try {
      const { result } = await this.publicClient.simulateContract({
        address: this.config.hookAddress,
        abi: RangeFitHookAbi,
        functionName: "rebalance",
        args: rebalanceArgs,
        account: this.keeperAddress,
      });
      console.log(`  ✓ Simulation succeeded! Deployed liquidity: ${result}`);
    } catch (simErr: any) {
      console.error(`  ✗ Simulation failed: ${simErr.message}`);
      return;
    }

    if (this.config.dryRun) {
      console.log("  [DRY-RUN] Rebalance simulated successfully. No transaction broadcast.");
      return;
    }

    if (!this.walletClient || !this.keeperAddress) {
      console.warn("  [!] No wallet client or private key configured. Cannot submit transaction.");
      return;
    }

    // Execute live on-chain transaction
    console.log("  • Broadcasting rebalance transaction to network...");
    const txHash = await this.walletClient.writeContract({
      address: this.config.hookAddress,
      abi: RangeFitHookAbi,
      functionName: "rebalance",
      args: rebalanceArgs,
    });

    console.log(`  ✓ Transaction broadcast: ${txHash}`);
    console.log("  • Waiting for receipt...");
    const receipt = await this.publicClient.waitForTransactionReceipt({ hash: txHash });
    console.log(
      `  ✓ Rebalance confirmed in block ${receipt.blockNumber} (Gas Used: ${receipt.gasUsed})`
    );
  }

  /**
   * Starts the keeper in continuous loop or single execution mode.
   */
  async start(): Promise<void> {
    console.log("=================================================");
    console.log("RangeFit Keeper Service Starting");
    console.log(`  Hook Address:    ${this.config.hookAddress}`);
    console.log(`  RPC URL:         ${this.config.rpcUrl}`);
    console.log(`  Mode:            ${this.config.dryRun ? "DRY-RUN" : "LIVE"}`);
    console.log(`  Poll Interval:   ${this.config.pollIntervalMs}ms`);
    console.log("=================================================");

    if (this.config.runOnce) {
      await this.runCycle();
      return;
    }

    while (true) {
      try {
        await this.runCycle();
      } catch (err: any) {
        console.error(`[!] Keeper cycle error: ${err.message}`);
      }
      await new Promise((resolve) => setTimeout(resolve, this.config.pollIntervalMs));
    }
  }
}
