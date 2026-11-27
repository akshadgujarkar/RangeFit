import React from "react";
import { Table, TableHeader, TableBody, TableHead, TableRow, TableCell } from "@/components/lightswind/table";
import { useRebalanceHistory } from "@/hooks/useRebalanceHistory";
import { ArrowRight, CheckCircle2 } from "lucide-react";

export const ActivityFeed: React.FC = () => {
  const { events, totalSwapsAvoided, totalFeesSavedUsd } = useRebalanceHistory();

  return (
    <div className="rounded-xl border border-white/[0.08] bg-[#111214] p-5 space-y-4">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 pb-1">
        <div>
          <div className="flex items-center gap-2">
            <h2 className="text-sm font-medium text-zinc-100">
              Rebalance Activity Ledger
            </h2>
            <span className="text-[11px] font-mono text-zinc-500 border border-white/[0.08] px-1.5 py-0.5 rounded">
              On-Chain Events
            </span>
          </div>
          <p className="text-xs text-zinc-400 mt-0.5">
            Every rebalance mathematically solves for new bounds without selling inventory into the pool
          </p>
        </div>

        <div className="text-xs font-mono text-zinc-400">
          <span className="text-zinc-200 font-medium">{totalSwapsAvoided}</span> rebalances executed •{" "}
          <span className="text-emerald-400 font-medium">+${totalFeesSavedUsd.toFixed(0)}</span> saved
        </div>
      </div>

      {/* Table */}
      <div className="rounded-lg border border-white/[0.08] overflow-hidden">
        <Table noScroll className="w-full">
          <TableHeader>
            <TableRow className="border-b border-white/[0.08] bg-[#16171a] text-[11px] font-mono text-zinc-400">
              <TableHead className="py-2.5 px-3">BLOCK / TIME</TableHead>
              <TableHead className="py-2.5 px-3">OLD RANGE</TableHead>
              <TableHead className="py-2.5 px-3 text-center"></TableHead>
              <TableHead className="py-2.5 px-3">NEW RANGE</TableHead>
              <TableHead className="py-2.5 px-3">SPOT PRICE</TableHead>
              <TableHead className="py-2.5 px-3">RESIDUAL DUST</TableHead>
              <TableHead className="py-2.5 px-3 text-right">STATUS</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {events.map((ev) => (
              <TableRow
                key={ev.id}
                className="border-b border-white/[0.06] last:border-b-0 hover:bg-[#16171a]/60 transition-colors text-xs font-mono tabular-nums"
              >
                {/* Block & Time */}
                <TableCell className="py-3 px-3">
                  <div className="font-medium text-zinc-200">#{ev.blockNumber}</div>
                  <div className="text-[11px] text-zinc-500 mt-0.5">{ev.timeAgo}</div>
                </TableCell>

                {/* Old Range */}
                <TableCell className="py-3 px-3 text-zinc-400">
                  ${ev.oldRange[0].toFixed(0)} - ${ev.oldRange[1].toFixed(0)}
                </TableCell>

                {/* Arrow */}
                <TableCell className="py-3 px-3 text-center text-zinc-600">
                  <ArrowRight className="h-3 w-3 inline" />
                </TableCell>

                {/* New Range */}
                <TableCell className="py-3 px-3 font-medium text-zinc-200">
                  ${ev.newRange[0].toFixed(0)} - ${ev.newRange[1].toFixed(0)}
                </TableCell>

                {/* Spot Price */}
                <TableCell className="py-3 px-3 text-zinc-300">
                  ${ev.spotPrice.toFixed(2)}
                </TableCell>

                {/* Residual Dust */}
                <TableCell className="py-3 px-3 text-zinc-400">
                  <span className="text-zinc-200 font-medium">{(ev.dustBps / 100).toFixed(2)}%</span>
                  <span className="text-[10px] text-zinc-500 ml-1">dust</span>
                </TableCell>

                {/* Status Badge */}
                <TableCell className="py-3 px-3 text-right">
                  <span className="inline-flex items-center gap-1 text-[11px] font-mono text-emerald-400 bg-emerald-500/10 border border-emerald-500/20 px-2 py-0.5 rounded">
                    <CheckCircle2 className="h-3 w-3" />
                    <span>0 Swaps ($0 Fee)</span>
                  </span>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </div>
  );
};
