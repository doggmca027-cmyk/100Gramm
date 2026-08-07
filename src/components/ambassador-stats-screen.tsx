"use client";

import { useEffect, useState } from "react";
import { BarChart3, Medal } from "lucide-react";
import { fetchAmbassadorStats, type AmbassadorStats } from "@/lib/api-client";

function formatDisplayName(username: string | null, firstName: string | null) {
  const safeName = [firstName, username].find((value) => typeof value === "string" && value.trim().length > 0);
  if (!safeName) return "Без имени";

  const normalized = safeName.trim();
  return normalized.startsWith("@") ? normalized : `@${normalized}`;
}

function maskTelegramId(value: number | null | undefined) {
  if (value == null) return "—";
  const text = String(value);
  if (text.length <= 4) return text;
  return `***${text.slice(-2)}`;
}

const LEVEL_LABEL: Record<number, string> = {
  1: "Уровень 1",
  2: "Уровень 2",
  3: "Уровень 3",
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
        <button type="button" onClick={onBack} aria-label="Назад" className="inline-block text-lg rtl:rotate-180">
          ←
        </button>
        <p className="flex items-center gap-1.5 font-semibold">
          <BarChart3 className="h-4 w-4 text-purple-400" />
          Статистика амбассадоров
        </p>
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
                {formatDisplayName(a.username ?? null, a.first_name ?? null)}
              </p>
              <p className="text-xs text-nav-inactive">ID: {maskTelegramId(a.telegram_id)}</p>
            </div>
            <div className="flex flex-col divide-y divide-white/5 rounded-xl bg-progress-bg">
              {a.levels.map((l) => (
                <div key={l.level} className="flex items-center justify-between p-3 text-sm">
                  <span className="flex items-center gap-1.5 text-nav-inactive">
                    <Medal className="h-3.5 w-3.5 shrink-0 text-amber-400" />
                    {LEVEL_LABEL[l.level] ?? `Уровень ${l.level}`}
                  </span>
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
