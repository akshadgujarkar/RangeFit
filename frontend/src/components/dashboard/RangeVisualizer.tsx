import React from "react";
import { VaultData } from "@/hooks/useRangeFitVault";

interface RangeVisualizerProps {
  vault: VaultData;
}

export const RangeVisualizer: React.FC<RangeVisualizerProps> = ({ vault }) => {
  const {
    spotPrice,
    priceLower,
    priceUpper,
    rangeProgressPercent,
    tickLower,
    tickUpper,
    rebalanceDue,
  } = vault;

  const distToLowerPct = ((spotPrice - priceLower) / spotPrice) * 100;
  const distToUpperPct = ((priceUpper - spotPrice) / spotPrice) * 100;
  const isNearEdge = rangeProgressPercent <= 20 || rangeProgressPercent >= 80;

  return (
    <div className="rounded-xl border border-white/[0.08] bg-[#111214] p-5 space-y-5">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 pb-1">
        <div>
          <div className="flex items-center gap-2">
            <h2 className="text-sm font-medium text-zinc-100">
              Concentrated Liquidity Range
            </h2>
            <span className="text-[11px] font-mono text-zinc-500 border border-white/[0.08] px-1.5 py-0.5 rounded">
              Tick Spacing 60
            </span>
          </div>
          <p className="text-xs text-zinc-400 mt-0.5">
            Analytical solution absorbs inventory without swapping tokens
          </p>
        </div>

        <div className="flex items-center gap-1.5 text-xs font-mono">
          <span
            className={`h-2 w-2 rounded-full ${
              isNearEdge ? "bg-amber-400" : "bg-emerald-500"
            }`}
          ></span>
          <span className="text-zinc-400">
            {isNearEdge ? "Near 20% Boundary" : "Position Centered"}
          </span>
        </div>
      </div>

      {/* Metric Triplet */}
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
        {/* Lower Bound */}
        <div className="rounded-lg border border-white/[0.06] bg-[#16171a] p-3.5">
          <div className="flex items-center justify-between text-xs text-zinc-400">
            <span>Lower Price (p_a)</span>
            <span className="font-mono text-[10px] text-zinc-500">Tick {tickLower}</span>
          </div>
          <div className="mt-1 text-lg font-mono tabular-nums font-medium text-zinc-200">
            ${priceLower.toFixed(2)}
          </div>
          <div className="text-[11px] text-zinc-500 font-mono mt-0.5">
            -{distToLowerPct.toFixed(2)}% from spot
          </div>
        </div>

        {/* Spot Price */}
        <div className="rounded-lg border border-cyan-500/30 bg-[#16171a] p-3.5">
          <div className="flex items-center justify-between text-xs text-cyan-400">
            <span>Current Spot (s)</span>
            <span className="h-1.5 w-1.5 rounded-full bg-cyan-400"></span>
          </div>
          <div className="mt-1 text-lg font-mono tabular-nums font-semibold text-zinc-100">
            ${spotPrice.toFixed(2)}
          </div>
          <div className="text-[11px] text-zinc-400 font-mono mt-0.5">
            {rangeProgressPercent.toFixed(1)}% through range
          </div>
        </div>

        {/* Upper Bound */}
        <div className="rounded-lg border border-white/[0.06] bg-[#16171a] p-3.5">
          <div className="flex items-center justify-between text-xs text-zinc-400">
            <span>Upper Price (p_b)</span>
            <span className="font-mono text-[10px] text-zinc-500">Tick {tickUpper}</span>
          </div>
          <div className="mt-1 text-lg font-mono tabular-nums font-medium text-zinc-200">
            ${priceUpper.toFixed(2)}
          </div>
          <div className="text-[11px] text-zinc-500 font-mono mt-0.5">
            +{distToUpperPct.toFixed(2)}% from spot
          </div>
        </div>
      </div>

      {/* Visual Liquidity Depth Span */}
      <div className="space-y-2 pt-1">
        <div className="flex justify-between text-[11px] text-zinc-500 font-mono">
          <span>${priceLower.toFixed(0)}</span>
          <span className="text-zinc-400 font-medium">Active Position Span</span>
          <span>${priceUpper.toFixed(0)}</span>
        </div>

        <div className="relative h-10 w-full rounded-lg bg-zinc-900 border border-white/[0.08] overflow-hidden">
          {/* 20% Left Edge Warning Zone */}
          <div className="absolute left-0 top-0 bottom-0 w-[20%] bg-amber-500/[0.07] border-r border-dashed border-amber-500/30 flex items-center pl-2">
            <span className="text-[10px] font-mono text-amber-400/80 hidden sm:inline">20% trigger</span>
          </div>

          {/* 20% Right Edge Warning Zone */}
          <div className="absolute right-0 top-0 bottom-0 w-[20%] bg-amber-500/[0.07] border-l border-dashed border-amber-500/30 flex items-center justify-end pr-2">
            <span className="text-[10px] font-mono text-amber-400/80 hidden sm:inline">20% trigger</span>
          </div>

          {/* Active Liquidity Region */}
          <div className="absolute left-[15%] right-[15%] top-1 bottom-1 rounded bg-zinc-800 border border-white/[0.1] flex items-center justify-center">
            <span className="text-[11px] font-mono text-zinc-300 tracking-wide">
              Active Concentrated Liquidity (100%)
            </span>
          </div>

          {/* Spot Price Needle Target */}
          <div
            className="absolute top-0 bottom-0 -ml-[1px] z-10 w-[2px] bg-cyan-400 shadow-[0_0_6px_rgba(6,182,212,0.6)]"
            style={{ left: `${Math.min(96, Math.max(4, rangeProgressPercent))}%` }}
          >
            <div className="absolute -top-1 -left-[3px] w-2 h-2 rounded-full bg-cyan-400"></div>
          </div>
        </div>

        <div className="flex items-center justify-between text-[11px] text-zinc-500 font-mono pt-0.5">
          <span>Keeper rebalances if spot crosses 20% boundary</span>
          <span>Width: {tickUpper - tickLower} ticks (${(priceUpper - priceLower).toFixed(0)})</span>
        </div>
      </div>
    </div>
  );
};
