"use client";

import { useState } from "react";
import {
  searchAdminUsers,
  setUserAmbassador,
  type AdminUser,
} from "@/lib/api-client";

export function AmbassadorsAdminSection({ onOpenStats }: { onOpenStats: () => void }) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<AdminUser[] | null>(null);
  const [searching, setSearching] = useState(false);
  const [pendingId, setPendingId] = useState<string | null>(null);

  async function handleSearch(e: React.FormEvent) {
    e.preventDefault();
    if (!query.trim()) return;
    setSearching(true);
    try {
      const data = await searchAdminUsers(query.trim());
      setResults(data);
    } catch {
      setResults([]);
    } finally {
      setSearching(false);
    }
  }

  async function handleToggle(user: AdminUser) {
    setPendingId(user.id);
    try {
      await setUserAmbassador(user.id, !user.is_ambassador);
      setResults(
        (prev) =>
          prev?.map((u) =>
            u.id === user.id ? { ...u, is_ambassador: !u.is_ambassador } : u,
          ) ?? null,
      );
    } finally {
      setPendingId(null);
    }
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between px-1">
        <h2 className="text-sm font-semibold text-nav-inactive">⭐ Амбассадоры</h2>
        <button
          type="button"
          onClick={onOpenStats}
          className="text-xs font-semibold text-gram"
        >
          📊 Статистика →
        </button>
      </div>

      <form onSubmit={handleSearch} className="flex gap-2">
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Username или Telegram ID"
          className="flex-1 rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
        />
        <button
          type="submit"
          disabled={searching}
          className="gradient-action shrink-0 rounded-full px-4 py-2 text-sm font-semibold disabled:opacity-50"
        >
          Найти
        </button>
      </form>

      <div className="flex flex-col gap-2">
        {results === null && (
          <p className="text-sm text-nav-inactive">Введи username или Telegram ID игрока.</p>
        )}
        {results?.length === 0 && (
          <p className="text-sm text-nav-inactive">Никого не нашлось.</p>
        )}
        {results?.map((user) => (
          <div
            key={user.id}
            className="gradient-surface flex items-center justify-between rounded-xl p-3"
          >
            <div>
              <p className="text-sm font-semibold">
                {user.username ? `@${user.username}` : user.first_name ?? "Без имени"}
              </p>
              <p className="text-xs text-nav-inactive">ID: {user.telegram_id}</p>
            </div>
            <button
              type="button"
              onClick={() => handleToggle(user)}
              disabled={pendingId === user.id}
              className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-semibold disabled:opacity-50 ${
                user.is_ambassador
                  ? "bg-progress-bg text-profit"
                  : "gradient-action"
              }`}
            >
              {user.is_ambassador ? "⭐ Амбассадор" : "Сделать амбассадором"}
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}
