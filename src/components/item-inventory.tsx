"use client";

import { useState } from "react";
import { X, Bot, Boxes, Gift } from "lucide-react";
import type { InventoryItem, PlayerState } from "@/lib/types";
import { useCountdown, formatDuration } from "@/hooks/use-countdown";
import { useLanguage } from "@/lib/i18n/context";
import { applyAutoCollectItem, applyTimeSkipItem } from "@/lib/api-client";
import { ITEM_ICON, itemNameKey, itemDescKey } from "@/lib/combo-items";
import { TIER_ICON, DEFAULT_TIER_ICON } from "@/lib/tier-art";

function ItemCard({
  item,
  state,
  onStateChange,
}: {
  item: InventoryItem;
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t, pick } = useLanguage();
  const secondsLeft = useCountdown(item.expires_at);
  const [pickerOpen, setPickerOpen] = useState(false);
  const [applying, setApplying] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const hasActiveCycles = state.active_cycles.length > 0;
  const isTimeSkip = item.category === "time_skip";
  const Icon = ITEM_ICON[item.item_type] ?? Gift;

  async function applyTo(cycleId: string) {
    setApplying(true);
    setError(null);
    try {
      const { state: newState } = await applyTimeSkipItem(item.item_type, cycleId);
      onStateChange(newState);
      setPickerOpen(false);
    } catch {
      setError(t("items.applyError"));
    } finally {
      setApplying(false);
    }
  }

  async function handleAutoCollectClick() {
    setApplying(true);
    setError(null);
    try {
      const { state: newState } = await applyAutoCollectItem(item.item_type);
      onStateChange(newState);
    } catch {
      setError(t("items.applyError"));
    } finally {
      setApplying(false);
    }
  }

  return (
    <div className="gradient-surface flex flex-col gap-2 rounded-xl p-3">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Icon className="h-6 w-6 shrink-0 text-purple-400" />
          <div>
            <p className="text-sm font-semibold">
              {t(itemNameKey(item.item_type))} <span className="text-nav-inactive">×{item.quantity}</span>
            </p>
            <p className="text-xs text-nav-inactive">{t(itemDescKey(item.item_type))}</p>
          </div>
        </div>
      </div>

      <div className="flex items-center justify-between text-xs">
        <span className="text-nav-inactive">
          {t("items.expiresIn", { time: formatDuration(secondsLeft) })}
        </span>
        <button
          type="button"
          onClick={isTimeSkip ? () => setPickerOpen(true) : handleAutoCollectClick}
          disabled={applying || (isTimeSkip && !hasActiveCycles)}
          className="gradient-action shrink-0 rounded-full px-3 py-1.5 text-xs font-semibold disabled:opacity-40"
        >
          {t("items.use")}
        </button>
      </div>

      {isTimeSkip && !hasActiveCycles && (
        <p className="text-xs text-danger">{t("items.noActiveCycle")}</p>
      )}
      {error && <p className="text-xs text-danger">{error}</p>}

      {pickerOpen && (
        <div
          className="fixed inset-0 z-50 flex flex-col justify-end bg-black/60"
          onClick={() => setPickerOpen(false)}
        >
          <div
            className="bg-nav flex max-h-[80vh] flex-col gap-3 rounded-t-2xl p-4"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between">
              <h2 className="text-base font-semibold">{t("items.pickCycle")}</h2>
              <button
                type="button"
                onClick={() => setPickerOpen(false)}
                className="text-nav-inactive"
                aria-label={t("common.back")}
              >
                <X className="h-5 w-5" />
              </button>
            </div>
            <div className="flex flex-col gap-2 overflow-y-auto">
              {state.active_cycles.map((cycle) => {
                const tierInfo = state.tiers.find((candidate) => candidate.tier === cycle.tier);
                const CycleIcon = TIER_ICON[cycle.tier] ?? DEFAULT_TIER_ICON;
                return (
                  <button
                    key={cycle.id}
                    type="button"
                    onClick={() => applyTo(cycle.id)}
                    disabled={applying}
                    className="gradient-surface flex items-center justify-between rounded-xl p-3 text-left rtl:text-right disabled:opacity-50"
                  >
                    <span className="flex items-center gap-2 text-sm font-semibold">
                      <CycleIcon className="h-5 w-5 shrink-0 text-amber-400" />
                      {cycle.tier}. {tierInfo ? pick(tierInfo.name_i18n) : ""}
                    </span>
                    <span className="text-xs text-nav-inactive">
                      {formatDuration(Math.floor(cycle.seconds_remaining))}
                    </span>
                  </button>
                );
              })}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

export function ItemInventory({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const autoCollectActive =
    state.wallet.auto_collect_until != null && new Date(state.wallet.auto_collect_until) > new Date();

  if (state.inventory.length === 0 && !autoCollectActive) return null;

  return (
    <div className="flex flex-col gap-2">
      <h2 className="flex items-center gap-1.5 px-1 text-sm font-semibold text-nav-inactive">
        <Boxes className="h-4 w-4 text-neutral-400" />
        {t("items.inventoryTitle")}
      </h2>
      {autoCollectActive && (
        <p className="flex items-center gap-1.5 gradient-surface rounded-xl p-3 text-xs text-profit">
          <Bot className="h-4 w-4 shrink-0 text-purple-400" />
          {t("items.autoCollectActiveUntil", { time: new Date(state.wallet.auto_collect_until!).toLocaleString() })}
        </p>
      )}
      {state.inventory.map((item) => (
        <ItemCard key={item.item_type} item={item} state={state} onStateChange={onStateChange} />
      ))}
    </div>
  );
}
