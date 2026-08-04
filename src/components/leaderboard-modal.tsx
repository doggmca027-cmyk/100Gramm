"use client";

import { useEffect, useState } from "react";
import { fetchLeaderboard, type LeaderboardEntry } from "@/lib/api-client";

export function LeaderboardModal({ onClose }: { onClose: () => void }) {
  const [entries, setEntries] = useState<LeaderboardEntry[] | null>(null);

  useEffect(() => {
    fetchLeaderboard("total_earned")
      .then(setEntries)
      .catch(() => setEntries([]));
  }, []);

  return (
    <div
      className="fixed inset-0 z-50 flex flex-col justify-end bg-black/60"
      onClick={onClose}
    >
      <div
        className="bg-nav flex max-h-[80vh] flex-col gap-3 rounded-t-2xl p-4"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between">
          <h2 className="text-base font-semibold">🏆 Рейтинг сезона</h2>
          <button
            type="button"
            onClick={onClose}
            className="text-nav-inactive"
            aria-label="Закрыть"
          >
            ✕
          </button>
        </div>
        <div className="gradient-surface flex flex-col divide-y divide-white/5 overflow-y-auto rounded-xl">
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
    </div>
  );
}
