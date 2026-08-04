"use client";

import type { PlayerState } from "@/lib/types";
import { useLanguage } from "@/lib/i18n/context";

export function UpgradesScreen({ state }: { state: PlayerState }) {
  const { t } = useLanguage();
  const { base_slots, cycles_per_slot, max_slots } = state.season.config;
  const atCap = max_slots != null && state.wallet.slots_count >= max_slots;

  const cyclesForCurrentSlots =
    (state.wallet.slots_count - base_slots) * cycles_per_slot;
  const cyclesIntoCurrentSlot =
    state.wallet.completed_cycles_total - cyclesForCurrentSlots;
  const progressPercent = atCap
    ? 100
    : Math.min(100, (cyclesIntoCurrentSlot / cycles_per_slot) * 100);
  const cyclesRemaining = Math.max(0, cycles_per_slot - cyclesIntoCurrentSlot);

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4 pb-24">
      <div className="gradient-surface rounded-2xl p-5">
        <p className="text-sm text-nav-inactive">{t("upgrades.slots")}</p>
        <p className="text-3xl font-bold">{state.wallet.slots_count}</p>
        {atCap ? (
          <p className="mt-2 text-xs text-nav-inactive">{t("upgrades.maxReached")}</p>
        ) : (
          <>
            <div className="mt-3 h-1.5 rounded-full bg-progress-bg">
              <div
                className="h-1.5 rounded-full bg-progress-fill"
                style={{ width: `${progressPercent}%` }}
              />
            </div>
            <p className="mt-2 text-xs text-nav-inactive">
              {t("upgrades.untilNext", { n: cyclesRemaining, per: cycles_per_slot })}
            </p>
          </>
        )}
      </div>

      <div className="gradient-surface rounded-2xl p-5 text-sm text-nav-inactive">
        <p>{t("upgrades.futureNote")}</p>
      </div>
    </div>
  );
}
