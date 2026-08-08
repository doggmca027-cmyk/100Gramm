"use client";

import { Flame, Zap, Wrench } from "lucide-react";
import type { PlayerState } from "@/lib/types";
import { useLanguage } from "@/lib/i18n/context";
import { TIER_ICON, TIER_ACCENT, DEFAULT_TIER_ICON } from "@/lib/tier-art";
import { BoostInventory } from "./boost-inventory";
import { ItemInventory } from "./item-inventory";

export function UpgradesScreen({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t, pick } = useLanguage();
  const unlockedTiers = state.tiers.filter((tier) => tier.unlocked);

  return (
    <div className="flex flex-1 flex-col gap-3 overflow-y-auto p-4 pb-24">
      <p className="px-1 text-sm text-nav-inactive">{t("upgrades.subtitle")}</p>

      <BoostInventory state={state} onStateChange={onStateChange} />
      <ItemInventory state={state} onStateChange={onStateChange} />

      {unlockedTiers.map((tier) => {
        const atCap = tier.can_buy_max;
        const cyclesIntoLevel = tier.cycles_to_next_slot != null ? 5 - tier.cycles_to_next_slot : 5;
        const progressPercent = atCap ? 100 : Math.min(100, (cyclesIntoLevel / 5) * 100);
        const TierIcon = TIER_ICON[tier.tier] ?? DEFAULT_TIER_ICON;

        return (
          <div
            key={tier.tier}
            className="gradient-surface rounded-2xl p-4"
            style={{ borderInlineStart: `3px solid ${TIER_ACCENT[tier.tier] ?? "#8b7765"}` }}
          >
            <div className="flex items-center justify-between">
              <p className="flex items-center gap-1.5 font-semibold">
                <TierIcon className="h-4 w-4 shrink-0 text-amber-400" />
                {tier.tier}. {pick(tier.name_i18n)}
              </p>
              <p className="text-lg font-bold">
                {tier.slots_open}
                <span className="text-sm text-nav-inactive">/{tier.slots_max}</span>
                {tier.slots_boost > 0 && (
                  <span className="ms-1 inline-flex items-center gap-0.5 text-sm text-boost">
                    +{tier.slots_boost}
                    <Zap className="h-3.5 w-3.5" />
                  </span>
                )}
              </p>
            </div>

            {atCap ? (
              <p className="mt-2 flex items-center gap-1.5 text-xs font-semibold text-profit">
                <Flame className="h-3.5 w-3.5 text-amber-400" />
                {t("upgrades.maxReached")}
              </p>
            ) : (
              <>
                <div className="mt-3 h-1.5 rounded-full bg-progress-bg">
                  <div
                    className="h-1.5 rounded-full bg-progress-fill"
                    style={{ width: `${progressPercent}%` }}
                  />
                </div>
                <p className="mt-2 text-xs text-nav-inactive">
                  {t("upgrades.untilNext", { n: tier.cycles_to_next_slot ?? 0 })}
                </p>
              </>
            )}

            {tier.slots_boost > 0 && (
              <p className="mt-2 text-xs text-boost">{t("productCard.tempSlotNote")}</p>
            )}
          </div>
        );
      })}

      <div className="gradient-surface flex items-start gap-2 rounded-2xl p-5 text-sm text-nav-inactive">
        <Wrench className="mt-0.5 h-4 w-4 shrink-0 text-neutral-400" />
        <p>{t("upgrades.futureNote")}</p>
      </div>
    </div>
  );
}
