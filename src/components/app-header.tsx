"use client";

import type { ReactNode } from "react";
import { Settings, Trophy, LifeBuoy } from "lucide-react";
import { openTelegramLink } from "@telegram-apps/sdk-react";
import { useCountdown, formatDuration } from "@/hooks/use-countdown";
import type { PlayerState } from "@/lib/types";
import { isAdminTelegramId } from "@/lib/admin";
import { useLanguage } from "@/lib/i18n/context";
import { LanguageSwitcher } from "./language-switcher";

const SUPPORT_BOT_URL = "https://t.me/GrammSupportBot";

/** Muted "Web3 panel" icon button — ambient purple glow at rest, brightens to amber on hover/press. */
function HeaderIconButton({
  onClick,
  label,
  children,
}: {
  onClick: () => void;
  label: string;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={label}
      className="flex h-9 w-9 items-center justify-center rounded-full border border-purple-900/30 bg-neutral-900/60 text-neutral-400 shadow-[0_0_10px_-4px_rgba(168,85,247,0.5)] transition-colors hover:border-amber-500/30 hover:text-amber-400"
    >
      {children}
    </button>
  );
}

export function AppHeader({
  state,
  onOpenAdmin,
  onOpenLeaderboard,
}: {
  state: PlayerState;
  onOpenAdmin: () => void;
  onOpenLeaderboard: () => void;
}) {
  const { t, pick } = useLanguage();
  const secondsLeft = useCountdown(state.season.ends_at);
  const daysLeft = Math.floor(secondsLeft / 86400);
  const isAdmin = isAdminTelegramId(state.squad.invite_code);

  function handleSupport() {
    if (openTelegramLink.isAvailable()) {
      openTelegramLink(SUPPORT_BOT_URL);
    } else {
      window.open(SUPPORT_BOT_URL, "_blank");
    }
  }

  return (
    <header className="bg-header flex items-center justify-between px-4 py-3">
      <div>
        <p className="text-lg font-bold">100ГРАМ</p>
        <span className="mt-1 inline-flex items-center gap-1 rounded-full border border-amber-500/20 bg-amber-500/10 px-2 py-0.5 text-xs font-semibold text-amber-400">
          {state.rank?.icon} {pick(state.rank?.name_i18n) || t("header.rankFallback")}
        </span>
      </div>
      <div className="flex items-center gap-2">
        <HeaderIconButton onClick={handleSupport} label={t("header.support")}>
          <LifeBuoy size={18} />
        </HeaderIconButton>
        <LanguageSwitcher />
        {isAdmin && (
          <HeaderIconButton onClick={onOpenAdmin} label={t("header.admin")}>
            <Settings size={18} />
          </HeaderIconButton>
        )}
        <HeaderIconButton onClick={onOpenLeaderboard} label={t("header.leaderboard")}>
          <Trophy size={18} />
        </HeaderIconButton>
        <div className="text-right rtl:text-left">
          <p className="gradient-gram bg-clip-text text-lg font-bold text-transparent">
            {state.wallet.balance.toFixed(2)} {t("common.gram")}
          </p>
          <p className="text-xs text-nav-inactive">
            {t("header.season")}: {daysLeft > 0 ? `${daysLeft} d` : formatDuration(secondsLeft)}
          </p>
        </div>
      </div>
    </header>
  );
}
