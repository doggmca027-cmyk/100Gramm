"use client";

import { useState } from "react";
import type { Boost, PlayerState } from "@/lib/types";
import { useCountdown, formatDuration } from "@/hooks/use-countdown";
import { useLanguage } from "@/lib/i18n/context";
import { applyBoost } from "@/lib/api-client";
import { TIER_ICON } from "@/lib/tier-art";

function BoostRow({
  boost,
  state,
  onStateChange,
}: {
  boost: Boost;
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t, pick } = useLanguage();
  const secondsLeft = useCountdown(boost.expires_at);
  const [pickerOpen, setPickerOpen] = useState(false);
  const [applying, setApplying] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const activeTier =
    boost.status === "ACTIVE" && boost.target_tier != null
      ? state.tiers.find((candidate) => candidate.tier === boost.target_tier)
      : null;

  async function handlePick(tier: number) {
    setApplying(true);
    setError(null);
    try {
      const { state: newState } = await applyBoost(boost.id, tier);
      onStateChange(newState);
      setPickerOpen(false);
    } catch {
      setError(t("boosts.applyError"));
    } finally {
      setApplying(false);
    }
  }

  return (
    <div className="gradient-surface flex items-center justify-between rounded-xl p-3">
      <div className="flex items-center gap-2">
        <span className="text-2xl">⚡</span>
        <div>
          <p className="text-sm font-semibold">{t("boosts.extraSlot")}</p>
          {boost.status === "PENDING" ? (
            <p className="text-xs text-nav-inactive">
              {t("boosts.expiresIn", { time: formatDuration(secondsLeft) })}
            </p>
          ) : (
            <p className="text-xs text-profit">
              {t("boosts.appliedTo", {
                tier: activeTier ? `${activeTier.tier}. ${pick(activeTier.name_i18n)}` : "?",
              })}
            </p>
          )}
        </div>
      </div>

      {boost.status === "PENDING" && (
        <button
          type="button"
          onClick={() => setPickerOpen(true)}
          className="gradient-action shrink-0 rounded-full px-3 py-1.5 text-xs font-semibold"
        >
          {t("boosts.apply")}
        </button>
      )}

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
              <h2 className="text-base font-semibold">{t("boosts.pickItem")}</h2>
              <button
                type="button"
                onClick={() => setPickerOpen(false)}
                className="text-nav-inactive"
                aria-label={t("common.back")}
              >
                ✕
              </button>
            </div>
            {error && <p className="text-xs text-danger">{error}</p>}
            <div className="flex flex-col gap-2 overflow-y-auto">
              {state.tiers
                .filter((tier) => tier.unlocked)
                .map((tier) => (
                  <button
                    key={tier.tier}
                    type="button"
                    onClick={() => handlePick(tier.tier)}
                    disabled={applying}
                    className="gradient-surface flex items-center gap-3 rounded-xl p-3 text-left rtl:text-right disabled:opacity-50"
                  >
                    <span className="text-2xl">{TIER_ICON[tier.tier] ?? "🎴"}</span>
                    <span className="text-sm font-semibold">
                      {tier.tier}. {pick(tier.name_i18n)}
                    </span>
                  </button>
                ))}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

export function BoostInventory({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  if (state.boosts.length === 0) return null;

  return (
    <div className="flex flex-col gap-2">
      <h2 className="px-1 text-sm font-semibold text-nav-inactive">{t("boosts.title")}</h2>
      {state.boosts.map((boost) => (
        <BoostRow key={boost.id} boost={boost} state={state} onStateChange={onStateChange} />
      ))}
    </div>
  );
}
