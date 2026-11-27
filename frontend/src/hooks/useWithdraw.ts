import { useState } from "react";
import { useAccount, useWriteContract } from "wagmi";
import { DEFAULT_HOOK_ADDRESS, RangeFitHookAbi } from "../config/contracts";

export function useWithdraw() {
  const { isConnected } = useAccount();
  const { writeContractAsync } = useWriteContract();

  const [status, setStatus] = useState<
    "idle" | "withdrawing" | "success" | "error"
  >("idle");
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [txHash, setTxHash] = useState<string | null>(null);

  const calculatePreviewWithdraw = (
    sharesToBurn: bigint,
    totalShares: bigint,
    inv0: number,
    inv1: number
  ) => {
    if (totalShares === 0n || sharesToBurn === 0n) {
      return { estToken0: 0, estToken1: 0 };
    }
    const frac = Number(sharesToBurn) / Number(totalShares);
    return {
      estToken0: inv0 * frac,
      estToken1: inv1 * frac,
    };
  };

  const handleWithdraw = async (sharesToBurn: bigint) => {
    if (sharesToBurn <= 0n) {
      setErrorMessage("Please specify a valid share amount to withdraw.");
      return;
    }

    try {
      setStatus("withdrawing");
      setErrorMessage(null);

      if (!isConnected || DEFAULT_HOOK_ADDRESS === "0x0000000000000000000000000000000000000000") {
        // Simulated execution for interactive demo mode
        await new Promise((resolve) => setTimeout(resolve, 1200));
        setTxHash("0x" + Array.from({ length: 64 }, () => Math.floor(Math.random() * 16).toString(16)).join(""));
        setStatus("success");
        return;
      }

      const hash = await writeContractAsync({
        address: DEFAULT_HOOK_ADDRESS,
        abi: RangeFitHookAbi,
        functionName: "withdraw",
        args: [sharesToBurn, 0n, 0n],
      });

      setTxHash(hash);
      setStatus("success");
    } catch (err: any) {
      console.error("Withdraw error:", err);
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
    handleWithdraw,
    calculatePreviewWithdraw,
    status,
    errorMessage,
    txHash,
    reset,
  };
}
