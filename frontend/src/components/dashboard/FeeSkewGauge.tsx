import React from "react";
import { VaultData } from "@/hooks/useRangeFitVault";

interface FeeSkewGaugeProps {
  vault: VaultData;
}

export const FeeSkewGauge: React.FC<FeeSkewGaugeProps> = ({ vault }) => {
  const {
    inventoryRatioToken0,
    targetRatioPercent,
    baseFeePercent,
    token0FeePercent,
    token1FeePercent,
    feeSkewEnabled,
  } = vault;

  const ratio1 = 100 - inventoryRatioToken0;
  const skew = inventoryRatioToken0 - targetRatioPercent;

  return (
    <div className="rounded-xl border border-white/[0.08] bg-[#111214] p-5 space-y-5">
      {/* Header */}
      <div className="flex items-center justify-between pb-1">
        <div>
          <div className="flex items-center gap-2">
            <h2 className="text-sm font-medium text-zinc-100">
              Directional Fee Skew
            </h2>
            <span className="text-[11px] font-mono text-zinc-500 border border-white/[0.08] px-1.5 py-0.5 rounded">
              Uniswap v4 beforeSwap
            </span>
          </div>
          <p className="text-xs text-zinc-400 mt-0.5">
            Dynamic swap fee incentivizes organic flow to balance inventory
          </p>
        </div>

        <div className="flex items-center gap-1.5 text-xs font-mono">
          <span
            className={`h-2 w-2 rounded-full ${
              feeSkewEnabled ? "bg-emerald-500" : "bg-zinc-600"
            }`}
          ></span>
          <span className="text-zinc-400">
            {feeSkewEnabled ? "Dynamic Active" : "Static 0.30%"}
          </span>
        </div>
      </div>

      {/* Inventory Ratio Split Bar */}
      <div className="space-y-2">
        <div className="flex justify-between text-xs font-mono">
          <span className="text-zinc-300">
            WETH: {inventoryRatioToken0.toFixed(1)}%
          </span>
          <span className="text-zinc-500">
            Target: {targetRatioPercent.toFixed(0)}% / {targetRatioPercent.toFixed(0)}%
          </span>
          <span className="text-zinc-300">
            USDC: {ratio1.toFixed(1)}%
          </span>
        </div>

        <div className="h-2.5 w-full rounded-full bg-zinc-900 border border-white/[0.06] flex overflow-hidden">
          <div
            className="h-full bg-zinc-400 transition-all duration-300"
            style={{ width: `${inventoryRatioToken0}%` }}
          ></div>
          <div
            className="h-full bg-zinc-600 transition-all duration-300"
            style={{ width: `${ratio1}%` }}
          ></div>
        </div>

        <div className="flex justify-between items-center text-[11px] font-mono text-zinc-500">
          <span>
            {skew > 0 ? `+${skew.toFixed(1)}% excess WETH` : `${skew.toFixed(1)}% WETH`}
          </span>
          <span>Inventory offset: {Math.abs(skew).toFixed(1)}%</span>
          <span>
            {skew > 0 ? `-${skew.toFixed(1)}% deficit USDC` : `+${Math.abs(skew).toFixed(1)}% USDC`}
          </span>
        </div>
      </div>

      {/* Directional Fee Table */}
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 pt-1">
        {/* Sell Token0 */}
        <div className="rounded-lg border border-white/[0.06] bg-[#16171a] p-3.5 space-y-1">
          <div className="flex items-center justify-between text-xs text-zinc-400">
            <span>Sell WETH (Worsens Skew)</span>
            <span className="text-[10px] font-mono text-red-400 bg-red-500/10 border border-red-500/20 px-1.5 py-0.5 rounded">
              +{((token0FeePercent - baseFeePercent) * 100).toFixed(0)} bps
            </span>
          </div>
          <div className="text-xl font-mono tabular-nums font-semibold text-zinc-200">
            {token0FeePercent.toFixed(2)}%
          </div>
          <p className="text-[11px] text-zinc-500">
            Higher fee charged to traders selling into vault oversupply
          </p>
        </div>

        {/* Buy Token0 */}
        <div className="rounded-lg border border-white/[0.06] bg-[#16171a] p-3.5 space-y-1">
          <div className="flex items-center justify-between text-xs text-zinc-400">
            <span>Buy WETH (Restores Skew)</span>
            <span className="text-[10px] font-mono text-emerald-400 bg-emerald-500/10 border border-emerald-500/20 px-1.5 py-0.5 rounded">
              -{((baseFeePercent - token1FeePercent) * 100).toFixed(0)} bps
            </span>
          </div>
          <div className="text-xl font-mono tabular-nums font-semibold text-emerald-400">
            {token1FeePercent.toFixed(2)}%
          </div>
          <p className="text-[11px] text-zinc-500">
            Fee discount offered to traders absorbing vault excess inventory
          </p>
        </div>
      </div>

      <div className="text-xs text-zinc-400 leading-relaxed pt-1 border-t border-white/[0.06]">
        <span className="text-zinc-200 font-medium">Zero cost rebalancing:</span> Instead of paying swap fees to rebalance inventory, the hook charges external traders higher fees, turning rebalancing into fee revenue for depositors.
      </div>
    </div>
  );
};
