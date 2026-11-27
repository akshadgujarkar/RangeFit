import { loadConfig } from "./config/config.js";
import { KeeperService } from "./services/keeperService.js";

async function main() {
  const args = process.argv.slice(2);
  const config = loadConfig(args);

  if (args.includes("--help") || args.includes("-h")) {
    console.log(`
RangeFit Keeper Service CLI

Usage:
  tsx src/index.ts [options]

Options:
  --dry-run       Simulate and log optimal rebalances without broadcasting transactions
  --once          Execute a single monitoring check and exit
  --help, -h      Display this help message

Environment Variables:
  RPC_URL                 JSON-RPC endpoint (default: http://127.0.0.1:8545)
  RANGEFIT_HOOK_ADDRESS   Deployed RangeFitHook contract address
  POOL_MANAGER_ADDRESS    Deployed Uniswap v4 PoolManager contract address
  KEEPER_PRIVATE_KEY      Private key for keeper signing account
  POLL_INTERVAL_MS        Polling interval in milliseconds (default: 5000)
  EDGE_THRESHOLD_PERCENT  Threshold to consider price near boundary (default: 0.20)
  TARGET_WIDTH_TICKS      Target width in ticks for solved range (default: 240)
  MAX_DUST_BPS            Maximum acceptable dust tolerance in basis points (default: 1000)
    `);
    process.exit(0);
  }

  const keeper = new KeeperService(config);
  await keeper.start();
}

main().catch((err) => {
  console.error("Fatal keeper error:", err);
  process.exit(1);
});
