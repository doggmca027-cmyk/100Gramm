"use client";

import { useState } from "react";
import type { PlayerState, Quest } from "@/lib/types";
import { claimQuest } from "@/lib/api-client";

function QuestRow({
  quest,
  onClaimed,
}: {
  quest: Quest;
  onClaimed: (state: PlayerState) => void;
}) {
  const [claiming, setClaiming] = useState(false);
  const ready = Boolean(quest.completed_at) && !quest.claimed_at;

  async function handleClaim() {
    setClaiming(true);
    try {
      const result = await claimQuest(quest.id);
      onClaimed(result.state);
    } catch {
      // no-op: button just re-enables
    } finally {
      setClaiming(false);
    }
  }

  return (
    <div className="gradient-surface flex items-center justify-between rounded-xl p-3">
      <div>
        <p className="text-sm font-semibold">{quest.title}</p>
        <p className="text-xs text-nav-inactive">{quest.description}</p>
        <p className="mt-1 text-xs">
          {Math.min(quest.progress_count, quest.target_count)}/{quest.target_count} циклов ·{" "}
          <span className="text-gram">+{quest.reward_amount} GRAM</span>
        </p>
      </div>
      {quest.claimed_at ? (
        <span className="text-xs text-profit">Получено</span>
      ) : (
        <button
          type="button"
          onClick={handleClaim}
          disabled={!ready || claiming}
          className="gradient-action rounded-full px-3 py-1.5 text-xs font-semibold disabled:opacity-40"
        >
          Забрать
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
  if (quests.length === 0) return null;

  return (
    <div className="flex flex-col gap-2">
      <h2 className="px-1 text-sm font-semibold text-nav-inactive">
        ⏰ Срочные заказы
      </h2>
      {quests.map((quest) => (
        <QuestRow key={quest.id} quest={quest} onClaimed={onStateChange} />
      ))}
    </div>
  );
}
