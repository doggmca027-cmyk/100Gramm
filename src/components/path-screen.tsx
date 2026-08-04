"use client";

import { useCallback, useState } from "react";
import type { PlayerState } from "@/lib/types";
import { startCycle } from "@/lib/api-client";
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
  const [detailTier, setDetailTier] = useState<number | null>(null);
  const usedSlots = state.active_cycles.reduce((sum, c) => sum + c.slot_quantity, 0);
  const freeSlots = state.wallet.slots_count - usedSlots;

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

  const openTier = detailTier != null ? state.tiers.find((t) => t.tier === detailTier) : null;
  if (openTier) {
    return (
      <ProductDetailScreen
        tier={openTier}
        activeCycles={state.active_cycles.filter((c) => c.tier === openTier.tier)}
        balance={state.wallet.balance}
        freeSlots={freeSlots}
        slotsTotal={state.wallet.slots_count}
        onStart={handleStart}
        onBack={() => setDetailTier(null)}
      />
    );
  }

  return (
    <div className="flex flex-1 flex-col gap-3 overflow-y-auto p-4 pb-24">
      <PlayerProfileCard state={state} />

      <div className="flex items-center justify-between px-1 text-sm text-nav-inactive">
        <span>
          Слоты: {usedSlots}/{state.wallet.slots_count}
        </span>
        <span>{state.wallet.completed_cycles_total} циклов пройдено</span>
      </div>

      {state.tiers.map((tier, index) => (
        <ProductCard
          key={tier.tier}
          tier={tier}
          previousTier={index > 0 ? state.tiers[index - 1] : null}
          activeCycles={state.active_cycles.filter((c) => c.tier === tier.tier)}
          balance={state.wallet.balance}
          freeSlots={freeSlots}
          onStart={handleStart}
          onOpenDetail={() => setDetailTier(tier.tier)}
        />
      ))}
    </div>
  );
}
