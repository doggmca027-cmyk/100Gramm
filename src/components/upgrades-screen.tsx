"use client";

import type { PlayerState } from "@/lib/types";
import { useLanguage } from "@/lib/i18n/context";
import { TIER_ICON, TIER_ACCENT } from "@/lib/tier-art";
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

        return (
          <div
            key={tier.tier}
            className="gradient-surface rounded-2xl p-4"
            style={{ borderLeft: `3px solid ${TIER_ACCENT[tier.tier] ?? "#8b7765"}` }}
          >
            <div className="flex items-center justify-between">
              <p className="font-semibold">
                {TIER_ICON[tier.tier] ?? "🎴"} {tier.tier}. {pick(tier.name_i18n)}
              </p>
              <p className="text-lg font-bold">
                {tier.slots_open}
                <span className="text-sm text-nav-inactive">/{tier.slots_max}</span>
                {tier.slots_boost > 0 && (
                  <span className="ml-1 text-sm text-boost">+{tier.slots_boost}⚡</span>
                )}
              </p>
            </div>

            {atCap ? (
              <p className="mt-2 text-xs font-semibold text-profit">
                🔥 {t("upgrades.maxReached")}
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

      <div className="gradient-surface rounded-2xl p-5 text-sm text-nav-inactive">
        <p>{t("upgrades.futureNote")}</p>
      </div>
    </div>
  );
}
