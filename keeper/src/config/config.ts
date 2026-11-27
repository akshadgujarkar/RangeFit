import dotenv from "dotenv";
import { type Address, type Hex } from "viem";

dotenv.config();

export interface KeeperConfig {
  rpcUrl: string;
  privateKey?: Hex;
  hookAddress: Address;
  poolManagerAddress?: Address;
  pollIntervalMs: number;
  edgeThresholdPercent: number; // e.g. 0.20 = within 20% of boundary
  maxDustBps: bigint; // e.g. 1000n = 10%
  targetWidthTicks: number; // e.g. 240 ticks
  minWidthTicks?: number;
  maxWidthTicks?: number;
  dryRun: boolean;
  runOnce: boolean;
}

export function loadConfig(cliArgs: string[] = []): KeeperConfig {
  const isDryRun = cliArgs.includes("--dry-run") || process.env.KEEPER_DRY_RUN === "true";
  const isOnce = cliArgs.includes("--once") || process.env.KEEPER_ONCE === "true";

  const hookAddress = (process.env.RANGEFIT_HOOK_ADDRESS ||
    "0x0000000000000000000000000000000000000000") as Address;

  return {
    rpcUrl: process.env.RPC_URL || "http://127.0.0.1:8545",
    privateKey: process.env.KEEPER_PRIVATE_KEY as Hex | undefined,
    hookAddress,
    poolManagerAddress: process.env.POOL_MANAGER_ADDRESS as Address | undefined,
    pollIntervalMs: Number(process.env.POLL_INTERVAL_MS || "5000"),
    edgeThresholdPercent: Number(process.env.EDGE_THRESHOLD_PERCENT || "0.20"),
    maxDustBps: BigInt(process.env.MAX_DUST_BPS || "1000"),
    targetWidthTicks: Number(process.env.TARGET_WIDTH_TICKS || "240"),
    dryRun: isDryRun,
    runOnce: isOnce,
  };
}
