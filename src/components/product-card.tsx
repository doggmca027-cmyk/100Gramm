"use client";

import { useState } from "react";
import { Lock, Timer, Clock, Layers, Flame } from "lucide-react";
import type { ActiveCycle, TierState } from "@/lib/types";
import { useCountdown, useElapsedPercent, formatDuration, useDurationUnits } from "@/hooks/use-countdown";
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
  exchangeRate,
  onStart,
  onBuyMax,
  onOpenDetail,
}: {
  tier: TierState;
  previousTier: TierState | null;
  activeCycles: ActiveCycle[];
  balance: number;
  freeSlots: number;
  exchangeRate: number | null;
  onStart: (tier: number) => Promise<void>;
  onBuyMax: (tier: number) => Promise<void>;
  onOpenDetail: () => void;
}) {
  const { t, pick } = useLanguage();
  const units = useDurationUnits();
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
  // unlock_min_hours is a floor measured in real elapsed time since the
  // previous tier unlocked, deliberately *not* sped up by owning extra
  // slots — running several cycles in parallel can satisfy the cycle-count
  // requirement (doneCycles >= requiredCycles) well before this floor does.
  // When that happens, showing "10/10 циклов" reads as "requirement met"
  // even though the tier is still gated purely on time, so once cycles are
  // saturated we switch the label to a countdown against that real floor
  // instead of the now-meaningless cycle fraction.
  const cyclesMet = requiredCycles === 0 || doneCycles >= requiredCycles;
  const unlockAt =
    previousTier?.unlocked_at && previousTier?.unlock_min_hours
      ? new Date(
          new Date(previousTier.unlocked_at).getTime() + previousTier.unlock_min_hours * 3600_000,
        ).toISOString()
      : EPOCH;
  const timeUntilUnlock = useCountdown(unlockAt);

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

  async function handleBuyMax(e: React.MouseEvent) {
    e.stopPropagation();
    setStarting(true);
    try {
      await onBuyMax(tier.tier);
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
            <span className="flex items-center gap-1 font-semibold">
              <Lock className="h-4 w-4 shrink-0 text-neutral-400" />
              {pick(tier.name_i18n)}
            </span>
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
            {cyclesMet && timeUntilUnlock > 0
              ? `${t("productCard.unlocksIn")} ${formatDuration(timeUntilUnlock, units)}`
              : `${t("productCard.unlocksAfter")} ${requiredCycles} ${t("productCard.cycles")} · ${doneCycles}/${requiredCycles} · ${unlockPercent}%`}
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
      style={{ borderInlineStart: `3px solid ${accent}` }}
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
          <span className="shrink-0 text-right rtl:text-left text-sm text-gram">
            {tier.price} {t("common.gram")}
            {exchangeRate != null && (
              <span className="block text-[10px] font-normal text-nav-inactive/70">
                ≈{(tier.price * exchangeRate).toFixed(2)} USDT
              </span>
            )}
          </span>
        </div>

        <div className="flex items-center justify-between text-xs">
          <span className="text-profit">
            +{(tier.price * (1 + tier.payout_percent / 100)).toFixed(2)} {t("common.gram")}
          </span>
          {usedSlots > 0 && soonestEndsAt ? (
            <span className="flex items-center gap-1 font-mono text-nav-inactive">
              <Timer className="h-3.5 w-3.5 shrink-0 text-neutral-400" />
              {remaining > 0 ? formatDuration(remaining, units) : t("productCard.ready")}
              {usedSlots > 1 ? ` ×${usedSlots}` : ""}
            </span>
          ) : (
            <span className="flex items-center gap-1 text-nav-inactive">
              <Clock className="h-3.5 w-3.5 shrink-0 text-neutral-400" />
              {tier.cycle_hours} {t("productCard.hours")}
            </span>
          )}
        </div>

        <div className="flex flex-wrap items-center gap-1.5 text-[11px] text-nav-inactive">
          <span className="inline-flex items-center gap-1">
            <Layers className="h-3.5 w-3.5 shrink-0 text-amber-400" />
            {t("productCard.slots")} {tier.slots_open}/{tier.slots_max}
            {/* tier.slots_boost badge intentionally not rendered — boosters
                are hidden from the app. slots_total (used everywhere the
                actual slot count matters) already folds it in regardless. */}
          </span>
          {tier.can_buy_max ? (
            <span className="text-profit">· {t("productCard.slotsMaxed")}</span>
          ) : (
            tier.cycles_to_next_slot != null && (
              <span>
                · {t("productCard.nextSlotIn", { n: tier.cycles_to_next_slot })}
              </span>
            )
          )}
        </div>

        {tier.can_buy_max ? (
          <button
            type="button"
            onClick={handleBuyMax}
            disabled={!canStart}
            className={`mt-1 rounded-full py-2 text-sm font-semibold transition-colors ${
              canStart
                ? "gradient-action"
                : "border border-neutral-700/50 bg-neutral-800/60 text-neutral-500"
            }`}
          >
            {!canAfford ? (
              t("productCard.insufficientBalance")
            ) : freeSlots <= 0 ? (
              t("productCard.noFreeSlots")
            ) : (
              <span className="inline-flex items-center justify-center gap-1.5">
                <Flame className="h-4 w-4" />
                {t("productCard.buyMax")} ×{launchQuantity}
              </span>
            )}
          </button>
        ) : (
          <button
            type="button"
            onClick={handleStart}
            disabled={!canStart}
            className={`mt-1 rounded-full py-2 text-sm font-semibold transition-colors ${
              canStart
                ? "gradient-action"
                : "border border-neutral-700/50 bg-neutral-800/60 text-neutral-500"
            }`}
          >
            {!canAfford
              ? t("productCard.insufficientBalance")
              : freeSlots <= 0
                ? t("productCard.noFreeSlots")
                : launchQuantity > 1
                  ? `${t("productCard.launchCycle")} ×${launchQuantity}`
                  : t("productCard.launchCycle")}
          </button>
        )}
      </div>
    </div>
  );
}
