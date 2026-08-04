"use client";

import { useState } from "react";
import type { ActiveCycle, TierState } from "@/lib/types";
import { useCountdown, formatDuration } from "@/hooks/use-countdown";
import { TIER_RARITY } from "@/lib/tier-art";
import { TierImage } from "./tier-image";

function SlotTile({ endsAt }: { endsAt: string }) {
  const remaining = useCountdown(endsAt);
  return (
    <div className="gradient-surface flex flex-col items-center gap-1 rounded-xl p-2">
      <span className="text-lg">🍾</span>
      <span className="font-mono text-[11px] text-nav-inactive">
        {remaining > 0 ? formatDuration(remaining) : "Готово"}
      </span>
    </div>
  );
}

export function ProductDetailScreen({
  tier,
  activeCycles,
  balance,
  freeSlots,
  slotsTotal,
  onStart,
  onBack,
}: {
  tier: TierState;
  activeCycles: ActiveCycle[];
  balance: number;
  freeSlots: number;
  slotsTotal: number;
  onStart: (tier: number) => Promise<void>;
  onBack: () => void;
}) {
  const [starting, setStarting] = useState(false);
  const usedSlots = activeCycles.reduce((sum, c) => sum + c.slot_quantity, 0);
  const slotTiles = activeCycles.flatMap((c) =>
    Array.from({ length: c.slot_quantity }, () => c.ends_at),
  );

  const canAfford = balance >= tier.price;
  const canStart = canAfford && freeSlots > 0 && !starting;
  const launchQuantity = Math.max(1, Math.min(freeSlots, Math.floor(balance / tier.price)));
  const totalPrice = tier.price * launchQuantity;

  async function handleStart() {
    setStarting(true);
    try {
      await onStart(tier.tier);
    } finally {
      setStarting(false);
    }
  }

  return (
    <div className="flex flex-1 flex-col">
      <header className="bg-header flex items-center gap-3 px-4 py-3">
        <button type="button" onClick={onBack} aria-label="Назад" className="text-lg">
          ←
        </button>
        <p className="font-semibold">О предприятии</p>
      </header>

      <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4 pb-28">
        <TierImage tier={tier.tier} className="h-48 w-full rounded-2xl" emojiClassName="text-6xl" />

        <div>
          <div className="flex items-center gap-2">
            <h1 className="text-lg font-bold">
              {tier.tier}. {tier.name}
            </h1>
            <span className="gradient-surface rounded-full px-2 py-0.5 text-[10px] text-nav-inactive">
              {TIER_RARITY[tier.tier] ?? "Обычное"}
            </span>
          </div>
          {tier.description && (
            <p className="mt-1 text-sm text-nav-inactive">{tier.description}</p>
          )}
        </div>

        <div className="grid grid-cols-2 gap-2">
          {[
            ["Цена", `${tier.price} GRAM`],
            ["Прибыль", `+${(tier.price * (1 + tier.payout_percent / 100)).toFixed(2)} GRAM`],
            ["Доходность", `${tier.payout_percent}%`],
            ["Цикл", `${tier.cycle_hours} ч`],
          ].map(([label, value]) => (
            <div key={label} className="gradient-surface rounded-xl p-3">
              <p className="text-xs text-nav-inactive">{label}</p>
              <p className="text-sm font-semibold">{value}</p>
            </div>
          ))}
        </div>

        <div>
          <div className="mb-2 flex items-center justify-between">
            <h2 className="text-sm font-semibold text-nav-inactive">
              Слоты ({usedSlots}/{slotsTotal})
            </h2>
          </div>
          <div className="grid grid-cols-4 gap-2">
            {slotTiles.map((endsAt, i) => (
              <SlotTile key={i} endsAt={endsAt} />
            ))}
            <button
              type="button"
              disabled
              className="gradient-surface flex flex-col items-center justify-center gap-1 rounded-xl p-2 text-nav-inactive opacity-50"
              title="Скоро"
            >
              <span className="text-lg">+</span>
              <span className="text-[10px]">Купить слот</span>
            </button>
          </div>
        </div>
      </div>

      <div className="fixed inset-x-0 bottom-16 p-4">
        <button
          type="button"
          onClick={handleStart}
          disabled={!canStart}
          className="gradient-action w-full rounded-full py-3 text-sm font-semibold disabled:opacity-40"
        >
          {!canAfford
            ? "Недостаточно GRAM"
            : freeSlots <= 0
              ? "Нет свободных слотов"
              : `Запустить цикл (${totalPrice.toFixed(2)} GRAM)`}
        </button>
      </div>
    </div>
  );
}
