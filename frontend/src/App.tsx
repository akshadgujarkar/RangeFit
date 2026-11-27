import React from "react";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { wagmiConfig } from "./config/wagmi";
import { Navbar } from "./components/dashboard/Navbar";
import { ProtocolStats } from "./components/dashboard/ProtocolStats";
import { RangeVisualizer } from "./components/dashboard/RangeVisualizer";
import { FeeSkewGauge } from "./components/dashboard/FeeSkewGauge";
import { DepositWithdraw } from "./components/dashboard/DepositWithdraw";
import { ActivityFeed } from "./components/dashboard/ActivityFeed";
import { useRangeFitVault } from "./hooks/useRangeFitVault";
import { useRebalanceHistory } from "./hooks/useRebalanceHistory";
import { Layers } from "lucide-react";

const queryClient = new QueryClient();

const DashboardContent: React.FC = () => {
  const vault = useRangeFitVault();
  const { totalSwapsAvoided, totalFeesSavedUsd } = useRebalanceHistory();

  return (
    <div className="min-h-screen w-full bg-[#09090b] text-zinc-100 flex flex-col justify-start relative">
      {/* Subtle top ambient radial lighting */}
      <div className="pointer-events-none absolute top-0 left-1/2 -translate-x-1/2 w-full max-w-7xl h-96 bg-[radial-gradient(ellipse_60%_50%_at_50%_0%,rgba(6,182,212,0.06),transparent_80%)]"></div>

      <Navbar isConfigured={vault.isConfigured} />

      <main className="container mx-auto px-4 sm:px-6 lg:px-8 py-8 space-y-6 max-w-7xl relative z-10 flex-1">
        {/* Hero Section */}
        <section className="space-y-2 pt-1 max-w-3xl">
          <div className="flex items-center gap-2">
            <span className="text-[11px] font-mono text-zinc-400 border border-white/[0.08] bg-zinc-900 px-2 py-0.5 rounded">
              Uniswap v4 Hook-as-LP Architecture
            </span>
            <span className="text-[11px] font-mono text-emerald-400 bg-emerald-500/10 border border-emerald-500/20 px-2 py-0.5 rounded">
              Zero Swap Friction
            </span>
          </div>

          <h1 className="text-2xl sm:text-3xl lg:text-4xl font-semibold tracking-tight text-zinc-100">
            Swapless Concentrated Liquidity Re-ranging
          </h1>
          <p className="text-sm text-zinc-400 leading-relaxed">
            RangeFit analytically solves for asymmetric price bounds that fit current inventory at spot price without executing swaps. Depositors face zero swap slippage, and dynamic hook fees turn rebalancing into yield.
          </p>
        </section>

        {/* 1. Protocol High-Level KPIs */}
        <ProtocolStats
          vault={vault}
          swapsAvoidedCount={totalSwapsAvoided}
          feesSavedUsd={totalFeesSavedUsd}
        />

        {/* 2. Workstation Grid */}
        <div className="grid grid-cols-1 lg:grid-cols-12 gap-5 items-start">
          {/* Left Column: Range Visualizer + Fee Skew */}
          <div className="lg:col-span-7 space-y-5">
            <RangeVisualizer vault={vault} />
            <FeeSkewGauge vault={vault} />
          </div>

          {/* Right Column: Liquidity Portal */}
          <div className="lg:col-span-5 space-y-5 sticky top-20">
            <DepositWithdraw vault={vault} />
          </div>
        </div>

        {/* 3. Rebalance Activity Feed */}
        <section className="pt-1">
          <ActivityFeed />
        </section>

        {/* Footer */}
        <footer className="pt-10 pb-6 border-t border-white/[0.08] text-xs text-zinc-500 flex flex-col sm:flex-row items-center justify-between gap-4">
          <div className="flex items-center gap-2">
            <div className="h-5 w-5 rounded bg-zinc-800 border border-white/[0.08] flex items-center justify-center text-zinc-300">
              <Layers className="h-3 w-3" />
            </div>
            <span className="font-medium text-zinc-300">RangeFit Protocol</span>
            <span>—</span>
            <span>Uniswap v4 Concentrated Liquidity Vault</span>
          </div>

          <div className="flex items-center gap-4 font-mono text-[11px] text-zinc-400">
            <span className="text-emerald-400/90">68 Foundry Tests Passing</span>
            <span>•</span>
            <span className="text-zinc-400">17 Keeper Tests Passing</span>
            <span>•</span>
            <span className="text-zinc-400">2,000 MC Paths Verified</span>
          </div>
        </footer>
      </main>
    </div>
  );
};

export default function App() {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <DashboardContent />
      </QueryClientProvider>
    </WagmiProvider>
  );
}
