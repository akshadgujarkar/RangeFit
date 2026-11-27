import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { formatUnits } from "viem";
import { DEFAULT_HOOK_ADDRESS, RangeFitHookAbi } from "../config/contracts";

export interface VaultData {
  isConfigured: boolean;
  totalVaultValueUsd: number;
  totalShares: bigint;
  userShares: bigint;
  userValueUsd: number;
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
  inv0: number;
  inv1: number;
  idle0: number;
  idle1: number;
  spotPrice: number;
  priceLower: number;
  priceUpper: number;
  rangeProgressPercent: number;
  rebalanceDue: boolean;
  feeSkewEnabled: boolean;
  baseFeePercent: number;
  token0FeePercent: number;
  token1FeePercent: number;
  inventoryRatioToken0: number;
  targetRatioPercent: number;
  refetch: () => void;
}

// Convert tick to price: 1.0001^tick
function tickToPrice(tick: number): number {
  return Math.pow(1.0001, tick);
}

export function useRangeFitVault(): VaultData {
  const { address } = useAccount();
  const hookAddress = DEFAULT_HOOK_ADDRESS;

  const { data, refetch } = useReadContracts({
    contracts: [
      { address: hookAddress, abi: RangeFitHookAbi, functionName: "poolConfigured" },
      { address: hookAddress, abi: RangeFitHookAbi, functionName: "totalVaultValue" },
      { address: hookAddress, abi: RangeFitHookAbi, functionName: "position" },
      { address: hookAddress, abi: RangeFitHookAbi, functionName: "inventory" },
      { address: hookAddress, abi: RangeFitHookAbi, functionName: "idle0" },
      { address: hookAddress, abi: RangeFitHookAbi, functionName: "idle1" },
      { address: hookAddress, abi: RangeFitHookAbi, functionName: "totalShares" },
      {
        address: hookAddress,
        abi: RangeFitHookAbi,
        functionName: "shares",
        args: [address || "0x0000000000000000000000000000000000000000"],
      },
      {
        address: hookAddress,
        abi: RangeFitHookAbi,
        functionName: "userValue",
        args: [address || "0x0000000000000000000000000000000000000000"],
      },
      { address: hookAddress, abi: RangeFitHookAbi, functionName: "emaSqrtPriceX96" },
      { address: hookAddress, abi: RangeFitHookAbi, functionName: "rebalanceDue" },
      { address: hookAddress, abi: RangeFitHookAbi, functionName: "feeSkewEnabled" },
      { address: hookAddress, abi: RangeFitHookAbi, functionName: "baseFee" },
      { address: hookAddress, abi: RangeFitHookAbi, functionName: "feeSensitivity" },
      { address: hookAddress, abi: RangeFitHookAbi, functionName: "targetRatioBps" },
    ],
  });

  const poolConfigured = data?.[0]?.result as boolean | undefined;

  // If connected to a live contract that is configured
  if (poolConfigured) {
    const rawVaultVal = (data?.[1]?.result as bigint) || 0n;
    const rawPos = data?.[2]?.result as [number, number, bigint] | undefined;
    const rawInv = data?.[3]?.result as [bigint, bigint] | undefined;
    const rawIdle0 = (data?.[4]?.result as bigint) || 0n;
    const rawIdle1 = (data?.[5]?.result as bigint) || 0n;
    const rawTotalShares = (data?.[6]?.result as bigint) || 0n;
    const rawUserShares = (data?.[7]?.result as bigint) || 0n;
    const rawUserVal = (data?.[8]?.result as bigint) || 0n;
    const rawEmaSqrtPrice = (data?.[9]?.result as bigint) || 0n;
    const isRebalanceDue = (data?.[10]?.result as boolean) || false;
    const isFeeSkewEnabled = (data?.[11]?.result as boolean) || false;
    const rawBaseFee = Number((data?.[12]?.result as number) || 3000); // 3000 = 0.3%
    const rawSensitivity = Number((data?.[13]?.result as number) || 5);
    const rawTargetRatio = Number((data?.[14]?.result as number) || 5000);

    const tickLower = rawPos ? rawPos[0] : -120;
    const tickUpper = rawPos ? rawPos[1] : 120;
    const liquidity = rawPos ? rawPos[2] : 0n;

    const inv0 = Number(formatUnits(rawInv?.[0] || 0n, 18));
    const inv1 = Number(formatUnits(rawInv?.[1] || 0n, 6)); // assuming token1 is USDC
    const idle0 = Number(formatUnits(rawIdle0, 18));
    const idle1 = Number(formatUnits(rawIdle1, 6));

    // Calculate spot price from sqrtPriceX96: (sqrtPriceX96 / 2^96)^2 * 10^(decimals0 - decimals1)
    let spotPrice = 2500.0;
    if (rawEmaSqrtPrice > 0n) {
      const q96 = BigInt(2) ** BigInt(96);
      const ratio = Number(rawEmaSqrtPrice) / Number(q96);
      spotPrice = ratio * ratio * 1e12; // adjust for 18 vs 6 decimals
    }

    const priceLower = tickToPrice(tickLower) * 1e12;
    const priceUpper = tickToPrice(tickUpper) * 1e12;

    const rangeProgressPercent = Math.max(
      0,
      Math.min(100, ((spotPrice - priceLower) / (priceUpper - priceLower)) * 100)
    );

    const val0Usd = inv0 * spotPrice;
    const val1Usd = inv1;
    const totalValUsd = val0Usd + val1Usd;
    const invRatio0 = totalValUsd > 0 ? (val0Usd / totalValUsd) * 100 : 50;

    const skewBps = ((invRatio0 - rawTargetRatio / 100) / 100) * 10000;
    const feeDelta = (skewBps * rawSensitivity) / 100;
    const baseFeePct = rawBaseFee / 10000; // e.g. 0.30%
    const token0FeePercent = Math.max(0.05, Math.min(1.0, (rawBaseFee + feeDelta) / 10000));
    const token1FeePercent = Math.max(0.05, Math.min(1.0, (rawBaseFee - feeDelta) / 10000));

    return {
      isConfigured: true,
      totalVaultValueUsd: Number(formatUnits(rawVaultVal, 6)),
      totalShares: rawTotalShares,
      userShares: rawUserShares,
      userValueUsd: Number(formatUnits(rawUserVal, 6)),
      tickLower,
      tickUpper,
      liquidity,
      inv0,
      inv1,
      idle0,
      idle1,
      spotPrice,
      priceLower,
      priceUpper,
      rangeProgressPercent,
      rebalanceDue: isRebalanceDue,
      feeSkewEnabled: isFeeSkewEnabled,
      baseFeePercent: baseFeePct,
      token0FeePercent,
      token1FeePercent,
      inventoryRatioToken0: invRatio0,
      targetRatioPercent: rawTargetRatio / 100,
      refetch,
    };
  }

  // Fallback demo state mirroring verified Milestone 8 simulation & keeper testnet data
  // Spot ETH: $2,540, Range: [$2,480, $2,600], $425,000 TVL, 54% ETH / 46% USDC
  const spotPrice = 2540.25;
  const priceLower = 2480.0;
  const priceUpper = 2600.0;
  const rangeProgressPercent = ((spotPrice - priceLower) / (priceUpper - priceLower)) * 100;

  return {
    isConfigured: false,
    totalVaultValueUsd: 428750.0,
    totalShares: 428750000000n,
    userShares: 12500000000n,
    userValueUsd: 12500.0,
    tickLower: -240,
    tickUpper: 240,
    liquidity: 185000000000000000000n,
    inv0: 91.25, // ~91.25 WETH
    inv1: 196975.0, // ~196,975 USDC
    idle0: 0.12,
    idle1: 250.0,
    spotPrice,
    priceLower,
    priceUpper,
    rangeProgressPercent,
    rebalanceDue: false,
    feeSkewEnabled: true,
    baseFeePercent: 0.3,
    token0FeePercent: 0.34, // higher fee to sell ETH (vault has excess ETH)
    token1FeePercent: 0.26, // discounted fee to buy ETH (restoring vault balance)
    inventoryRatioToken0: 54.1,
    targetRatioPercent: 50.0,
    refetch,
  };
}
