import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { spawn, execSync, type ChildProcess } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { existsSync } from "node:fs";
import { createPublicClient, http, type Address, type Hex } from "viem";
import { KeeperService } from "../src/services/keeperService.js";
import { RangeFitHookAbi } from "../src/abi/RangeFitHookAbi.js";

const anvilPath = existsSync(join(homedir(), ".foundry", "bin", "anvil.exe"))
  ? join(homedir(), ".foundry", "bin", "anvil.exe")
  : "anvil";

const forgePath = existsSync(join(homedir(), ".foundry", "bin", "forge.exe"))
  ? join(homedir(), ".foundry", "bin", "forge.exe")
  : "forge";

const ANVIL_PORT = 8548;
const RPC_URL = `http://127.0.0.1:${ANVIL_PORT}`;
const ANVIL_KEY: Hex = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

describe("Keeper End-to-End Integration Test on Anvil", () => {
  let anvilProcess: ChildProcess;
  let hookAddress: Address;
  let poolManagerAddress: Address;

  beforeAll(async () => {
    // 1. Start isolated local Anvil instance on port 8548
    anvilProcess = spawn(anvilPath, ["--port", String(ANVIL_PORT), "--silent"]);
    await new Promise((resolve) => setTimeout(resolve, 2000));

    // 2. Deploy infrastructure & initialize pool via SetupLocalAnvilScript
    const repoRoot = join(process.cwd(), "..");
    const deployOutput = execSync(
      `"${forgePath}" script script/SetupLocalAnvil.s.sol --rpc-url ${RPC_URL} --broadcast -vv`,
      { cwd: repoRoot, encoding: "utf-8" }
    );

    // 3. Parse contract addresses from script logs
    const hookMatch = deployOutput.match(/HOOK_ADDRESS:\s*(0x[a-fA-F0-9]{40})/);
    const pmMatch = deployOutput.match(/POOL_MANAGER:\s*(0x[a-fA-F0-9]{40})/);

    if (!hookMatch || !pmMatch) {
      throw new Error(`Failed to extract addresses from deployment output:\n${deployOutput}`);
    }

    hookAddress = hookMatch[1] as Address;
    poolManagerAddress = pmMatch[1] as Address;
  }, 120_000);

  afterAll(() => {
    if (anvilProcess) {
      anvilProcess.kill();
    }
  });

  it("Keeper detects out-of-range position, solves optimal bounds, and executes swapless rebalance", async () => {
    const publicClient = createPublicClient({ transport: http(RPC_URL) });

    // 1. Verify pre-rebalance state on chain
    const [tickLowerBefore, tickUpperBefore, liqBefore] = await publicClient.readContract({
      address: hookAddress,
      abi: RangeFitHookAbi,
      functionName: "position",
    });
    expect(tickLowerBefore).toBe(-180);
    expect(tickUpperBefore).toBe(60);
    expect(liqBefore).toBeGreaterThan(0n);

    // 2. Configure and run Keeper in single-cycle mode
    const keeper = new KeeperService({
      rpcUrl: RPC_URL,
      privateKey: ANVIL_KEY,
      hookAddress,
      poolManagerAddress,
      pollIntervalMs: 1000,
      edgeThresholdPercent: 0.40,
      maxDustBps: 2000n,
      targetWidthTicks: 240,
      dryRun: false,
      runOnce: true,
    });

    await keeper.runCycle();

    // 3. Verify post-rebalance state on chain
    const [tickLowerAfter, tickUpperAfter, liqAfter] = await publicClient.readContract({
      address: hookAddress,
      abi: RangeFitHookAbi,
      functionName: "position",
    });

    expect(liqAfter).toBeGreaterThan(0n);
    // Position bounds have re-centered around the new price
    expect(tickUpperAfter - tickLowerAfter).toBeGreaterThanOrEqual(60);
    expect(tickLowerAfter !== tickLowerBefore || tickUpperAfter !== tickUpperBefore).toBe(true);

    const rebalanceDue = await publicClient.readContract({
      address: hookAddress,
      abi: RangeFitHookAbi,
      functionName: "rebalanceDue",
    });
    expect(rebalanceDue).toBe(false);
  }, 60_000);
});
