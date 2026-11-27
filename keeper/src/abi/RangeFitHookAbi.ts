import { parseAbi } from "viem";

export const RangeFitHookAbi = parseAbi([
  // Core view functions
  "function position() external view returns (int24 currentTickLower, int24 currentTickUpper, uint128 currentLiquidity)",
  "function inventory() external view returns (uint256 inv0, uint256 inv1)",
  "function idle0() external view returns (uint256)",
  "function idle1() external view returns (uint256)",
  "function liquidity() external view returns (uint128)",
  "function tickLower() external view returns (int24)",
  "function tickUpper() external view returns (int24)",
  "function emaSqrtPriceX96() external view returns (uint160)",
  "function cooldown() external view returns (uint32)",
  "function lastRebalance() external view returns (uint32)",
  "function maxDeviationBps() external view returns (uint256)",
  "function minWidthTicks() external view returns (int24)",
  "function maxWidthTicks() external view returns (int24)",
  "function rebalanceDue() external view returns (bool)",
  "function keeperOnly() external view returns (bool)",
  "function isKeeper(address keeper) external view returns (bool)",
  "function poolConfigured() external view returns (bool)",
  "function poolId() external view returns (bytes32)",
  "function poolKey() external view returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)",

  // Rebalance simulation and execution
  "function previewRebalance(int24 newTickLower, int24 newTickUpper) external view returns (uint128 newLiquidity, uint256 used0, uint256 used1, uint256 dust0, uint256 dust1, uint256 dustBps)",
  "function rebalance((int24 newTickLower, int24 newTickUpper, uint128 minLiquidity, uint256 maxDustBps) params) external returns (uint128 newLiquidity)",

  // Events
  "event Rebalanced(int24 oldTickLower, int24 oldTickUpper, uint128 oldLiquidity, int24 newTickLower, int24 newTickUpper, uint128 newLiquidity, uint256 idle0, uint256 idle1, uint256 dustBps)",
  "event EmaUpdated(uint160 oldEma, uint160 newEma)",
]);
