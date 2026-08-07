"use client";

import { useState } from "react";
import type { PlayerState } from "@/lib/types";
import { PartnerTasksAdminSection } from "./admin/partner-tasks-admin-section";
import { AmbassadorsAdminSection } from "./admin/ambassadors-admin-section";
import { NewsAdminSection } from "./admin/news-admin-section";
import { DailyComboAdminSection } from "./admin/daily-combo-admin-section";
import { WithdrawalsAdminSection } from "./admin/withdrawals-admin-section";
import { LeaderboardVisibilityAdminSection } from "./admin/leaderboard-visibility-admin-section";
import { AmbassadorStatsScreen } from "./ambassador-stats-screen";

type Section = "tasks" | "ambassadors" | "news" | "combo" | "withdrawals" | "profile";

export function AdminScreen({
  state,
  onStateChange,
  onBack,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
  onBack: () => void;
}) {
  const [section, setSection] = useState<Section>("tasks");
  const [statsOpen, setStatsOpen] = useState(false);

  if (statsOpen) {
    return <AmbassadorStatsScreen onBack={() => setStatsOpen(false)} />;
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="bg-header flex items-center gap-3 px-4 py-3">
        <button type="button" onClick={onBack} aria-label="Назад" className="inline-block text-lg rtl:rotate-180">
          ←
        </button>
        <p className="font-semibold">⚙️ Админ-панель</p>
      </header>

      <div className="flex gap-2 overflow-x-auto px-4 pt-3">
        <button
          type="button"
          onClick={() => setSection("tasks")}
          className={`shrink-0 rounded-full px-4 py-2 text-xs font-semibold ${
            section === "tasks" ? "gradient-action" : "gradient-surface text-nav-inactive"
          }`}
        >
          🤝 Задачи
        </button>
        <button
          type="button"
          onClick={() => setSection("ambassadors")}
          className={`shrink-0 rounded-full px-4 py-2 text-xs font-semibold ${
            section === "ambassadors" ? "gradient-action" : "gradient-surface text-nav-inactive"
          }`}
        >
          ⭐ Амбассадоры
        </button>
        <button
          type="button"
          onClick={() => setSection("news")}
          className={`shrink-0 rounded-full px-4 py-2 text-xs font-semibold ${
            section === "news" ? "gradient-action" : "gradient-surface text-nav-inactive"
          }`}
        >
          📰 Новости
        </button>
        <button
          type="button"
          onClick={() => setSection("combo")}
          className={`shrink-0 rounded-full px-4 py-2 text-xs font-semibold ${
            section === "combo" ? "gradient-action" : "gradient-surface text-nav-inactive"
          }`}
        >
          🎴 Combo
        </button>
        <button
          type="button"
          onClick={() => setSection("withdrawals")}
          className={`shrink-0 rounded-full px-4 py-2 text-xs font-semibold ${
            section === "withdrawals" ? "gradient-action" : "gradient-surface text-nav-inactive"
          }`}
        >
          💸 Выводы
        </button>
        <button
          type="button"
          onClick={() => setSection("profile")}
          className={`shrink-0 rounded-full px-4 py-2 text-xs font-semibold ${
            section === "profile" ? "gradient-action" : "gradient-surface text-nav-inactive"
          }`}
        >
          👤 Профиль
        </button>
      </div>

      <div className="flex flex-1 flex-col gap-6 overflow-y-auto p-4 pb-8">
        {section === "tasks" && <PartnerTasksAdminSection />}
        {section === "ambassadors" && (
          <AmbassadorsAdminSection onOpenStats={() => setStatsOpen(true)} />
        )}
        {section === "news" && <NewsAdminSection />}
        {section === "combo" && <DailyComboAdminSection />}
        {section === "withdrawals" && <WithdrawalsAdminSection />}
        {section === "profile" && (
          <LeaderboardVisibilityAdminSection state={state} onStateChange={onStateChange} />
        )}
        {/* Дальнейшие разделы админки добавляются сюда. */}
      </div>
    </div>
  );
}
