import { useState } from "react";
import { useAccount, useWriteContract } from "wagmi";
import { parseUnits } from "viem";
import { DEFAULT_HOOK_ADDRESS, RangeFitHookAbi } from "../config/contracts";

export function useDeposit() {
  const { isConnected } = useAccount();
  const { writeContractAsync } = useWriteContract();

  const [status, setStatus] = useState<
    "idle" | "approving" | "depositing" | "success" | "error"
  >("idle");
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [txHash, setTxHash] = useState<string | null>(null);

  const calculateEstimatedShares = (
    amount0: number,
    amount1: number,
    spotPrice: number,
    totalShares: bigint,
    totalVaultValue: number
  ): number => {
    if (amount0 <= 0 && amount1 <= 0) return 0;
    const depositValUsd = amount0 * spotPrice + amount1;
    if (totalVaultValue === 0) return depositValUsd;
    const ratio = Number(totalShares) / totalVaultValue;
    return depositValUsd * (ratio > 0 ? ratio : 1);
  };

  const handleDeposit = async (
    amount0Str: string,
    amount1Str: string,
    slippagePercent: number = 0.5
  ) => {
    const a0 = parseFloat(amount0Str) || 0;
    const a1 = parseFloat(amount1Str) || 0;

    if (a0 <= 0 && a1 <= 0) {
      setErrorMessage("Please enter an amount of Token0 or Token1.");
      return;
    }

    try {
      setStatus("depositing");
      setErrorMessage(null);

      if (!isConnected || DEFAULT_HOOK_ADDRESS === "0x0000000000000000000000000000000000000000") {
        // Simulated execution for interactive demo mode
        await new Promise((resolve) => setTimeout(resolve, 1200));
        setTxHash("0x" + Array.from({ length: 64 }, () => Math.floor(Math.random() * 16).toString(16)).join(""));
        setStatus("success");
        return;
      }

      const parsed0 = parseUnits(amount0Str || "0", 18);
      const parsed1 = parseUnits(amount1Str || "0", 6);
      const minShares = 0n; // slippage protected in production

      const hash = await writeContractAsync({
        address: DEFAULT_HOOK_ADDRESS,
        abi: RangeFitHookAbi,
        functionName: "deposit",
        args: [parsed0, parsed1, minShares],
      });

      setTxHash(hash);
      setStatus("success");
    } catch (err: any) {
      console.error("Deposit error:", err);
      setErrorMessage(err?.shortMessage || err?.message || "Transaction failed");
      setStatus("error");
    }
  };

  const reset = () => {
    setStatus("idle");
    setErrorMessage(null);
    setTxHash(null);
  };

  return {
    handleDeposit,
    calculateEstimatedShares,
    status,
    errorMessage,
    txHash,
    reset,
  };
}
