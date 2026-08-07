"use client";

import { useState } from "react";
import { Trophy } from "lucide-react";
import type { PlayerState } from "@/lib/types";
import { setLeaderboardVisibility } from "@/lib/api-client";

/** Self-toggle: hide/unhide *your own* profile from the leaderboard. */
export function LeaderboardVisibilityAdminSection({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const [submitting, setSubmitting] = useState(false);
  const hidden = state.profile.hide_from_leaderboard;

  async function handleToggle() {
    setSubmitting(true);
    try {
      const { state: newState } = await setLeaderboardVisibility(!hidden);
      onStateChange(newState);
    } catch {
      // transient — button just re-enables, current state stays shown
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="flex flex-col gap-2">
      <h2 className="flex items-center gap-1.5 px-1 text-sm font-semibold text-nav-inactive">
        <Trophy className="h-4 w-4 text-amber-400" />
        Лидерборд
      </h2>
      <div className="gradient-surface flex items-center justify-between gap-3 rounded-xl p-3">
        <div>
          <p className="text-sm font-semibold">Скрыть мой профиль</p>
          <p className="text-xs text-nav-inactive">
            {hidden
              ? "Сейчас твой профиль не показывается в общем рейтинге"
              : "Сейчас твой профиль виден всем в общем рейтинге"}
          </p>
        </div>
        <button
          type="button"
          onClick={handleToggle}
          disabled={submitting}
          className={`shrink-0 rounded-full px-4 py-2 text-xs font-semibold disabled:opacity-50 ${
            hidden ? "gradient-action" : "bg-progress-bg text-danger"
          }`}
        >
          {hidden ? "Показать" : "Скрыть"}
        </button>
      </div>
    </div>
  );
}
