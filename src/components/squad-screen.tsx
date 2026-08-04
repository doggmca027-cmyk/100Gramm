"use client";

import { useState } from "react";
import Image from "next/image";
import type { PlayerState } from "@/lib/types";
import { SQUAD_BANNER_IMAGE } from "@/lib/tier-art";
import { useLanguage } from "@/lib/i18n/context";

export function SquadScreen({ state }: { state: PlayerState }) {
  const { t } = useLanguage();
  const [copied, setCopied] = useState(false);
  const botUsername = process.env.NEXT_PUBLIC_BOT_USERNAME;
  const inviteLink = botUsername
    ? `https://t.me/${botUsername}?startapp=${state.squad.invite_code}`
    : null;

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
        <ul className="mt-3 space-y-1 text-xs text-nav-inactive">
          <li>{t("squad.level1")}</li>
          <li>{t("squad.level2")}</li>
          <li>{t("squad.level3")}</li>
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
