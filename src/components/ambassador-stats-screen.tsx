"use client";

import { useEffect, useState } from "react";
import { fetchAmbassadorStats, type AmbassadorStats } from "@/lib/api-client";

const LEVEL_LABEL: Record<number, string> = {
  1: "🥇 Уровень 1",
  2: "🥈 Уровень 2",
  3: "🥉 Уровень 3",
};

export function AmbassadorStatsScreen({ onBack }: { onBack: () => void }) {
  const [stats, setStats] = useState<AmbassadorStats[] | null>(null);

  useEffect(() => {
    fetchAmbassadorStats()
      .then(setStats)
      .catch(() => setStats([]));
  }, []);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="bg-header flex items-center gap-3 px-4 py-3">
        <button type="button" onClick={onBack} aria-label="Назад" className="text-lg">
          ←
        </button>
        <p className="font-semibold">📊 Статистика амбассадоров</p>
      </header>

      <div className="flex flex-1 flex-col gap-3 overflow-y-auto p-4 pb-8">
        {stats === null && <p className="text-sm text-nav-inactive">Загрузка...</p>}
        {stats?.length === 0 && (
          <p className="text-sm text-nav-inactive">
            Пока нет отмеченных амбассадоров — отметь кого-нибудь на экране «Амбассадоры».
          </p>
        )}

        {stats?.map((a) => (
          <div key={a.id} className="gradient-surface flex flex-col gap-2 rounded-2xl p-4">
            <div>
              <p className="font-semibold">
                {a.username ? `@${a.username}` : a.first_name ?? "Без имени"}
              </p>
              <p className="text-xs text-nav-inactive">ID: {a.telegram_id}</p>
            </div>
            <div className="flex flex-col divide-y divide-white/5 rounded-xl bg-progress-bg">
              {a.levels.map((l) => (
                <div key={l.level} className="flex items-center justify-between p-3 text-sm">
                  <span className="text-nav-inactive">{LEVEL_LABEL[l.level] ?? `Уровень ${l.level}`}</span>
                  <span>
                    {l.referred_count} чел. ·{" "}
                    <span className="text-gram">{l.total_deposited.toFixed(2)} GRAM</span>
                  </span>
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
