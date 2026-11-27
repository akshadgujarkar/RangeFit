import React from "react";
import { CountUp } from "@/components/lightswind/count-up";
import { VaultData } from "@/hooks/useRangeFitVault";

interface ProtocolStatsProps {
  vault: VaultData;
  swapsAvoidedCount: number;
  feesSavedUsd: number;
}

export const ProtocolStats: React.FC<ProtocolStatsProps> = ({
  vault,
  swapsAvoidedCount,
  feesSavedUsd,
}) => {
  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4">
      {/* 1. TVL */}
      <div className="rounded-xl border border-white/[0.08] bg-[#111214] p-4 flex flex-col justify-between">
        <div className="text-xs text-zinc-400">Total Value Locked</div>
        <div className="mt-2 text-2xl font-medium font-mono tabular-nums text-zinc-100">
          <CountUp
            value={vault.totalVaultValueUsd}
            prefix="$"
            decimals={2}
            duration={1.0}
            className="text-zinc-100"
          />
        </div>
        <div className="mt-2 text-[11px] font-mono text-zinc-500">
          {vault.inv0.toFixed(2)} WETH + {vault.inv1.toLocaleString(undefined, { maximumFractionDigits: 0 })} USDC
        </div>
      </div>

      {/* 2. Rebalances Executed */}
      <div className="rounded-xl border border-white/[0.08] bg-[#111214] p-4 flex flex-col justify-between">
        <div className="text-xs text-zinc-400">Rebalances Executed</div>
        <div className="mt-2 text-2xl font-medium font-mono tabular-nums text-zinc-100 flex items-baseline gap-1.5">
          <CountUp
            value={swapsAvoidedCount}
            duration={1.0}
            className="text-zinc-100"
          />
          <span className="text-xs font-sans text-zinc-500 font-normal">
            swapless
          </span>
        </div>
        <div className="mt-2 text-[11px] text-emerald-400/90 font-mono">
          0% swap drag vs traditional ALM
        </div>
      </div>

      {/* 3. Slippage & Fees Preserved */}
      <div className="rounded-xl border border-white/[0.08] bg-[#111214] p-4 flex flex-col justify-between">
        <div className="text-xs text-zinc-400">Capital Preserved</div>
        <div className="mt-2 text-2xl font-medium font-mono tabular-nums text-emerald-400">
          <CountUp
            value={feesSavedUsd}
            prefix="+$"
            decimals={2}
            duration={1.0}
            className="text-emerald-400"
          />
        </div>
        <div className="mt-2 text-[11px] text-zinc-500 font-mono">
          Zero swap fees & zero price impact
        </div>
      </div>

      {/* 4. Vault Status */}
      <div className="rounded-xl border border-white/[0.08] bg-[#111214] p-4 flex flex-col justify-between">
        <div className="text-xs text-zinc-400">Vault Position State</div>
        <div className="mt-2 text-xl font-medium text-zinc-100 flex items-center gap-2">
          <span className={`h-2 w-2 rounded-full ${vault.rebalanceDue ? "bg-amber-400" : "bg-emerald-500"}`}></span>
          <span>{vault.rebalanceDue ? "Rebalance Standby" : "Active In-Range"}</span>
        </div>
        <div className="mt-2 text-[11px] text-zinc-500 font-mono">
          {vault.rebalanceDue ? "20% boundary threshold reached" : "Position centered within bounds"}
        </div>
      </div>
    </div>
  );
};
