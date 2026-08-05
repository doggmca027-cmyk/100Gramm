"use client";

import { useEffect, useState } from "react";
import { fetchLeaderboard, type LeaderboardEntry } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";

export function LeaderboardScreen({ onBack }: { onBack: () => void }) {
  const { t } = useLanguage();
  const [entries, setEntries] = useState<LeaderboardEntry[] | null>(null);

  useEffect(() => {
    fetchLeaderboard("total_earned")
      .then(setEntries)
      .catch(() => setEntries([]));
  }, []);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="bg-header flex items-center gap-3 px-4 py-3">
        <button type="button" onClick={onBack} aria-label={t("common.back")} className="text-lg">
          ←
        </button>
        <p className="font-semibold">{t("leaderboard.title")}</p>
      </header>

      <div className="flex flex-1 flex-col gap-3 overflow-y-auto p-4 pb-8">
        <div className="gradient-surface flex flex-col divide-y divide-white/5 rounded-xl">
          {entries === null && (
            <p className="p-3 text-sm text-nav-inactive">{t("common.loading")}</p>
          )}
          {entries?.length === 0 && (
            <p className="p-3 text-sm text-nav-inactive">{t("leaderboard.empty")}</p>
          )}
          {entries?.map((entry, index) => (
            <div
              key={`${entry.display_name}-${index}`}
              className="flex items-center justify-between p-3 text-sm"
            >
              <span>
                #{index + 1} {entry.display_name}
              </span>
              <span className="text-gram">
                {entry.total_earned.toFixed(2)} {t("common.gram")}
              </span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
