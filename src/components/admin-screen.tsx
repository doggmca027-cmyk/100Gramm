"use client";

import { PartnerTasksAdminSection } from "./admin/partner-tasks-admin-section";

export function AdminScreen({ onBack }: { onBack: () => void }) {
  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="bg-header flex items-center gap-3 px-4 py-3">
        <button type="button" onClick={onBack} aria-label="Назад" className="text-lg">
          ←
        </button>
        <p className="font-semibold">⚙️ Админ-панель</p>
      </header>

      <div className="flex flex-1 flex-col gap-6 overflow-y-auto p-4 pb-8">
        <PartnerTasksAdminSection />
        {/* Дальнейшие разделы админки (сезоны, игроки и т.д.) добавляются сюда. */}
      </div>
    </div>
  );
}
