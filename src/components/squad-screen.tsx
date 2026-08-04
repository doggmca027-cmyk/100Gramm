"use client";

import { useState } from "react";
import type { PlayerState } from "@/lib/types";

export function SquadScreen({ state }: { state: PlayerState }) {
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
      <div className="gradient-surface rounded-2xl p-5 text-center">
        <p className="text-sm text-nav-inactive">👥 Банда</p>
        <p className="text-3xl font-bold">{state.squad.referred_count}</p>
        <p className="mt-1 text-xs text-nav-inactive">
          Доход с команды:{" "}
          <span className="text-gram">{state.squad.earned_total.toFixed(2)} GRAM</span>
        </p>
      </div>

      <div className="gradient-surface rounded-2xl p-4 text-sm leading-relaxed">
        <p>
          В этом мире одному выжить сложно. Приглашай друзей — получай долю
          GRAM с каждого их запущенного цикла.
        </p>
        <ul className="mt-3 space-y-1 text-xs text-nav-inactive">
          <li>🥇 Уровень 1 (напарники) — 10%</li>
          <li>🥈 Уровень 2 — 5%</li>
          <li>🥉 Уровень 3 — 2%</li>
        </ul>
      </div>

      <button
        type="button"
        onClick={handleCopy}
        disabled={!inviteLink}
        className="gradient-action rounded-full py-3 text-sm font-semibold disabled:opacity-40"
      >
        {copied ? "Скопировано!" : "🍾 Позвать в команду"}
      </button>
    </div>
  );
}
