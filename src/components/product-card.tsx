"use client";

import { useState } from "react";
import type { ActiveCycle, TierState } from "@/lib/types";
import { useCountdown, useElapsedPercent, formatDuration } from "@/hooks/use-countdown";
import { useLanguage } from "@/lib/i18n/context";
import { TIER_ACCENT } from "@/lib/tier-art";
import { TierImage } from "./tier-image";

// Stable placeholder for useElapsedPercent's start param when there's no
// real previousTier.unlocked_at yet — avoids computing `new Date()` (impure)
// during render just to produce an unused fallback.
const EPOCH = "1970-01-01T00:00:00.000Z";

function nextEndsAt(activeCycles: ActiveCycle[]): string | null {
  if (activeCycles.length === 0) return null;
  return activeCycles.reduce((soonest, c) => (c.ends_at < soonest ? c.ends_at : soonest), activeCycles[0].ends_at);
}

export function ProductCard({
  tier,
  previousTier,
  activeCycles,
  balance,
  freeSlots,
  onStart,
  onOpenDetail,
}: {
  tier: TierState;
  previousTier: TierState | null;
  activeCycles: ActiveCycle[];
  balance: number;
  freeSlots: number;
  onStart: (tier: number) => Promise<void>;
  onOpenDetail: () => void;
}) {
  const { t, pick } = useLanguage();
  const [starting, setStarting] = useState(false);
  const accent = TIER_ACCENT[tier.tier] ?? "#8b7765";

  const requiredCycles = previousTier?.unlock_required_cycles ?? 0;
  const doneCycles = Math.min(previousTier?.completed_cycles ?? 0, requiredCycles);
  const cyclesPercent = requiredCycles > 0 ? (doneCycles / requiredCycles) * 100 : 100;
  const timePercent = useElapsedPercent(
    previousTier?.unlocked_at ?? EPOCH,
    previousTier?.unlocked_at ? (previousTier?.unlock_min_hours ?? 0) : 0,
  );
  const unlockPercent = Math.floor(Math.min(cyclesPercent, timePercent));

  const usedSlots = activeCycles.reduce((sum, c) => sum + c.slot_quantity, 0);
  const soonestEndsAt = nextEndsAt(activeCycles);
  const remaining = useCountdown(soonestEndsAt ?? EPOCH);

  async function handleStart(e: React.MouseEvent) {
    e.stopPropagation();
    setStarting(true);
    try {
      await onStart(tier.tier);
    } finally {
      setStarting(false);
    }
  }

  if (!tier.unlocked) {
    return (
      <div className="gradient-surface flex gap-3 rounded-2xl p-3 opacity-60">
        <TierImage tier={tier.tier} className="h-16 w-16 shrink-0 rounded-xl" />
        <div className="flex flex-1 flex-col justify-center gap-1.5">
          <div className="flex items-center justify-between">
            <span className="font-semibold">🔒 {pick(tier.name_i18n)}</span>
            <span className="text-sm text-nav-inactive">
              {tier.price} {t("common.gram")}
            </span>
          </div>
          <div className="h-1.5 rounded-full bg-progress-bg">
            <div
              className="h-1.5 rounded-full bg-progress-fill"
              style={{ width: `${unlockPercent}%` }}
            />
          </div>
          <p className="text-xs text-nav-inactive">
            {t("productCard.unlocksAfter")} {requiredCycles} {t("productCard.cycles")} ·{" "}
            {doneCycles}/{requiredCycles} · {unlockPercent}%
          </p>
        </div>
      </div>
    );
  }

  const canAfford = balance >= tier.price;
  const canStart = canAfford && freeSlots > 0 && !starting;
  // Mirrors the server's start_cycle: one launch fills as many idle slots as
  // affordable, capped at all of them — shown so the button's ×N is accurate
  // before the click, not just a guess.
  const launchQuantity = Math.max(1, Math.min(freeSlots, Math.floor(balance / tier.price)));
  const description = pick(tier.description_i18n);

  return (
    <div
      className="gradient-surface flex cursor-pointer gap-3 rounded-2xl p-3"
      style={{ borderLeft: `3px solid ${accent}` }}
      onClick={onOpenDetail}
    >
      <TierImage tier={tier.tier} className="h-16 w-16 shrink-0 rounded-xl" />
      <div className="flex flex-1 flex-col gap-1">
        <div className="flex items-start justify-between gap-2">
          <div>
            <p className="font-semibold">
              {tier.tier}. {pick(tier.name_i18n)}
            </p>
            {description && <p className="text-xs text-nav-inactive">{description}</p>}
          </div>
          <span className="shrink-0 text-sm text-gram">
            {tier.price} {t("common.gram")}
          </span>
        </div>

        <div className="flex items-center justify-between text-xs">
          <span className="text-profit">
            +{(tier.price * (1 + tier.payout_percent / 100)).toFixed(2)} {t("common.gram")}
          </span>
          {usedSlots > 0 && soonestEndsAt ? (
            <span className="font-mono text-nav-inactive">
              ⏱ {remaining > 0 ? formatDuration(remaining) : t("productCard.ready")}
              {usedSlots > 1 ? ` ×${usedSlots}` : ""}
            </span>
          ) : (
            <span className="text-nav-inactive">
              🕐 {tier.cycle_hours} {t("productCard.hours")}
            </span>
          )}
        </div>

        <button
          type="button"
          onClick={handleStart}
          disabled={!canStart}
          className="gradient-action mt-1 rounded-full py-2 text-sm font-semibold disabled:opacity-40"
        >
          {!canAfford
            ? t("productCard.insufficientBalance")
            : freeSlots <= 0
              ? t("productCard.noFreeSlots")
              : launchQuantity > 1
                ? `${t("productCard.launchCycle")} ×${launchQuantity}`
                : t("productCard.launchCycle")}
        </button>
      </div>
    </div>
  );
}
