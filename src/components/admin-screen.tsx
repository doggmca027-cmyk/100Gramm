"use client";

import { useState } from "react";
import { Settings, Handshake, Star, Newspaper, Sparkles, Banknote, UserRound, type LucideIcon } from "lucide-react";
import type { PlayerState } from "@/lib/types";
import { PartnerTasksAdminSection } from "./admin/partner-tasks-admin-section";
import { PartnerAppsAdminSection } from "./admin/partner-apps-admin-section";
import { AmbassadorsAdminSection } from "./admin/ambassadors-admin-section";
import { NewsAdminSection } from "./admin/news-admin-section";
import { DailyComboAdminSection } from "./admin/daily-combo-admin-section";
import { WithdrawalsAdminSection } from "./admin/withdrawals-admin-section";
import { LeaderboardVisibilityAdminSection } from "./admin/leaderboard-visibility-admin-section";
import { AmbassadorStatsScreen } from "./ambassador-stats-screen";

type Section = "tasks" | "ambassadors" | "news" | "combo" | "withdrawals" | "profile";

const SECTION_TABS: { id: Section; label: string; Icon: LucideIcon }[] = [
  { id: "tasks", label: "Задачи", Icon: Handshake },
  { id: "ambassadors", label: "Амбассадоры", Icon: Star },
  { id: "news", label: "Новости", Icon: Newspaper },
  { id: "combo", label: "Combo", Icon: Sparkles },
  { id: "withdrawals", label: "Выводы", Icon: Banknote },
  { id: "profile", label: "Профиль", Icon: UserRound },
];

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
        <p className="flex items-center gap-1.5 font-semibold">
          <Settings className="h-4 w-4 text-neutral-400" />
          Админ-панель
        </p>
      </header>

      <div className="flex gap-2 overflow-x-auto px-4 pt-3">
        {SECTION_TABS.map(({ id, label, Icon }) => (
          <button
            key={id}
            type="button"
            onClick={() => setSection(id)}
            className={`flex shrink-0 items-center gap-1.5 rounded-full px-4 py-2 text-xs font-semibold ${
              section === id ? "gradient-action" : "gradient-surface text-nav-inactive"
            }`}
          >
            <Icon className="h-3.5 w-3.5" />
            {label}
          </button>
        ))}
      </div>

      <div className="flex flex-1 flex-col gap-6 overflow-y-auto p-4 pb-8">
        {section === "tasks" && (
          <>
            <PartnerAppsAdminSection />
            <PartnerTasksAdminSection />
          </>
        )}
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
