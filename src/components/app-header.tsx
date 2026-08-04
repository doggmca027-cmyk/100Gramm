"use client";

import { useState } from "react";
import { useCountdown, formatDuration } from "@/hooks/use-countdown";
import type { PlayerState } from "@/lib/types";
import { isAdminTelegramId } from "@/lib/admin";
import { LeaderboardModal } from "./leaderboard-modal";
import { AdminPanelModal } from "./admin-panel-modal";

export function AppHeader({ state }: { state: PlayerState }) {
  const secondsLeft = useCountdown(state.season.ends_at);
  const daysLeft = Math.floor(secondsLeft / 86400);
  const [leaderboardOpen, setLeaderboardOpen] = useState(false);
  const [adminOpen, setAdminOpen] = useState(false);
  const isAdmin = isAdminTelegramId(state.squad.invite_code);

  return (
    <>
      <header className="bg-header flex items-center justify-between px-4 py-3">
        <div>
          <p className="text-lg font-bold">100ГРАМ</p>
          <p className="text-xs text-nav-inactive">
            {state.rank?.icon} {state.rank?.name ?? "Бомж"}
          </p>
        </div>
        <div className="flex items-center gap-3">
          <div className="text-right">
            <p className="gradient-gram bg-clip-text text-lg font-bold text-transparent">
              {state.wallet.balance.toFixed(2)} GRAM
            </p>
            <p className="text-xs text-nav-inactive">
              Сезон: {daysLeft > 0 ? `${daysLeft} дн.` : formatDuration(secondsLeft)}
            </p>
          </div>
          {isAdmin && (
            <button
              type="button"
              onClick={() => setAdminOpen(true)}
              className="gradient-surface flex h-9 w-9 items-center justify-center rounded-full text-lg"
              aria-label="Управление"
            >
              ⚙️
            </button>
          )}
          <button
            type="button"
            onClick={() => setLeaderboardOpen(true)}
            className="gradient-surface flex h-9 w-9 items-center justify-center rounded-full text-lg"
            aria-label="Рейтинг сезона"
          >
            🏆
          </button>
        </div>
      </header>

      {leaderboardOpen && (
        <LeaderboardModal onClose={() => setLeaderboardOpen(false)} />
      )}
      {adminOpen && <AdminPanelModal onClose={() => setAdminOpen(false)} />}
    </>
  );
}
