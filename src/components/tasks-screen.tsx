"use client";

import { useMemo, useState } from "react";
import { ClipboardList, Target, Star, Handshake, type LucideIcon } from "lucide-react";
import type { PlayerState } from "@/lib/types";
import { useLanguage } from "@/lib/i18n/context";
import { QuestList } from "./quest-list";
import { SystemTasksSection } from "./system-tasks-section";
import { PartnerTasksSection } from "./partner-tasks-section";

type Tab = "district" | "ambassadors" | "partners";

const TABS: {
  id: Tab;
  labelKey: "tasksScreen.tabDistrict" | "tasksScreen.tabAmbassadors" | "tasksScreen.tabPartners";
  Icon: LucideIcon;
}[] = [
  { id: "district", labelKey: "tasksScreen.tabDistrict", Icon: Target },
  { id: "ambassadors", labelKey: "tasksScreen.tabAmbassadors", Icon: Star },
  { id: "partners", labelKey: "tasksScreen.tabPartners", Icon: Handshake },
];

export function TasksScreen({
  state,
  onStateChange,
  onBack,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
  onBack: () => void;
}) {
  const { t } = useLanguage();
  const [tab, setTab] = useState<Tab>("district");

  const ambassadorTasks = useMemo(
    () => state.partner_tasks.filter((task) => task.kind === "ambassador"),
    [state.partner_tasks],
  );
  const partnerTasks = useMemo(
    () => state.partner_tasks.filter((task) => task.kind === "partner"),
    [state.partner_tasks],
  );

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="bg-header flex items-center gap-3 px-4 py-3">
        <button type="button" onClick={onBack} aria-label={t("common.back")} className="inline-block text-lg rtl:rotate-180">
          ←
        </button>
        <p className="flex items-center gap-1.5 font-semibold">
          <ClipboardList className="h-4 w-4 text-amber-400" />
          {t("tasksScreen.title")}
        </p>
      </header>

      <div className="flex gap-2 overflow-x-auto px-4 pt-3">
        {TABS.map(({ id, labelKey, Icon }) => (
          <button
            key={id}
            type="button"
            onClick={() => setTab(id)}
            className={`flex shrink-0 items-center gap-1.5 rounded-full px-4 py-2 text-xs font-semibold ${
              tab === id ? "gradient-action" : "gradient-surface text-nav-inactive"
            }`}
          >
            <Icon className="h-3.5 w-3.5" />
            {t(labelKey)}
          </button>
        ))}
      </div>

      <div className="flex flex-1 flex-col gap-5 overflow-y-auto p-4 pb-8">
        {tab === "district" && (
          <>
            <QuestList quests={state.quests} onStateChange={onStateChange} />
            <SystemTasksSection tasks={state.system_tasks} onStateChange={onStateChange} />
          </>
        )}
        {tab === "ambassadors" && (
          <PartnerTasksSection
            tasks={ambassadorTasks}
            onStateChange={onStateChange}
            title={t("tasksScreen.tabAmbassadors")}
            icon={Star}
            emptyText={t("tasksScreen.ambassadorsEmpty")}
          />
        )}
        {tab === "partners" && (
          <PartnerTasksSection
            tasks={partnerTasks}
            onStateChange={onStateChange}
            title={t("partnerTasks.title")}
            icon={Handshake}
            emptyText={t("tasksScreen.partnersEmpty")}
          />
        )}
      </div>
    </div>
  );
}
