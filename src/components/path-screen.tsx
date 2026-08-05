"use client";

import { useCallback, useState } from "react";
import type { PlayerState } from "@/lib/types";
import { startCycle, buyMaxSlots } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";
import { ProductCard } from "./product-card";
import { ProductDetailScreen } from "./product-detail-screen";
import { PlayerProfileCard } from "./player-profile-card";

export function PathScreen({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const [detailTier, setDetailTier] = useState<number | null>(null);

  const handleStart = useCallback(
    async (tier: number) => {
      try {
        const result = await startCycle(tier);
        onStateChange(result.state);
      } catch {
        // errors (insufficient_balance, no_free_slots, tier_locked) are already
        // prevented by disabling the button; a transient failure just leaves
        // state untouched and the button re-enables itself.
      }
    },
    [onStateChange],
  );

  const handleBuyMax = useCallback(
    async (tier: number) => {
      try {
        const result = await buyMaxSlots(tier);
        onStateChange(result.state);
      } catch {
        // slots_not_maxed / insufficient_balance are prevented by the button's
        // own disabled state; a transient failure just leaves state untouched.
      }
    },
    [onStateChange],
  );

  const openTier = detailTier != null ? state.tiers.find((t) => t.tier === detailTier) : null;
  if (openTier) {
    return (
      <ProductDetailScreen
        tier={openTier}
        activeCycles={state.active_cycles.filter((c) => c.tier === openTier.tier)}
        balance={state.wallet.balance}
        freeSlots={openTier.slots_total - openTier.slots_used}
        slotsTotal={openTier.slots_total}
        onStart={handleStart}
        onBuyMax={handleBuyMax}
        onBack={() => setDetailTier(null)}
      />
    );
  }

  return (
    <div className="flex flex-1 flex-col gap-3 overflow-y-auto p-4 pb-24">
      <PlayerProfileCard state={state} />

      <div className="flex items-center justify-between px-1 text-sm text-nav-inactive">
        <span>
          {t("path.slots")}: {state.wallet.total_slots_used}/{state.wallet.total_slots_open}
        </span>
        <span>
          {state.wallet.completed_cycles_total} {t("path.cyclesDone")}
        </span>
      </div>

      {state.tiers.map((tier, index) => (
        <ProductCard
          key={tier.tier}
          tier={tier}
          previousTier={index > 0 ? state.tiers[index - 1] : null}
          activeCycles={state.active_cycles.filter((c) => c.tier === tier.tier)}
          balance={state.wallet.balance}
          freeSlots={tier.slots_total - tier.slots_used}
          onStart={handleStart}
          onBuyMax={handleBuyMax}
          onOpenDetail={() => setDetailTier(tier.tier)}
        />
      ))}
    </div>
  );
}
