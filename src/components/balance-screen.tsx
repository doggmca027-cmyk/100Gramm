"use client";

import { useState } from "react";
import type { PlayerState } from "@/lib/types";
import { QuestList } from "./quest-list";
import { ComingSoonSection } from "./coming-soon-section";
import { HistoryModal } from "./history-modal";

export function BalanceScreen({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const [historyOpen, setHistoryOpen] = useState(false);
  const usedSlots = state.active_cycles.reduce((sum, c) => sum + c.slot_quantity, 0);

  return (
    <div className="flex flex-1 flex-col gap-5 overflow-y-auto p-4 pb-24">
      <div className="gradient-surface rounded-2xl p-5 text-center">
        <p className="text-xs text-nav-inactive">Ваш баланс</p>
        <p className="gradient-gram bg-clip-text text-3xl font-bold text-transparent">
          {state.wallet.balance.toFixed(2)} GRAM
        </p>
      </div>

      <div className="grid grid-cols-3 gap-2">
        <button
          type="button"
          disabled
          className="gradient-surface flex flex-col items-center gap-1 rounded-xl p-3 text-xs opacity-40"
        >
          <span className="text-lg">⬆️</span>
          Пополнить
        </button>
        <button
          type="button"
          disabled
          className="gradient-surface flex flex-col items-center gap-1 rounded-xl p-3 text-xs opacity-40"
        >
          <span className="text-lg">⬇️</span>
          Вывести
        </button>
        <button
          type="button"
          onClick={() => setHistoryOpen(true)}
          className="gradient-surface flex flex-col items-center gap-1 rounded-xl p-3 text-xs"
        >
          <span className="text-lg">📜</span>
          История
        </button>
      </div>

      <div className="flex flex-col gap-2">
        <h2 className="px-1 text-sm font-semibold text-nav-inactive">Статистика</h2>
        <div className="gradient-surface flex flex-col divide-y divide-white/5 rounded-xl">
          {[
            ["Завершено циклов", `${state.wallet.completed_cycles_total}`],
            ["Заработано всего", `${state.wallet.total_earned.toFixed(2)} GRAM`],
            ["Прибыль за 24ч", `${state.stats.profit_24h.toFixed(2)} GRAM`],
            ["Активных слотов", `${usedSlots} / ${state.wallet.slots_count}`],
          ].map(([label, value]) => (
            <div key={label} className="flex items-center justify-between p-3 text-sm">
              <span className="text-nav-inactive">{label}</span>
              <span className="text-profit font-semibold">{value}</span>
            </div>
          ))}
        </div>
      </div>

      <div className="gradient-surface rounded-2xl p-4">
        <p className="text-sm font-semibold">👥 Бонус за друзей</p>
        <p className="mt-1 text-xs text-nav-inactive">
          Зови друзей и получай долю их дохода.
        </p>
        <p className="mt-2 text-2xl font-bold text-gram">+10%</p>
        <p className="text-xs text-nav-inactive">от дохода 1-го уровня приглашённых</p>
      </div>

      <QuestList quests={state.quests} onStateChange={onStateChange} />
      <ComingSoonSection
        icon="📦"
        title="Контейнеры"
        description="Появятся в одном из следующих сезонов."
      />

      {historyOpen && <HistoryModal onClose={() => setHistoryOpen(false)} />}
    </div>
  );
}
