"use client";

import type { PlayerState } from "@/lib/types";
import { useLanguage } from "@/lib/i18n/context";
import { ProfileAvatar } from "./profile-avatar";

export function PlayerProfileCard({ state }: { state: PlayerState }) {
  const { t, pick } = useLanguage();
  const rank = state.rank;
  const earned = state.wallet.total_earned;
  const floor = rank?.min_earned ?? 0;
  const ceiling = rank?.next_min_earned;
  const progressPercent =
    ceiling != null && ceiling > floor
      ? Math.min(100, ((earned - floor) / (ceiling - floor)) * 100)
      : 100;

  return (
    <div className="gradient-surface flex items-center justify-between gap-3 rounded-2xl p-4">
      <div className="flex items-center gap-3">
        <ProfileAvatar
          photoUrl={state.profile.photo_url}
          rankIcon={rank?.icon ?? null}
          rankLevel={rank?.level}
        />
        <div>
          <p className="font-semibold">{pick(rank?.name_i18n) || t("header.rankFallback")}</p>
          <p className="text-xs text-nav-inactive">
            {t("profileCard.level")} {rank?.level ?? 1}
          </p>
          <div className="mt-1.5 h-1.5 w-28 rounded-full bg-progress-bg">
            <div
              className="h-1.5 rounded-full bg-progress-fill"
              style={{ width: `${progressPercent}%` }}
            />
          </div>
          <p className="mt-0.5 text-[10px] text-nav-inactive">
            {earned.toFixed(0)} / {ceiling != null ? ceiling.toFixed(0) : t("profileCard.max")}
          </p>
        </div>
      </div>
      <div className="text-right">
        <p className="text-xs text-nav-inactive">{t("profileCard.balance")}</p>
        <p className="gradient-gram bg-clip-text text-xl font-bold text-transparent">
          {state.wallet.balance.toFixed(2)}
        </p>
        <p className="text-[10px] text-nav-inactive">{t("common.gram")}</p>
      </div>
    </div>
  );
}
