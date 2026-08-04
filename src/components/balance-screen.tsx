"use client";

import type { PlayerState } from "@/lib/types";
import { QuestList } from "./quest-list";
import { ComingSoonSection } from "./coming-soon-section";

export function BalanceScreen({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  return (
    <div className="flex flex-1 flex-col gap-5 overflow-y-auto p-4 pb-24">
      <div className="gradient-surface rounded-2xl p-5 text-center">
        <p className="text-xs text-nav-inactive">Баланс</p>
        <p className="gradient-gram bg-clip-text text-3xl font-bold text-transparent">
          {state.wallet.balance.toFixed(2)} GRAM
        </p>
        <p className="mt-1 text-xs text-nav-inactive">
          Всего заработано: {state.wallet.total_earned.toFixed(2)} GRAM
        </p>
      </div>

      <QuestList quests={state.quests} onStateChange={onStateChange} />
      <ComingSoonSection
        icon="📦"
        title="Контейнеры"
        description="Появятся в одном из следующих сезонов."
      />
    </div>
  );
}
