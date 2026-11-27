import React, { useState } from "react";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/lightswind/tabs";
import { Input } from "@/components/lightswind/input";
import { Slider } from "@/components/lightswind/slider";
import { VaultData } from "@/hooks/useRangeFitVault";
import { useDeposit } from "@/hooks/useDeposit";
import { useWithdraw } from "@/hooks/useWithdraw";
import { ArrowDownToLine, ArrowUpFromLine, CheckCircle2, AlertCircle } from "lucide-react";

interface DepositWithdrawProps {
  vault: VaultData;
}

export const DepositWithdraw: React.FC<DepositWithdrawProps> = ({ vault }) => {
  const [tab, setTab] = useState<string>("deposit");

  // Deposit Form State
  const [amount0, setAmount0] = useState<string>("1.0");
  const [amount1, setAmount1] = useState<string>("2540.0");

  // Withdraw Form State
  const [withdrawPercent, setWithdrawPercent] = useState<number>(50);

  const {
    handleDeposit,
    calculateEstimatedShares,
    status: depositStatus,
    errorMessage: depositError,
    reset: resetDeposit,
  } = useDeposit();

  const {
    handleWithdraw,
    calculatePreviewWithdraw,
    status: withdrawStatus,
    errorMessage: withdrawError,
    reset: resetWithdraw,
  } = useWithdraw();

  // Calculations for Deposit
  const parsed0 = parseFloat(amount0) || 0;
  const parsed1 = parseFloat(amount1) || 0;
  const totalDepositValUsd = parsed0 * vault.spotPrice + parsed1;
  const estSharesMinted = calculateEstimatedShares(
    parsed0,
    parsed1,
    vault.spotPrice,
    vault.totalShares,
    vault.totalVaultValueUsd
  );
  const futureTotalVal = vault.totalVaultValueUsd + totalDepositValUsd;
  const estPoolSharePct = futureTotalVal > 0 ? (totalDepositValUsd / futureTotalVal) * 100 : 0;

  // Calculations for Withdraw
  const sharesToBurn = (vault.userShares * BigInt(withdrawPercent)) / 100n;
  const { estToken0, estToken1 } = calculatePreviewWithdraw(
    sharesToBurn,
    vault.totalShares,
    vault.inv0,
    vault.inv1
  );
  const estWithdrawValUsd = estToken0 * vault.spotPrice + estToken1;

  // Preset Ratio Handlers
  const setPresetRatio = (mode: "eth" | "balanced" | "usdc") => {
    if (mode === "eth") {
      setAmount0("2.0");
      setAmount1("0");
    } else if (mode === "balanced") {
      setAmount0("1.0");
      setAmount1("2540.0");
    } else {
      setAmount0("0");
      setAmount1("5000.0");
    }
  };

  return (
    <div className="rounded-xl border border-white/[0.08] bg-[#111214] p-5 space-y-4">
      {/* Header */}
      <div className="flex items-center justify-between pb-1">
        <div>
          <h2 className="text-sm font-medium text-zinc-100">
            Vault Liquidity
          </h2>
          <p className="text-xs text-zinc-400 mt-0.5">
            Deposit any ratio without swapping • Pro-rata exit
          </p>
        </div>
        <span className="text-[11px] font-mono text-emerald-400 bg-emerald-500/10 border border-emerald-500/20 px-2 py-0.5 rounded">
          Zero Swap Slippage
        </span>
      </div>

      <Tabs value={tab} onValueChange={setTab} className="w-full">
        <TabsList className="grid w-full grid-cols-2 mb-4 bg-zinc-900 border border-white/[0.08] p-1 rounded-lg">
          <TabsTrigger value="deposit" className="text-xs font-medium py-1.5 rounded-md">
            <ArrowDownToLine className="h-3.5 w-3.5 mr-1.5" />
            Any-Ratio Deposit
          </TabsTrigger>
          <TabsTrigger value="withdraw" className="text-xs font-medium py-1.5 rounded-md">
            <ArrowUpFromLine className="h-3.5 w-3.5 mr-1.5" />
            Pro-Rata Withdraw
          </TabsTrigger>
        </TabsList>

        {/* ================= DEPOSIT TAB ================= */}
        <TabsContent value="deposit" className="space-y-4 pt-1">
          {/* Quick Presets */}
          <div className="flex items-center justify-between text-xs">
            <span className="text-zinc-400">Ratio presets</span>
            <div className="flex gap-1.5">
              <button
                type="button"
                onClick={() => setPresetRatio("eth")}
                className="h-6 px-2 text-[11px] font-mono rounded bg-zinc-900 border border-white/[0.08] text-zinc-400 hover:text-zinc-200 transition-colors"
              >
                100% ETH
              </button>
              <button
                type="button"
                onClick={() => setPresetRatio("balanced")}
                className="h-6 px-2 text-[11px] font-mono rounded bg-zinc-900 border border-white/[0.15] text-zinc-200 hover:text-white transition-colors"
              >
                50 / 50
              </button>
              <button
                type="button"
                onClick={() => setPresetRatio("usdc")}
                className="h-6 px-2 text-[11px] font-mono rounded bg-zinc-900 border border-white/[0.08] text-zinc-400 hover:text-zinc-200 transition-colors"
              >
                100% USDC
              </button>
            </div>
          </div>

          {/* Token0 Input */}
          <div className="rounded-lg border border-white/[0.08] bg-[#16171a] p-3 space-y-1">
            <div className="flex justify-between text-xs text-zinc-400">
              <span>Token0 (WETH)</span>
              <span className="font-mono text-[11px]">Balance: 12.50</span>
            </div>
            <div className="flex items-center gap-2">
              <Input
                type="number"
                step="0.01"
                min="0"
                value={amount0}
                onChange={(e) => setAmount0(e.target.value)}
                className="border-none bg-transparent text-xl font-mono tabular-nums font-semibold text-zinc-100 focus-visible:ring-0 p-0 h-auto"
                placeholder="0.0"
              />
              <span className="text-xs font-mono font-medium text-zinc-300 bg-zinc-800 border border-white/[0.08] px-2 py-0.5 rounded">
                WETH
              </span>
            </div>
            <div className="text-[11px] text-zinc-500 font-mono">
              ≈ ${(parsed0 * vault.spotPrice).toFixed(2)} USD
            </div>
          </div>

          {/* Token1 Input */}
          <div className="rounded-lg border border-white/[0.08] bg-[#16171a] p-3 space-y-1">
            <div className="flex justify-between text-xs text-zinc-400">
              <span>Token1 (USDC)</span>
              <span className="font-mono text-[11px]">Balance: 25,000.00</span>
            </div>
            <div className="flex items-center gap-2">
              <Input
                type="number"
                step="1"
                min="0"
                value={amount1}
                onChange={(e) => setAmount1(e.target.value)}
                className="border-none bg-transparent text-xl font-mono tabular-nums font-semibold text-zinc-100 focus-visible:ring-0 p-0 h-auto"
                placeholder="0.0"
              />
              <span className="text-xs font-mono font-medium text-zinc-300 bg-zinc-800 border border-white/[0.08] px-2 py-0.5 rounded">
                USDC
              </span>
            </div>
            <div className="text-[11px] text-zinc-500 font-mono">
              ≈ ${parsed1.toFixed(2)} USD
            </div>
          </div>

          {/* Deposit Simulation Breakdown */}
          <div className="rounded-lg border border-white/[0.06] bg-[#141518] p-3 space-y-2 text-xs">
            <div className="text-zinc-400 font-medium">Deposit Simulation</div>
            <div className="grid grid-cols-2 gap-1.5 pt-1 text-zinc-400 font-mono text-[11px]">
              <div>Total Inflow:</div>
              <div className="text-right text-zinc-200 tabular-nums">
                ${totalDepositValUsd.toFixed(2)} USD
              </div>

              <div>Estimated Shares:</div>
              <div className="text-right text-zinc-200 tabular-nums">
                {estSharesMinted.toFixed(2)} shares
              </div>

              <div>Pool Ownership:</div>
              <div className="text-right text-zinc-200 tabular-nums">
                {estPoolSharePct.toFixed(2)}%
              </div>

              <div>Swap Friction:</div>
              <div className="text-right text-emerald-400 tabular-nums">
                $0.00 (Zero Swap Drag)
              </div>
            </div>
          </div>

          {/* Error Message */}
          {depositError && (
            <div className="p-2.5 rounded-lg bg-red-500/10 border border-red-500/20 text-red-400 text-xs flex items-center gap-2">
              <AlertCircle className="h-4 w-4 shrink-0" />
              <span>{depositError}</span>
            </div>
          )}

          {/* Success Message */}
          {depositStatus === "success" && (
            <div className="p-2.5 rounded-lg bg-emerald-500/10 border border-emerald-500/20 text-emerald-400 text-xs flex items-center justify-between">
              <div className="flex items-center gap-2">
                <CheckCircle2 className="h-4 w-4 shrink-0" />
                <span>Deposit confirmed. Held in idle reserves for next rebalance.</span>
              </div>
              <button
                type="button"
                onClick={resetDeposit}
                className="text-[11px] font-mono text-emerald-400 hover:underline"
              >
                Dismiss
              </button>
            </div>
          )}

          {/* Submit Action */}
          <button
            type="button"
            disabled={depositStatus === "depositing" || totalDepositValUsd <= 0}
            onClick={() => handleDeposit(amount0, amount1)}
            className="w-full h-10 rounded-lg bg-zinc-100 hover:bg-white text-zinc-950 font-medium text-xs tracking-wide transition-colors disabled:opacity-40 disabled:cursor-not-allowed shadow-[inset_0_1px_0_rgba(255,255,255,0.25)]"
          >
            {depositStatus === "depositing"
              ? "Confirming Deposit..."
              : `Deposit $${totalDepositValUsd.toFixed(2)} Liquidity`}
          </button>
        </TabsContent>

        {/* ================= WITHDRAW TAB ================= */}
        <TabsContent value="withdraw" className="space-y-4 pt-1">
          {/* User Holdings */}
          <div className="rounded-lg border border-white/[0.08] bg-[#16171a] p-3 space-y-1">
            <div className="flex justify-between text-xs text-zinc-400">
              <span>Your Vault Shares</span>
              <span className="font-mono text-zinc-300">
                {(Number(vault.userShares) / 1e6).toFixed(2)} Shares
              </span>
            </div>
            <div className="text-xl font-mono tabular-nums font-semibold text-zinc-100">
              ${vault.userValueUsd.toFixed(2)} <span className="text-xs text-zinc-500 font-normal">USD</span>
            </div>
          </div>

          {/* Percentage Slider */}
          <div className="space-y-2.5 pt-1">
            <div className="flex justify-between items-center text-xs">
              <span className="text-zinc-400">Withdraw Percentage</span>
              <span className="font-mono text-sm font-semibold text-zinc-200">{withdrawPercent}%</span>
            </div>

            <Slider
              value={[withdrawPercent]}
              min={1}
              max={100}
              step={1}
              onValueChange={(vals) => setWithdrawPercent(vals[0])}
              className="w-full"
            />

            <div className="grid grid-cols-4 gap-1.5 pt-1">
              {[25, 50, 75, 100].map((pct) => (
                <button
                  key={pct}
                  type="button"
                  onClick={() => setWithdrawPercent(pct)}
                  className={`h-7 text-xs font-mono rounded border transition-colors ${
                    withdrawPercent === pct
                      ? "bg-zinc-800 border-white/[0.2] text-zinc-100"
                      : "bg-zinc-900 border-white/[0.08] text-zinc-400 hover:text-zinc-200"
                  }`}
                >
                  {pct === 100 ? "Max" : `${pct}%`}
                </button>
              ))}
            </div>
          </div>

          {/* Pro-Rata Assets Return Preview */}
          <div className="rounded-lg border border-white/[0.06] bg-[#141518] p-3 space-y-2 text-xs">
            <div className="text-zinc-400 font-medium">Pro-Rata Settlement</div>
            <div className="grid grid-cols-2 gap-1.5 pt-1 text-zinc-400 font-mono text-[11px]">
              <div>WETH Returned:</div>
              <div className="text-right text-zinc-200 tabular-nums">
                {estToken0.toFixed(4)} WETH
              </div>

              <div>USDC Returned:</div>
              <div className="text-right text-zinc-200 tabular-nums">
                {estToken1.toFixed(2)} USDC
              </div>

              <div>Total Estimated Value:</div>
              <div className="text-right text-zinc-100 font-medium tabular-nums">
                ${estWithdrawValUsd.toFixed(2)} USD
              </div>
            </div>
          </div>

          {/* Error Message */}
          {withdrawError && (
            <div className="p-2.5 rounded-lg bg-red-500/10 border border-red-500/20 text-red-400 text-xs flex items-center gap-2">
              <AlertCircle className="h-4 w-4 shrink-0" />
              <span>{withdrawError}</span>
            </div>
          )}

          {/* Success Message */}
          {withdrawStatus === "success" && (
            <div className="p-2.5 rounded-lg bg-emerald-500/10 border border-emerald-500/20 text-emerald-400 text-xs flex items-center justify-between">
              <div className="flex items-center gap-2">
                <CheckCircle2 className="h-4 w-4 shrink-0" />
                <span>Withdrawal confirmed. Tokens returned to wallet.</span>
              </div>
              <button
                type="button"
                onClick={resetWithdraw}
                className="text-[11px] font-mono text-emerald-400 hover:underline"
              >
                Dismiss
              </button>
            </div>
          )}

          {/* Submit Action */}
          <button
            type="button"
            disabled={withdrawStatus === "withdrawing" || sharesToBurn <= 0n}
            onClick={() => handleWithdraw(sharesToBurn)}
            className="w-full h-10 rounded-lg bg-zinc-100 hover:bg-white text-zinc-950 font-medium text-xs tracking-wide transition-colors disabled:opacity-40 disabled:cursor-not-allowed shadow-[inset_0_1px_0_rgba(255,255,255,0.25)]"
          >
            {withdrawStatus === "withdrawing"
              ? "Burning Shares..."
              : `Withdraw ${withdrawPercent}% ($${estWithdrawValUsd.toFixed(2)})`}
          </button>
        </TabsContent>
      </Tabs>
    </div>
  );
};
