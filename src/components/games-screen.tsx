"use client";

import { useState } from "react";
import type { PlayerState } from "@/lib/types";
import { useLanguage } from "@/lib/i18n/context";
import { useCountdown, formatDuration } from "@/hooks/use-countdown";
import { TIER_ICON, TIER_ACCENT } from "@/lib/tier-art";
import { submitComboGuess } from "@/lib/api-client";
import { itemIcon, itemNameKey } from "@/lib/combo-items";

// Fallback for useCountdown when there's no combo yet (e.g. season just
// ended) — a fixed far-future placeholder, never actually rendered since the
// component bails out to the "coming soon" stub in that case.
const NO_COMBO_FALLBACK_ISO = "2099-01-01T00:00:00.000Z";

const CORRECT_COLOR = "#38D996";
const WRONG_COLOR = "#ff5c5c";

export function GamesScreen({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t, pick } = useLanguage();
  const combo = state.daily_combo;
  const secondsLeft = useCountdown(combo?.resets_at ?? NO_COMBO_FALLBACK_ISO);

  // Client-side staging area — nothing is sent to the server until "Проверить
  // комбо" is pressed. Pre-filled from the last submitted guess so a page
  // reload doesn't lose the player's previous attempt/feedback.
  const [slots, setSlots] = useState<(number | null)[]>(() => {
    const initial = combo?.last_guess?.map((g) => g.tier) ?? [];
    return [0, 1, 2, 3].map((i) => initial[i] ?? null);
  });
  const [feedback, setFeedback] = useState<boolean[] | null>(
    combo?.last_guess?.map((g) => g.correct) ?? null,
  );
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!combo) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-center">
        <p className="text-3xl">🎮</p>
        <p className="font-semibold">{t("games.title")}</p>
        <p className="text-sm text-nav-inactive">{t("games.description")}</p>
      </div>
    );
  }

  const attemptsLeft = Math.max(0, combo.attempts_max - combo.attempts_used);
  const outOfAttempts = !combo.is_completed && attemptsLeft <= 0;
  const canEdit = !combo.is_completed && !outOfAttempts;
  const placedTiers = new Set(slots.filter((s): s is number => s != null));
  const allFilled = slots.every((s) => s != null);

  function placeTier(tier: number) {
    if (!canEdit || placedTiers.has(tier)) return;
    const emptyIndex = slots.findIndex((s) => s == null);
    if (emptyIndex === -1) return;
    setFeedback(null);
    setError(null);
    setSlots((prev) => prev.map((s, i) => (i === emptyIndex ? tier : s)));
  }

  function clearSlot(index: number) {
    if (!canEdit) return;
    setFeedback(null);
    setError(null);
    setSlots((prev) => prev.map((s, i) => (i === index ? null : s)));
  }

  async function handleSubmit() {
    if (!allFilled || submitting || !canEdit) return;
    setSubmitting(true);
    setError(null);
    try {
      const { result, state: newState } = await submitComboGuess(slots as number[]);
      setFeedback(result.correct);
      onStateChange(newState);
    } catch {
      setError(t("games.comboSubmitError"));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4 pb-24">
      <div className="text-center">
        <p className="text-lg font-bold">{t("games.comboTitle")}</p>
        <p className="mt-1 text-sm text-nav-inactive">{t("games.comboSubtitle")}</p>
      </div>

      {combo.is_completed ? (
        <>
          <div className="gradient-action rounded-xl p-3 text-center">
            <p className="font-semibold">🎉 {t("games.comboCompletedTitle")}</p>
            <p className="text-sm opacity-90">
              {combo.reward_item
                ? t("games.comboCompletedBody", {
                    item: `${itemIcon(combo.reward_item.item_type)} ${t(itemNameKey(combo.reward_item.item_type))}`,
                  })
                : t("games.comboCompletedBodyUnknown")}
            </p>
          </div>
          <div className="grid grid-cols-4 gap-2">
            {(combo.revealed_tiers ?? []).map((card, i) => (
              <div
                key={i}
                className="gradient-surface flex aspect-square flex-col items-center justify-center gap-1 rounded-2xl p-2"
                style={{ boxShadow: `0 0 0 2px ${TIER_ACCENT[card.tier] ?? "#9b35ff"}` }}
              >
                <span className="text-2xl">{TIER_ICON[card.tier] ?? "🎴"}</span>
                <span className="text-center text-[10px] font-semibold">
                  {pick(card.name_i18n) || card.name}
                </span>
              </div>
            ))}
          </div>
        </>
      ) : outOfAttempts ? (
        <div className="gradient-surface rounded-xl p-4 text-center">
          <p className="font-semibold text-danger">{t("games.comboOutOfAttempts")}</p>
          <p className="mt-1 text-xs text-nav-inactive">
            {t("games.comboResetsIn", { time: formatDuration(secondsLeft) })}
          </p>
        </div>
      ) : (
        <>
          <div className="gradient-surface flex flex-col gap-2 rounded-xl p-3 text-sm">
            <div className="flex items-center justify-between">
              <span className="text-nav-inactive">{t("games.comboReward")}</span>
              <span className="font-semibold">{t("games.comboAttemptsLeft", { n: attemptsLeft })}</span>
            </div>
            <div className="flex flex-wrap gap-2">
              {combo.possible_drops.map((drop) => (
                <span
                  key={drop.item_type}
                  className="flex items-center gap-1 rounded-full bg-progress-bg px-2 py-1 text-[10px] text-nav-inactive"
                >
                  {itemIcon(drop.item_type)} {t(itemNameKey(drop.item_type))} · {drop.drop_weight}%
                </span>
              ))}
            </div>
          </div>

          <div className="grid grid-cols-4 gap-2">
            {slots.map((tier, i) => {
              const isCorrect = feedback ? feedback[i] : null;
              const ring =
                isCorrect === true ? CORRECT_COLOR : isCorrect === false ? WRONG_COLOR : null;
              return (
                <button
                  type="button"
                  key={i}
                  onClick={() => clearSlot(i)}
                  disabled={!canEdit || tier == null}
                  className="gradient-surface flex aspect-square flex-col items-center justify-center gap-1 rounded-2xl p-2 disabled:opacity-100"
                  style={ring ? { boxShadow: `0 0 0 2px ${ring}` } : undefined}
                >
                  {tier != null ? (
                    <>
                      <span className="text-2xl">{TIER_ICON[tier] ?? "🎴"}</span>
                      {isCorrect != null && <span className="text-[10px]">{isCorrect ? "✅" : "❌"}</span>}
                    </>
                  ) : (
                    <span className="text-lg font-bold text-nav-inactive">{i + 1}</span>
                  )}
                </button>
              );
            })}
          </div>

          <p className="px-1 text-center text-xs text-nav-inactive">{t("games.comboInstructions")}</p>

          <div className="grid grid-cols-4 gap-2">
            {combo.pool.map((card) => {
              const placed = placedTiers.has(card.tier);
              return (
                <button
                  type="button"
                  key={card.tier}
                  onClick={() => placeTier(card.tier)}
                  disabled={!canEdit || placed}
                  className="gradient-surface flex flex-col items-center gap-1 rounded-xl p-2 disabled:opacity-30"
                >
                  <span className="text-2xl">{TIER_ICON[card.tier] ?? "🎴"}</span>
                  <span className="text-center text-[10px] text-nav-inactive">
                    {pick(card.name_i18n) || card.name}
                  </span>
                </button>
              );
            })}
          </div>

          {error && <p className="text-center text-xs text-danger">{error}</p>}

          <button
            type="button"
            onClick={handleSubmit}
            disabled={!allFilled || submitting}
            className="gradient-action rounded-full py-3 text-sm font-semibold disabled:opacity-40"
          >
            {t("games.comboCheck")}
          </button>

          <p className="text-center text-xs text-nav-inactive">
            {t("games.comboResetsIn", { time: formatDuration(secondsLeft) })}
          </p>
        </>
      )}
    </div>
  );
}
