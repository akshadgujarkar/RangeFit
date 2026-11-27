import React from "react";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import { Badge } from "@/components/lightswind/badge";
import { Button } from "@/components/lightswind/button";
import { Layers, Wallet, LogOut, CheckCircle2 } from "lucide-react";
import { shortenAddress } from "@/lib/utils";

interface NavbarProps {
  isConfigured: boolean;
}

export const Navbar: React.FC<NavbarProps> = ({ isConfigured }) => {
  const { address, isConnected, chain } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();

  const handleConnect = () => {
    const connector = connectors[0];
    if (connector) {
      connect({ connector });
    }
  };

  return (
    <header className="sticky top-0 z-50 w-full border-b border-white/[0.08] bg-[#09090b]/90 backdrop-blur-md">
      <div className="container mx-auto flex h-14 items-center justify-between px-4 sm:px-6 lg:px-8 max-w-7xl">
        {/* Brand */}
        <div className="flex items-center gap-3">
          <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-zinc-800 border border-white/[0.1] text-zinc-100">
            <Layers className="h-4 w-4" />
          </div>
          <div className="flex items-center gap-2">
            <span className="font-semibold text-sm tracking-tight text-zinc-100">
              RangeFit
            </span>
            <span className="text-[11px] font-mono text-zinc-500 border border-white/[0.08] px-1.5 py-0.5 rounded">
              v4 Hook
            </span>
          </div>
        </div>

        {/* Network & Engine Status */}
        <div className="flex items-center gap-3">
          <div className="hidden sm:flex items-center gap-2 text-xs">
            <div className="flex items-center gap-1.5 text-zinc-400 bg-zinc-900 border border-white/[0.08] px-2.5 py-1 rounded-md font-mono text-[11px]">
              <span className="h-1.5 w-1.5 rounded-full bg-emerald-500"></span>
              <span>Swapless Engine</span>
            </div>

            <div className="text-zinc-500 font-mono text-[11px] px-2 py-1">
              {chain?.name || (isConfigured ? "Anvil Localnet" : "Verified Simulation")}
            </div>
          </div>

          {/* Wallet Actions */}
          {isConnected && address ? (
            <div className="flex items-center gap-2">
              <div className="flex items-center gap-2 rounded-md border border-white/[0.08] bg-zinc-900 px-2.5 py-1 text-xs">
                <span className="h-1.5 w-1.5 rounded-full bg-emerald-500"></span>
                <span className="font-mono text-[12px] font-medium text-zinc-200">
                  {shortenAddress(address)}
                </span>
              </div>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => disconnect()}
                className="text-zinc-400 hover:text-zinc-200 h-8 w-8 p-0 hover:bg-zinc-800"
                title="Disconnect"
              >
                <LogOut className="h-3.5 w-3.5" />
              </Button>
            </div>
          ) : (
            <button
              onClick={handleConnect}
              className="inline-flex items-center gap-1.5 h-8 px-3 rounded-md bg-zinc-100 hover:bg-white text-zinc-950 font-medium text-xs shadow-[inset_0_1px_0_rgba(255,255,255,0.25)] transition-colors"
            >
              <Wallet className="h-3.5 w-3.5" />
              <span>Connect Wallet</span>
            </button>
          )}
        </div>
      </div>
    </header>
  );
};
