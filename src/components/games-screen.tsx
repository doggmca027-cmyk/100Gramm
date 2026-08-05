"use client";

import type { PlayerState } from "@/lib/types";
import { useLanguage } from "@/lib/i18n/context";
import { useCountdown, formatDuration } from "@/hooks/use-countdown";
import { TIER_ICON, TIER_ACCENT } from "@/lib/tier-art";

// Fallback for useCountdown when there's no combo yet (e.g. season just
// ended) — a fixed far-future placeholder, never actually rendered since the
// component bails out to the "coming soon" stub in that case.
const NO_COMBO_FALLBACK_ISO = "2099-01-01T00:00:00.000Z";

export function GamesScreen({
  state,
  onNavigateToPath,
}: {
  state: PlayerState;
  onNavigateToPath: () => void;
}) {
  const { t, pick } = useLanguage();
  const combo = state.daily_combo;
  const secondsLeft = useCountdown(combo?.resets_at ?? NO_COMBO_FALLBACK_ISO);

  if (!combo) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center">
        <p className="text-3xl">🎮</p>
        <p className="font-semibold">{t("games.title")}</p>
        <p className="text-sm text-nav-inactive">{t("games.description")}</p>
      </div>
    );
  }

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4 pb-24">
      <div className="text-center">
        <p className="text-lg font-bold">{t("games.comboTitle")}</p>
        <p className="mt-1 text-sm text-nav-inactive">{t("games.comboSubtitle")}</p>
      </div>

      {combo.is_completed && (
        <div className="gradient-action rounded-xl p-3 text-center">
          <p className="font-semibold">🎉 {t("games.comboCompletedTitle")}</p>
          <p className="text-sm opacity-90">
            {t("games.comboCompletedBody", { amount: combo.reward_amount.toFixed(2) })}
          </p>
        </div>
      )}

      <div className="grid grid-cols-2 gap-3">
        {combo.slots.map((slot, i) => (
          <div
            key={i}
            className="gradient-surface flex aspect-square flex-col items-center justify-center gap-1 rounded-2xl p-3"
            style={
              slot.found && slot.tier
                ? { boxShadow: `0 0 0 2px ${TIER_ACCENT[slot.tier] ?? "#9b35ff"}` }
                : undefined
            }
          >
            {slot.found ? (
              <>
                <span className="text-3xl">{slot.tier ? TIER_ICON[slot.tier] : "🎴"}</span>
                <span className="text-center text-xs font-semibold">
                  {pick(slot.name_i18n) || slot.name}
                </span>
              </>
            ) : (
              <>
                <span className="text-3xl opacity-40">❓</span>
                <span className="text-xs text-nav-inactive">{t("games.comboMystery")}</span>
              </>
            )}
          </div>
        ))}
      </div>

      <div className="gradient-surface flex flex-col gap-2 rounded-xl p-3 text-center">
        <p className="text-sm text-nav-inactive">
          {t("games.comboFound", { found: combo.found_count, total: combo.total_count })}
        </p>
        <p className="gradient-gram bg-clip-text text-lg font-bold text-transparent">
          {t("games.comboReward")}: +{combo.reward_amount.toFixed(2)} {t("common.gram")}
        </p>
        <p className="text-xs text-nav-inactive">
          {t("games.comboResetsIn", { time: formatDuration(secondsLeft) })}
        </p>
      </div>

      <p className="px-2 text-center text-xs text-nav-inactive">{t("games.comboHint")}</p>

      <button
        type="button"
        onClick={onNavigateToPath}
        className="gradient-action rounded-full py-3 text-sm font-semibold"
      >
        {t("games.comboCta")}
      </button>
    </div>
  );
}
