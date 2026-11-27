import { useState } from "react";

export interface RebalanceEvent {
  id: string;
  blockNumber: number;
  timeAgo: string;
  oldRange: [number, number];
  newRange: [number, number];
  spotPrice: number;
  dustBps: number;
  swapAvoided: boolean;
  swapFeePaid: number;
  slippagePaid: number;
  reason: "Edge Threshold (20%)" | "Cooldown Expired" | "Manual Keeper" | "Idle Absorption";
}

const HISTORICAL_EVENTS: RebalanceEvent[] = [
  {
    id: "reb-006",
    blockNumber: 18452109,
    timeAgo: "14 mins ago",
    oldRange: [2440.0, 2560.0],
    newRange: [2480.0, 2600.0],
    spotPrice: 2540.25,
    dustBps: 18, // 0.18% dust
    swapAvoided: true,
    swapFeePaid: 0,
    slippagePaid: 0,
    reason: "Edge Threshold (20%)",
  },
  {
    id: "reb-005",
    blockNumber: 18449830,
    timeAgo: "2 hours ago",
    oldRange: [2400.0, 2520.0],
    newRange: [2440.0, 2560.0],
    spotPrice: 2502.8,
    dustBps: 24,
    swapAvoided: true,
    swapFeePaid: 0,
    slippagePaid: 0,
    reason: "Edge Threshold (20%)",
  },
  {
    id: "reb-004",
    blockNumber: 18445120,
    timeAgo: "8 hours ago",
    oldRange: [2360.0, 2480.0],
    newRange: [2400.0, 2520.0],
    spotPrice: 2465.1,
    dustBps: 12,
    swapAvoided: true,
    swapFeePaid: 0,
    slippagePaid: 0,
    reason: "Idle Absorption",
  },
  {
    id: "reb-003",
    blockNumber: 18438900,
    timeAgo: "1 day ago",
    oldRange: [2320.0, 2440.0],
    newRange: [2360.0, 2480.0],
    spotPrice: 2420.5,
    dustBps: 31,
    swapAvoided: true,
    swapFeePaid: 0,
    slippagePaid: 0,
    reason: "Edge Threshold (20%)",
  },
  {
    id: "reb-002",
    blockNumber: 18431050,
    timeAgo: "2 days ago",
    oldRange: [2280.0, 2400.0],
    newRange: [2320.0, 2440.0],
    spotPrice: 2382.4,
    dustBps: 15,
    swapAvoided: true,
    swapFeePaid: 0,
    slippagePaid: 0,
    reason: "Edge Threshold (20%)",
  },
  {
    id: "reb-001",
    blockNumber: 18420000,
    timeAgo: "4 days ago",
    oldRange: [2240.0, 2360.0],
    newRange: [2280.0, 2400.0],
    spotPrice: 2341.0,
    dustBps: 42,
    swapAvoided: true,
    swapFeePaid: 0,
    slippagePaid: 0,
    reason: "Idle Absorption",
  },
];

export function useRebalanceHistory() {
  const [events] = useState<RebalanceEvent[]>(HISTORICAL_EVENTS);

  const totalSwapsAvoided = events.length;
  // Baseline ALM comparison: avg $1,500 swap volume per rebalance * 0.3% fee + 0.1% slippage = $6.00 per rebalance
  // For $400k TVL, 10% inventory = $40,000 swap = $160 saved per rebalance!
  const totalFeesSavedUsd = events.length * 160.0;

  return {
    events,
    totalSwapsAvoided,
    totalFeesSavedUsd,
  };
}
