"use client";

import { useState } from "react";
import Image from "next/image";
import type { PlayerState } from "@/lib/types";
import { SQUAD_BANNER_IMAGE } from "@/lib/tier-art";
import { useLanguage } from "@/lib/i18n/context";

// Standard vs ambassador referral rates — must match start_cycle() in
// 0010_referral_on_start_and_ambassador_rates.sql exactly; these are
// display-only, the actual payout always comes from the database.
const REFERRAL_RATES = {
  standard: [10, 5, 2],
  ambassador: [15, 9, 5],
} as const;

export function SquadScreen({ state }: { state: PlayerState }) {
  const { t } = useLanguage();
  const [copied, setCopied] = useState(false);
  const botUsername = process.env.NEXT_PUBLIC_BOT_USERNAME;
  const inviteLink = botUsername
    ? `https://t.me/${botUsername}?startapp=${state.squad.invite_code}`
    : null;
  const isAmbassador = state.squad.is_ambassador;
  const [rate1, rate2, rate3] = isAmbassador ? REFERRAL_RATES.ambassador : REFERRAL_RATES.standard;

  async function handleCopy() {
    if (!inviteLink) return;
    await navigator.clipboard.writeText(inviteLink);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4 pb-24">
      <div className="relative overflow-hidden rounded-2xl">
        <Image
          src={SQUAD_BANNER_IMAGE}
          alt=""
          width={800}
          height={450}
          className="h-40 w-full object-cover"
        />
        <div className="absolute inset-0 flex flex-col justify-end bg-gradient-to-t from-black/90 via-black/30 to-transparent p-4">
          <p className="text-xs text-nav-inactive">{t("squad.title")}</p>
          <p className="text-2xl font-bold">{state.squad.referred_count}</p>
        </div>
      </div>

      <div className="gradient-surface rounded-2xl p-5 text-center">
        <p className="text-xs text-nav-inactive">{t("squad.teamIncome")}</p>
        <p className="gradient-gram bg-clip-text text-2xl font-bold text-transparent">
          {state.squad.earned_total.toFixed(2)} {t("common.gram")}
        </p>
      </div>

      <div className="gradient-surface rounded-2xl p-4 text-sm leading-relaxed">
        <p>{t("squad.description")}</p>
        {isAmbassador && (
          <p className="mt-2 text-xs font-semibold text-gram">{t("squad.ambassadorBadge")}</p>
        )}
        <ul className="mt-3 space-y-1 text-xs text-nav-inactive">
          <li>{t("squad.level1", { percent: rate1 })}</li>
          <li>{t("squad.level2", { percent: rate2 })}</li>
          <li>{t("squad.level3", { percent: rate3 })}</li>
        </ul>
      </div>

      <button
        type="button"
        onClick={handleCopy}
        disabled={!inviteLink}
        className="gradient-action rounded-full py-3 text-sm font-semibold disabled:opacity-40"
      >
        {copied ? t("squad.copied") : t("squad.invite")}
      </button>
    </div>
  );
}
