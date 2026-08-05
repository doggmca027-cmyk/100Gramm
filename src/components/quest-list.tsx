"use client";

import { useState } from "react";
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
  const [boostGranted, setBoostGranted] = useState(false);
  const ready = Boolean(quest.completed_at) && !quest.claimed_at;

  async function handleClaim() {
    setClaiming(true);
    try {
      const { result, state } = await claimQuest(quest.id);
      if (result.boost_granted) setBoostGranted(true);
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
          {t("productCard.cycles")} ·{" "}
          <span className="text-gram">
            +{quest.reward_amount} {t("common.gram")}
          </span>
          {quest.grants_boost && <span className="ml-1 text-boost">+1 ⚡</span>}
        </p>
        {boostGranted && (
          <p className="mt-1 text-xs font-semibold text-boost">{t("quests.boostGranted")}</p>
        )}
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
  if (quests.length === 0) return null;

  return (
    <div className="flex flex-col gap-2">
      <h2 className="px-1 text-sm font-semibold text-nav-inactive">{t("quests.title")}</h2>
      {quests.map((quest) => (
        <QuestRow key={quest.id} quest={quest} onClaimed={onStateChange} />
      ))}
    </div>
  );
}
