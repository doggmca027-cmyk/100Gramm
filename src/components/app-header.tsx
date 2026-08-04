"use client";

import { useCountdown, formatDuration } from "@/hooks/use-countdown";
import type { PlayerState } from "@/lib/types";

export function AppHeader({ state }: { state: PlayerState }) {
  const secondsLeft = useCountdown(state.season.ends_at);
  const daysLeft = Math.floor(secondsLeft / 86400);

  return (
    <header className="bg-header flex items-center justify-between px-4 py-3">
      <div>
        <p className="text-lg font-bold">100ГРАМ</p>
        <p className="text-xs text-nav-inactive">
          {state.rank?.icon} {state.rank?.name ?? "Бомж"}
        </p>
      </div>
      <div className="text-right">
        <p className="gradient-gram bg-clip-text text-lg font-bold text-transparent">
          {state.wallet.balance.toFixed(2)} GRAM
        </p>
        <p className="text-xs text-nav-inactive">
          Сезон: {daysLeft > 0 ? `${daysLeft} дн.` : formatDuration(secondsLeft)}
        </p>
      </div>
    </header>
  );
}
