"use client";

import { useState } from "react";
import type { ActiveCycle, TierState } from "@/lib/types";
import { useCountdown, useElapsedPercent, formatDuration } from "@/hooks/use-countdown";

// Stable placeholder for useElapsedPercent's start param when there's no
// real previousTier.unlocked_at yet — avoids computing `new Date()` (impure)
// during render just to produce an unused fallback.
const EPOCH = "1970-01-01T00:00:00.000Z";

const TIER_ACCENT: Record<number, string> = {
  1: "#8b7765",
  2: "#c47a4a",
  3: "#bfc7d5",
  4: "#ffd166",
  5: "#ff9f43",
  6: "#4da3ff",
  7: "#b05cff",
  8: "#ffd700",
};

function CycleTimer({ cycle }: { cycle: ActiveCycle }) {
  const remaining = useCountdown(cycle.ends_at);
  return (
    <div className="flex items-center justify-between rounded-lg bg-progress-bg px-3 py-1.5 text-xs">
      <span className="text-nav-inactive">
        В процессе{cycle.slot_quantity > 1 ? ` ×${cycle.slot_quantity}` : ""}
      </span>
      <span className="font-mono font-semibold">
        {remaining > 0 ? formatDuration(remaining) : "Готово"}
      </span>
    </div>
  );
}

export function ProductCard({
  tier,
  previousTier,
  activeCycles,
  balance,
  freeSlots,
  onStart,
}: {
  tier: TierState;
  previousTier: TierState | null;
  activeCycles: ActiveCycle[];
  balance: number;
  freeSlots: number;
  onStart: (tier: number) => Promise<void>;
}) {
  const [starting, setStarting] = useState(false);
  const accent = TIER_ACCENT[tier.tier] ?? "#8b7765";

  // Unlock requires BOTH enough completed cycles AND enough elapsed time
  // (see supabase/migrations/0002_functions.sql) — the real progress is
  // whichever of the two is further behind, not the cycle count alone.
  const requiredCycles = previousTier?.unlock_required_cycles ?? 0;
  const doneCycles = Math.min(previousTier?.completed_cycles ?? 0, requiredCycles);
  const cyclesPercent = requiredCycles > 0 ? (doneCycles / requiredCycles) * 100 : 100;
  const timePercent = useElapsedPercent(
    previousTier?.unlocked_at ?? EPOCH,
    previousTier?.unlocked_at ? (previousTier?.unlock_min_hours ?? 0) : 0,
  );
  const unlockPercent = Math.floor(Math.min(cyclesPercent, timePercent));

  async function handleStart() {
    setStarting(true);
    try {
      await onStart(tier.tier);
    } finally {
      setStarting(false);
    }
  }

  if (!tier.unlocked) {
    return (
      <div className="gradient-surface flex flex-col gap-2 rounded-2xl p-4 opacity-60">
        <div className="flex items-center justify-between">
          <span className="font-semibold">🔒 {tier.name}</span>
          <span className="text-sm text-nav-inactive">{tier.price} GRAM</span>
        </div>
        <div className="h-1.5 rounded-full bg-progress-bg">
          <div
            className="h-1.5 rounded-full bg-progress-fill"
            style={{ width: `${unlockPercent}%` }}
          />
        </div>
        <p className="text-xs text-nav-inactive">
          Открывается после: {doneCycles}/{requiredCycles} циклов · {unlockPercent}%
        </p>
      </div>
    );
  }

  const canAfford = balance >= tier.price;
  const canStart = canAfford && freeSlots > 0 && !starting;
  // Mirrors the server's start_cycle: one launch fills as many idle slots as
  // affordable, capped at all of them — shown so the button's ×N is accurate
  // before the click, not just a guess.
  const launchQuantity = Math.max(1, Math.min(freeSlots, Math.floor(balance / tier.price)));

  return (
    <div
      className="gradient-surface flex flex-col gap-2 rounded-2xl p-4"
      style={{ borderLeft: `3px solid ${accent}` }}
    >
      <div className="flex items-center justify-between">
        <span className="font-semibold">{tier.name}</span>
        <span className="text-sm text-gram">{tier.price} GRAM</span>
      </div>
      <p className="text-xs text-nav-inactive">
        +{tier.payout_percent}% за {tier.cycle_hours}ч · доход{" "}
        <span className="text-profit">
          {(tier.price * (1 + tier.payout_percent / 100)).toFixed(2)} GRAM
        </span>
      </p>

      {activeCycles.map((cycle) => (
        <CycleTimer key={cycle.id} cycle={cycle} />
      ))}

      <button
        type="button"
        onClick={handleStart}
        disabled={!canStart}
        className="gradient-action mt-1 rounded-full py-2 text-sm font-semibold disabled:opacity-40"
      >
        {!canAfford
          ? "Недостаточно GRAM"
          : freeSlots <= 0
            ? "Нет свободных слотов"
            : launchQuantity > 1
              ? `🍾 Запустить цикл ×${launchQuantity}`
              : "🍾 Запустить цикл"}
      </button>
    </div>
  );
}
