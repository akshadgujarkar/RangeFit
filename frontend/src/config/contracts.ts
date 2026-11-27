import { parseAbi, type Address } from "viem";

export const DEFAULT_HOOK_ADDRESS: Address =
  (import.meta.env.VITE_HOOK_ADDRESS as Address) ||
  "0x0000000000000000000000000000000000000000";

export const DEFAULT_TOKEN0_ADDRESS: Address =
  (import.meta.env.VITE_TOKEN0_ADDRESS as Address) ||
  "0x1111111111111111111111111111111111111111";

export const DEFAULT_TOKEN1_ADDRESS: Address =
  (import.meta.env.VITE_TOKEN1_ADDRESS as Address) ||
  "0x2222222222222222222222222222222222222222";

export const RangeFitHookAbi = parseAbi([
  // Core Views
  "function totalVaultValue() external view returns (uint256)",
  "function userValue(address user) external view returns (uint256)",
  "function position() external view returns (int24 currentTickLower, int24 currentTickUpper, uint128 currentLiquidity)",
  "function inventory() external view returns (uint256 inv0, uint256 inv1)",
  "function idle0() external view returns (uint256)",
  "function idle1() external view returns (uint256)",
  "function totalShares() external view returns (uint256)",
  "function shares(address account) external view returns (uint256)",
  "function emaSqrtPriceX96() external view returns (uint160)",
  "function rebalanceDue() external view returns (bool)",
  "function feeSkewEnabled() external view returns (bool)",
  "function baseFee() external view returns (uint24)",
  "function feeSensitivity() external view returns (uint24)",
  "function minFee() external view returns (uint24)",
  "function maxFee() external view returns (uint24)",
  "function targetRatioBps() external view returns (uint16)",
  "function cooldown() external view returns (uint32)",
  "function lastRebalance() external view returns (uint32)",
  "function poolConfigured() external view returns (bool)",
  "function poolId() external view returns (bytes32)",
  "function poolKey() external view returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)",

  // Previews
  "function previewDeposit(uint256 amount0, uint256 amount1) external view returns (uint256 sharesMinted)",
  "function previewWithdraw(uint256 sharesToBurn) external view returns (uint256 amount0Out, uint256 amount1Out)",
  "function previewRebalance(int24 newTickLower, int24 newTickUpper) external view returns (uint128 newLiquidity, uint256 used0, uint256 used1, uint256 dust0, uint256 dust1, uint256 dustBps)",

  // User Mutative Functions
  "function deposit(uint256 amount0, uint256 amount1, uint256 minShares) external returns (uint256 sharesMinted)",
  "function withdraw(uint256 sharesToBurn, uint256 minAmount0, uint256 minAmount1) external returns (uint256 amount0Out, uint256 amount1Out)",

  // Keeper Mutative Functions
  "function rebalance((int24 newTickLower, int24 newTickUpper, uint128 minLiquidity, uint256 maxDustBps) params) external returns (uint128 newLiquidity)",

  // Events
  "event Deposit(address indexed sender, uint256 amount0, uint256 amount1, uint256 sharesMinted)",
  "event Withdraw(address indexed sender, uint256 sharesBurned, uint256 amount0Out, uint256 amount1Out)",
  "event Rebalanced(int24 oldTickLower, int24 oldTickUpper, uint128 oldLiquidity, int24 newTickLower, int24 newTickUpper, uint128 newLiquidity, uint256 idle0, uint256 idle1, uint256 dustBps)",
  "event EmaUpdated(uint160 oldEma, uint160 newEma)",
  "event FeeSkewUpdated(bool enabled, uint24 baseFee, uint24 feeSensitivity, uint16 targetRatioBps)",
]);

export const ERC20Abi = parseAbi([
  "function name() external view returns (string)",
  "function symbol() external view returns (string)",
  "function decimals() external view returns (uint8)",
  "function totalSupply() external view returns (uint256)",
  "function balanceOf(address account) external view returns (uint256)",
  "function allowance(address owner, address spender) external view returns (uint256)",
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function transfer(address recipient, uint256 amount) external returns (bool)",
  "function transferFrom(address sender, address recipient, uint256 amount) external returns (bool)",
]);
