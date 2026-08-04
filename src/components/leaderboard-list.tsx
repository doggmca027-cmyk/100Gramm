"use client";

import { useEffect, useState } from "react";
import { fetchLeaderboard, type LeaderboardEntry } from "@/lib/api-client";

export function LeaderboardList() {
  const [entries, setEntries] = useState<LeaderboardEntry[] | null>(null);

  useEffect(() => {
    fetchLeaderboard("total_earned")
      .then(setEntries)
      .catch(() => setEntries([]));
  }, []);

  return (
    <div className="flex flex-col gap-2">
      <h2 className="px-1 text-sm font-semibold text-nav-inactive">
        🏆 Рейтинг сезона
      </h2>
      <div className="gradient-surface flex flex-col divide-y divide-white/5 rounded-xl">
        {entries === null && (
          <p className="p-3 text-sm text-nav-inactive">Загрузка...</p>
        )}
        {entries?.length === 0 && (
          <p className="p-3 text-sm text-nav-inactive">Пока никого нет</p>
        )}
        {entries?.map((entry, index) => (
          <div
            key={`${entry.display_name}-${index}`}
            className="flex items-center justify-between p-3 text-sm"
          >
            <span>
              #{index + 1} {entry.display_name}
            </span>
            <span className="text-gram">{entry.total_earned.toFixed(2)} GRAM</span>
          </div>
        ))}
      </div>
    </div>
  );
}
