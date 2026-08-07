"use client";

import { useEffect, useState } from "react";
import { Users, Star, Medal, UserPlus } from "lucide-react";
import type { PlayerState, SquadLevel } from "@/lib/types";
import { useLanguage } from "@/lib/i18n/context";
import { REFERRAL_RATES } from "@/lib/referral-rates";
import { fetchSquadLevels } from "@/lib/api-client";
import { formatGramAmount } from "@/lib/format-gram";

/** Telegram photo if we have one and it loads; otherwise the name's first letter. Mirrors leaderboard-screen's avatar. */
function MemberAvatar({ name, photoUrl }: { name: string; photoUrl: string | null }) {
  const [failed, setFailed] = useState(false);
  const showPhoto = photoUrl && !failed;

  return (
    <div className="h-10 w-10 shrink-0 overflow-hidden rounded-full bg-progress-bg">
      {showPhoto ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={photoUrl}
          alt=""
          className="h-full w-full object-cover"
          onError={() => setFailed(true)}
        />
      ) : (
        <div className="gradient-action flex h-full w-full items-center justify-center text-sm font-bold">
          {name.charAt(0).toUpperCase()}
        </div>
      )}
    </div>
  );
}

export function SquadScreen({ state }: { state: PlayerState }) {
  const { t } = useLanguage();
  const [copied, setCopied] = useState(false);
  const botUsername = process.env.NEXT_PUBLIC_BOT_USERNAME;
  const inviteLink = botUsername
    ? `https://t.me/${botUsername}?startapp=${state.squad.invite_code}`
    : null;
  const isAmbassador = state.squad.is_ambassador;
  const [rate1, rate2, rate3] = isAmbassador ? REFERRAL_RATES.ambassador : REFERRAL_RATES.standard;

  const [levels, setLevels] = useState<SquadLevel[] | null>(null);
  const [levelsError, setLevelsError] = useState(false);
  const [selectedLevel, setSelectedLevel] = useState(1);

  function loadLevels() {
    fetchSquadLevels()
      .then(setLevels)
      .catch(() => setLevelsError(true));
  }

  useEffect(() => {
    loadLevels();
  }, []);

  function retryLevels() {
    setLevelsError(false);
    setLevels(null);
    loadLevels();
  }

  async function handleCopy() {
    if (!inviteLink) return;
    await navigator.clipboard.writeText(inviteLink);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  const active = levels?.find((l) => l.level === selectedLevel) ?? null;

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4 pb-24">
      <div className="gradient-surface rounded-2xl p-5 text-center">
        <p className="flex items-center justify-center gap-1 text-xs text-nav-inactive">
          <Users className="h-3.5 w-3.5 text-purple-400" />
          {t("squad.teamIncome")}
        </p>
        <p className="gradient-gram bg-clip-text text-2xl font-bold text-transparent">
          {state.squad.earned_total.toFixed(2)} {t("common.gram")}
        </p>
      </div>

      <div className="gradient-surface rounded-2xl p-4 text-sm leading-relaxed">
        <p>{t("squad.description")}</p>
        {isAmbassador && (
          <p className="mt-2 flex items-center gap-1.5 text-xs font-semibold text-gram">
            <Star className="h-3.5 w-3.5 text-amber-400" />
            {t("squad.ambassadorBadge")}
          </p>
        )}
        <ul className="mt-3 space-y-1 text-xs text-nav-inactive">
          <li className="flex items-center gap-1.5">
            <Medal className="h-3.5 w-3.5 shrink-0 text-amber-400" />
            {t("squad.level1", { percent: rate1 })}
          </li>
          <li className="flex items-center gap-1.5">
            <Medal className="h-3.5 w-3.5 shrink-0 text-amber-400" />
            {t("squad.level2", { percent: rate2 })}
          </li>
          <li className="flex items-center gap-1.5">
            <Medal className="h-3.5 w-3.5 shrink-0 text-amber-400" />
            {t("squad.level3", { percent: rate3 })}
          </li>
        </ul>
      </div>

      <button
        type="button"
        onClick={handleCopy}
        disabled={!inviteLink}
        className="gradient-action flex items-center justify-center gap-1.5 rounded-full py-3 text-sm font-semibold disabled:opacity-40"
      >
        {!copied && <UserPlus className="h-4 w-4" />}
        {copied ? t("squad.copied") : t("squad.invite")}
      </button>

      {/* Line tabs: 1/2/3 — matches the 3-level referral tree start_cycle actually pays out. */}
      <div className="grid grid-cols-3 gap-2">
        {[1, 2, 3].map((n) => (
          <button
            key={n}
            type="button"
            onClick={() => setSelectedLevel(n)}
            className={`rounded-xl py-2 text-sm font-semibold transition-colors ${
              selectedLevel === n
                ? "bg-gram text-bg"
                : "gradient-surface text-nav-inactive"
            }`}
          >
            {t("squad.lineTab", { n })}
          </button>
        ))}
      </div>

      {levels === null && !levelsError && (
        <p className="p-3 text-center text-sm text-nav-inactive">{t("common.loading")}</p>
      )}

      {levelsError && (
        <div className="flex flex-col items-center gap-2 p-3 text-center">
          <p className="text-sm text-nav-inactive">{t("common.loadFailed")}</p>
          <button
            type="button"
            onClick={retryLevels}
            className="gradient-action rounded-full px-4 py-2 text-xs font-semibold"
          >
            {t("common.retry")}
          </button>
        </div>
      )}

      {active && (
        <div className="flex flex-col gap-3">
          <p className="text-sm font-semibold text-nav-inactive">
            {t("squad.lineHeading", { n: active.level })} · {active.percent}%
          </p>

          <div className="grid grid-cols-3 gap-2">
            <div className="gradient-surface rounded-xl p-3 text-center">
              <p className="text-[10px] text-nav-inactive">{t("squad.participants")}</p>
              <p className="text-lg font-bold">{active.referred_count}</p>
            </div>
            <div className="gradient-surface rounded-xl p-3 text-center">
              <p className="text-[10px] text-nav-inactive">{t("squad.deposits")}</p>
              <p className="text-lg font-bold">{formatGramAmount(active.total_deposits)}</p>
            </div>
            <div className="gradient-surface rounded-xl p-3 text-center">
              <p className="text-[10px] text-nav-inactive">{t("squad.lineEarned")}</p>
              <p className="gradient-gram bg-clip-text text-lg font-bold text-transparent">
                {formatGramAmount(active.earned_total)}
              </p>
            </div>
          </div>

          {active.referrals.length === 0 ? (
            <p className="p-3 text-center text-sm text-nav-inactive">{t("squad.emptyLevel")}</p>
          ) : (
            <div className="gradient-surface flex flex-col divide-y divide-white/5 rounded-xl">
              {active.referrals.map((member) => (
                <div key={member.user_id} className="flex items-center gap-3 p-3 text-sm">
                  <MemberAvatar name={member.display_name} photoUrl={member.photo_url} />
                  <div className="min-w-0 flex-1">
                    <p className="truncate font-semibold">{member.display_name?.trim() ? member.display_name.trim() : "Игрок"}</p>
                    <p className="text-xs text-nav-inactive">
                      {t("squad.deposits")}: {formatGramAmount(member.total_deposited)} {t("common.gram")}
                    </p>
                  </div>
                  <div className="shrink-0 text-right rtl:text-left">
                    <p className="text-[10px] text-nav-inactive">{t("squad.yourIncome")}</p>
                    <p className="font-semibold text-gram">
                      {formatGramAmount(member.earned_from)} {t("common.gram")}
                    </p>
                  </div>
                </div>
              ))}
            </div>
          )}

          {active.truncated && (
            <p className="text-center text-xs text-nav-inactive">
              {t("squad.truncatedNotice", {
                shown: active.referrals.length,
                total: active.referred_count,
              })}
            </p>
          )}
        </div>
      )}
    </div>
  );
}
