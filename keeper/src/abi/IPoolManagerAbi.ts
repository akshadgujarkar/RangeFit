import { parseAbi } from "viem";

export const IPoolManagerAbi = parseAbi([
  "function extsload(bytes32 slot) external view returns (bytes32)",
  "function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[])",
]);
