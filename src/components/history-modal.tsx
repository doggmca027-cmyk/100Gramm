"use client";

import { useEffect, useState } from "react";
import { fetchHistory } from "@/lib/api-client";
import type { HistoryEntry } from "@/lib/types";

function formatDate(iso: string): string {
  return new Date(iso).toLocaleString("ru-RU", {
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function HistoryModal({ onClose }: { onClose: () => void }) {
  const [entries, setEntries] = useState<HistoryEntry[] | null>(null);

  useEffect(() => {
    fetchHistory()
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
          <h2 className="text-base font-semibold">📜 История</h2>
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
            <p className="p-3 text-sm text-nav-inactive">Пока пусто</p>
          )}
          {entries?.map((entry, i) => (
            <div key={i} className="flex items-center justify-between p-3 text-sm">
              <div>
                <p>{entry.type === "cycle" ? `Товар ${entry.tier}` : `Рефералка ур.${entry.tier}`}</p>
                <p className="text-xs text-nav-inactive">{formatDate(entry.created_at)}</p>
              </div>
              <span className="text-profit">+{entry.amount.toFixed(2)} GRAM</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
