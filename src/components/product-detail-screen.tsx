"use client";

import { useState } from "react";
import type { ActiveCycle, TierState } from "@/lib/types";
import { useCountdown, formatDuration } from "@/hooks/use-countdown";
import { useLanguage } from "@/lib/i18n/context";
import { TIER_RARITY_KEY } from "@/lib/tier-art";
import { TierImage } from "./tier-image";

function SlotTile({ endsAt }: { endsAt: string }) {
  const { t } = useLanguage();
  const remaining = useCountdown(endsAt);
  return (
    <div className="gradient-surface flex flex-col items-center gap-1 rounded-xl p-2">
      <span className="text-lg">🍾</span>
      <span className="font-mono text-[11px] text-nav-inactive">
        {remaining > 0 ? formatDuration(remaining) : t("productCard.ready")}
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
  onBuyMax,
  onBack,
}: {
  tier: TierState;
  activeCycles: ActiveCycle[];
  balance: number;
  freeSlots: number;
  slotsTotal: number;
  onStart: (tier: number) => Promise<void>;
  onBuyMax: (tier: number) => Promise<void>;
  onBack: () => void;
}) {
  const { t, pick } = useLanguage();
  const [starting, setStarting] = useState(false);
  const usedSlots = activeCycles.reduce((sum, c) => sum + c.slot_quantity, 0);
  const slotTiles = activeCycles.flatMap((c) =>
    Array.from({ length: c.slot_quantity }, () => c.ends_at),
  );

  const canAfford = balance >= tier.price;
  const canStart = canAfford && freeSlots > 0 && !starting;
  const launchQuantity = Math.max(1, Math.min(freeSlots, Math.floor(balance / tier.price)));
  const totalPrice = tier.price * launchQuantity;
  const description = pick(tier.description_i18n);
  const rarityKey = TIER_RARITY_KEY[tier.tier] ?? "Common";

  async function handleStart() {
    setStarting(true);
    try {
      await onStart(tier.tier);
    } finally {
      setStarting(false);
    }
  }

  async function handleBuyMax() {
    setStarting(true);
    try {
      await onBuyMax(tier.tier);
    } finally {
      setStarting(false);
    }
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="bg-header flex items-center gap-3 px-4 py-3">
        <button type="button" onClick={onBack} aria-label={t("common.back")} className="text-lg">
          ←
        </button>
        <p className="font-semibold">{t("productDetail.title")}</p>
      </header>

      <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4 pb-40">
        <TierImage tier={tier.tier} className="aspect-square w-full rounded-2xl" emojiClassName="text-6xl" />

        <div>
          <div className="flex items-center gap-2">
            <h1 className="text-lg font-bold">
              {tier.tier}. {pick(tier.name_i18n)}
            </h1>
            <span className="gradient-surface rounded-full px-2 py-0.5 text-[10px] text-nav-inactive">
              {t(`productDetail.rarity${rarityKey}` as `productDetail.${string}`)}
            </span>
          </div>
          {description && <p className="mt-1 text-sm text-nav-inactive">{description}</p>}
        </div>

        <div className="grid grid-cols-2 gap-2">
          {[
            [t("productDetail.price"), `${tier.price} ${t("common.gram")}`],
            [
              t("productDetail.profit"),
              `+${(tier.price * (1 + tier.payout_percent / 100)).toFixed(2)} ${t("common.gram")}`,
            ],
            [t("productDetail.yield"), `${tier.payout_percent}%`],
            [t("productDetail.cycle"), `${tier.cycle_hours} ${t("productCard.hours")}`],
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
              {t("productDetail.slots")} ({usedSlots}/{slotsTotal})
            </h2>
            {tier.can_buy_max ? (
              <span className="text-xs font-semibold text-profit">
                🔥 {t("productCard.slotsMaxed")}
              </span>
            ) : (
              tier.cycles_to_next_slot != null && (
                <span className="text-xs text-nav-inactive">
                  {t("productCard.nextSlotIn", { n: tier.cycles_to_next_slot })}
                </span>
              )
            )}
          </div>
          <div className="grid grid-cols-4 gap-2">
            {slotTiles.map((endsAt, i) => (
              <SlotTile key={i} endsAt={endsAt} />
            ))}
            {Array.from({ length: Math.max(0, tier.slots_max - slotsTotal) }, (_, i) => (
              <div
                key={`locked-${i}`}
                className="flex flex-col items-center justify-center gap-1 rounded-xl border border-dashed border-border p-2 text-nav-inactive opacity-50"
              >
                <span className="text-lg">🔒</span>
                <span className="text-[10px]">{t("productDetail.lockedSlot")}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      <div className="fixed inset-x-0 bottom-16 p-4">
        {tier.can_buy_max ? (
          <button
            type="button"
            onClick={handleBuyMax}
            disabled={!canStart}
            className="gradient-action w-full rounded-full py-3 text-sm font-semibold disabled:opacity-40"
          >
            {!canAfford
              ? t("productCard.insufficientBalance")
              : freeSlots <= 0
                ? t("productCard.noFreeSlots")
                : `🔥 ${t("productCard.buyMax")} ×${launchQuantity} (${totalPrice.toFixed(2)} ${t("common.gram")})`}
          </button>
        ) : (
          <button
            type="button"
            onClick={handleStart}
            disabled={!canStart}
            className="gradient-action w-full rounded-full py-3 text-sm font-semibold disabled:opacity-40"
          >
            {!canAfford
              ? t("productCard.insufficientBalance")
              : freeSlots <= 0
                ? t("productCard.noFreeSlots")
                : `${t("productDetail.launchCycle")} (${totalPrice.toFixed(2)} ${t("common.gram")})`}
          </button>
        )}
      </div>
    </div>
  );
}
