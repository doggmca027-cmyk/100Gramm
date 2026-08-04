"use client";

import { useState } from "react";
import { PartnerTasksAdminSection } from "./admin/partner-tasks-admin-section";
import { AmbassadorsAdminSection } from "./admin/ambassadors-admin-section";
import { AmbassadorStatsScreen } from "./ambassador-stats-screen";

type Section = "tasks" | "ambassadors";

export function AdminScreen({ onBack }: { onBack: () => void }) {
  const [section, setSection] = useState<Section>("tasks");
  const [statsOpen, setStatsOpen] = useState(false);

  if (statsOpen) {
    return <AmbassadorStatsScreen onBack={() => setStatsOpen(false)} />;
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="bg-header flex items-center gap-3 px-4 py-3">
        <button type="button" onClick={onBack} aria-label="Назад" className="text-lg">
          ←
        </button>
        <p className="font-semibold">⚙️ Админ-панель</p>
      </header>

      <div className="flex gap-2 px-4 pt-3">
        <button
          type="button"
          onClick={() => setSection("tasks")}
          className={`flex-1 rounded-full py-2 text-xs font-semibold ${
            section === "tasks" ? "gradient-action" : "gradient-surface text-nav-inactive"
          }`}
        >
          🤝 Задачи
        </button>
        <button
          type="button"
          onClick={() => setSection("ambassadors")}
          className={`flex-1 rounded-full py-2 text-xs font-semibold ${
            section === "ambassadors" ? "gradient-action" : "gradient-surface text-nav-inactive"
          }`}
        >
          ⭐ Амбассадоры
        </button>
      </div>

      <div className="flex flex-1 flex-col gap-6 overflow-y-auto p-4 pb-8">
        {section === "tasks" && <PartnerTasksAdminSection />}
        {section === "ambassadors" && (
          <AmbassadorsAdminSection onOpenStats={() => setStatsOpen(true)} />
        )}
        {/* Дальнейшие разделы админки добавляются сюда. */}
      </div>
    </div>
  );
}
