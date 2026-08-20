"use client";

import { useState } from "react";
import { AlarmClock } from "lucide-react";
import type { PlayerState, Quest } from "@/lib/types";
import { claimQuest } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";

function QuestRow({
  quest,
  onClaimed,
}: {
  quest: Quest;
  onClaimed: (state: PlayerState) => void;
}) {
  const { t, pick } = useLanguage();
  const [claiming, setClaiming] = useState(false);
  const ready = Boolean(quest.completed_at) && !quest.claimed_at;

  async function handleClaim() {
    setClaiming(true);
    try {
      // result.boost_granted deliberately unused — boosters are hidden
      // from the app, see QuestList's visibleQuests filter and the removed
      // grants_boost badge below. The quest still actually grants the
      // boost server-side either way, just never surfaced here.
      const { state } = await claimQuest(quest.id);
      onClaimed(state);
    } catch {
      // no-op: button just re-enables
    } finally {
      setClaiming(false);
    }
  }

  return (
    <div className="gradient-surface flex items-center justify-between rounded-xl p-3">
      <div>
        <p className="text-sm font-semibold">{pick(quest.title_i18n)}</p>
        <p className="text-xs text-nav-inactive">{pick(quest.description_i18n)}</p>
        <p className="mt-1 text-xs">
          {Math.min(quest.progress_count, quest.target_count)}/{quest.target_count}{" "}
          {t("productCard.cycles")}
          {quest.reward_amount > 0 && (
            <>
              {" · "}
              <span className="text-gram">
                +{quest.reward_amount} {t("common.gram")}
              </span>
            </>
          )}
          {/* grants_boost badge intentionally not rendered — boosters are
              hidden from the app. Quests whose entire reward is the boost
              (reward_amount 0) never reach here at all, see QuestList's
              visibleQuests filter; this covers the hypothetical case of a
              quest combining grants_boost with a real GRAM reward too. */}
        </p>
      </div>
      {quest.claimed_at ? (
        <span className="text-xs text-profit">{t("quests.claimed")}</span>
      ) : (
        <button
          type="button"
          onClick={handleClaim}
          disabled={!ready || claiming}
          className="gradient-action rounded-full px-3 py-1.5 text-xs font-semibold disabled:opacity-40"
        >
          {t("quests.claim")}
        </button>
      )}
    </div>
  );
}

export function QuestList({
  quests,
  onStateChange,
}: {
  quests: Quest[];
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  // Boosters are hidden from the app — both of today's grants_boost quests
  // ("Разгрузка", "Срочный заказ") have reward_amount 0, i.e. the boost IS
  // the entire reward, same as the item-only partner tasks in
  // partner-tasks-section.tsx: nothing left to show if the boost is hidden,
  // so the card is filtered out rather than shown claimable-for-nothing.
  // A quest that ever combines grants_boost with a nonzero reward_amount
  // would still show here, just without the +1⚡ badge (see QuestRow).
  const visibleQuests = quests.filter((quest) => !quest.grants_boost || quest.reward_amount > 0);
  if (visibleQuests.length === 0) return null;

  return (
    <div className="flex flex-col gap-2">
      <h2 className="flex items-center gap-1.5 px-1 text-sm font-semibold text-nav-inactive">
        <AlarmClock className="h-4 w-4 text-amber-400" />
        {t("quests.title")}
      </h2>
      {visibleQuests.map((quest) => (
        <QuestRow key={quest.id} quest={quest} onClaimed={onStateChange} />
      ))}
    </div>
  );
}
