"use client";

import { useState } from "react";
import { openTelegramLink } from "@telegram-apps/sdk-react";
import { useCountdown, formatDuration } from "@/hooks/use-countdown";
import type { PlayerState } from "@/lib/types";
import { isAdminTelegramId } from "@/lib/admin";
import { useLanguage } from "@/lib/i18n/context";
import { LeaderboardModal } from "./leaderboard-modal";
import { LanguageSwitcher } from "./language-switcher";

const SUPPORT_BOT_URL = "https://t.me/GrammSupportBot";

export function AppHeader({
  state,
  onOpenAdmin,
}: {
  state: PlayerState;
  onOpenAdmin: () => void;
}) {
  const { t, pick } = useLanguage();
  const secondsLeft = useCountdown(state.season.ends_at);
  const daysLeft = Math.floor(secondsLeft / 86400);
  const [leaderboardOpen, setLeaderboardOpen] = useState(false);
  const isAdmin = isAdminTelegramId(state.squad.invite_code);

  function handleSupport() {
    if (openTelegramLink.isAvailable()) {
      openTelegramLink(SUPPORT_BOT_URL);
    } else {
      window.open(SUPPORT_BOT_URL, "_blank");
    }
  }

  return (
    <>
      <header className="bg-header flex items-center justify-between px-4 py-3">
        <div>
          <p className="text-lg font-bold">100ГРАМ</p>
          <p className="text-xs text-nav-inactive">
            {state.rank?.icon} {pick(state.rank?.name_i18n) || t("header.rankFallback")}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={handleSupport}
            className="gradient-surface flex h-9 w-9 items-center justify-center rounded-full text-lg"
            aria-label={t("header.support")}
          >
            🛟
          </button>
          <LanguageSwitcher />
          {isAdmin && (
            <button
              type="button"
              onClick={onOpenAdmin}
              className="gradient-surface flex h-9 w-9 items-center justify-center rounded-full text-lg"
              aria-label={t("header.admin")}
            >
              ⚙️
            </button>
          )}
          <button
            type="button"
            onClick={() => setLeaderboardOpen(true)}
            className="gradient-surface flex h-9 w-9 items-center justify-center rounded-full text-lg"
            aria-label={t("header.leaderboard")}
          >
            🏆
          </button>
          <div className="text-right">
            <p className="gradient-gram bg-clip-text text-lg font-bold text-transparent">
              {state.wallet.balance.toFixed(2)} {t("common.gram")}
            </p>
            <p className="text-xs text-nav-inactive">
              {t("header.season")}: {daysLeft > 0 ? `${daysLeft} d` : formatDuration(secondsLeft)}
            </p>
          </div>
        </div>
      </header>

      {leaderboardOpen && (
        <LeaderboardModal onClose={() => setLeaderboardOpen(false)} />
      )}
    </>
  );
}
