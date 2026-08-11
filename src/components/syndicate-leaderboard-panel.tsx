"use client";

import { useEffect, useState } from "react";
import { Trophy, Flame, Crown, Users, X } from "lucide-react";
import type { PlayerState, SyndicateLeaderboard, SyndicateLeaderboardEntry } from "@/lib/types";
import { fetchSyndicateLeaderboard, buyDirectInfluence, ApiError } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";
import { useCountdown } from "@/hooks/use-countdown";
import { WEEKLY_PRIZE_POOL_TON, DIRECT_INFLUENCE_MIN_TON, DIRECT_INFLUENCE_RATE } from "@/lib/gang-avatars";
import { GangAvatar } from "./gangs-screen";

const RANK_MEDAL_CLASS: Record<number, string> = {
  1: "bg-gram text-bg",
  2: "bg-[#c9ccd6] text-bg",
  3: "bg-[#cd8a4f] text-bg",
};

function syndicateErrorMessage(err: unknown, t: ReturnType<typeof useLanguage>["t"]): string {
  const code = err instanceof ApiError ? err.code : null;
  switch (code) {
    case "not_in_gang":
      return t("districts.notInGang");
    case "not_gang_officer":
      return t("districts.notOfficer");
    case "amount_too_low":
      return t("gangs.invalidAmount");
    case "insufficient_balance":
      return t("gangs.insufficientBalance");
    case "insufficient_gang_bank":
      return t("gangs.insufficientGangBank");
    case "bank_payment_officers_only":
      return t("gangs.bankOfficersOnly");
    default:
      return t("gangs.actionFailed");
  }
}

/** "Xd Yh Zm" countdown to the next weekly reset — same tick-every-second building block as district-map-screen's CountdownLabel, extended with a day unit since this span runs up to a full week. */
function ResetCountdown({ targetIso }: { targetIso: string }) {
  const { t } = useLanguage();
  const seconds = useCountdown(targetIso);
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return (
    <>
      {days}
      {t("common.dayShort")} {hours}
      {t("common.hourShort")} {minutes}
      {t("common.minuteShort")}
    </>
  );
}

/** Bottom-sheet modal for buy_direct_influence — mirrors gangs-screen.tsx's DonateModal shell. */
function BuyInfluenceModal({
  isOfficer,
  gangBankBalance,
  personalBalance,
  onClose,
  onBought,
}: {
  /** Leader/co_leader only — plain members may only ever pay from their own personal balance, see buy_direct_influence (0071_open_battle_boosts_to_members.sql). */
  isOfficer: boolean;
  gangBankBalance: number;
  personalBalance: number;
  onClose: () => void;
  onBought: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const [amount, setAmount] = useState(String(DIRECT_INFLUENCE_MIN_TON));
  const [payFromBank, setPayFromBank] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const parsed = Number(amount);
  const availableBalance = isOfficer && payFromBank ? gangBankBalance : personalBalance;
  const validAmount = amount.trim().length > 0 && Number.isFinite(parsed) && parsed >= DIRECT_INFLUENCE_MIN_TON;
  const canSubmit = validAmount && parsed <= availableBalance && !submitting;
  const pointsPreview = validAmount ? Math.round(parsed * DIRECT_INFLUENCE_RATE) : 0;

  async function handleSubmit() {
    if (!canSubmit) return;
    setSubmitting(true);
    setError(null);
    try {
      const { state } = await buyDirectInfluence(parsed, isOfficer && payFromBank);
      onBought(state);
      onClose();
    } catch (err) {
      setError(syndicateErrorMessage(err, t));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end bg-black/60" onClick={onClose}>
      <div className="flex max-h-[85vh] flex-col gap-4 rounded-t-2xl bg-nav p-4" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between">
          <h2 className="flex items-center gap-1.5 text-base font-semibold">
            <Flame className="h-4 w-4 text-amber-400" />
            {t("leaderboard.boostModalTitle")}
          </h2>
          <button type="button" onClick={onClose} className="text-nav-inactive" aria-label={t("common.back")}>
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="flex flex-col gap-2">
          <input
            type="number"
            inputMode="decimal"
            min={DIRECT_INFLUENCE_MIN_TON}
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder={t("gangs.donateAmountPlaceholder")}
            className={`rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none ring-1 transition-colors ${
              validAmount && parsed > availableBalance ? "ring-danger" : "ring-transparent"
            }`}
          />
          <p className="text-xs text-gram">{t("leaderboard.boostPointsPreview", { points: pointsPreview })}</p>

          {isOfficer ? (
            <label className="flex items-center gap-1.5 text-[11px] text-nav-inactive">
              <input
                type="checkbox"
                checked={payFromBank}
                onChange={() => setPayFromBank((v) => !v)}
                className="accent-amber-400"
              />
              {t("districts.payFromBank")}
            </label>
          ) : (
            <p className="text-[11px] text-nav-inactive">{t("districts.personalBalanceOnly")}</p>
          )}

          {validAmount && parsed > availableBalance && (
            <p className="text-xs text-danger">
              {isOfficer && payFromBank ? t("gangs.insufficientGangBank") : t("gangs.insufficientBalance")}
            </p>
          )}

          <p className="rounded-lg bg-progress-bg px-3 py-2 text-xs text-gram">{t("leaderboard.boostMotivation")}</p>

          {error && <p className="text-xs text-danger">{error}</p>}
        </div>

        <div className="flex gap-2">
          <button
            type="button"
            onClick={onClose}
            className="flex-1 rounded-full bg-progress-bg py-3 text-sm font-semibold text-nav-inactive"
          >
            {t("gangs.cancel")}
          </button>
          <button
            type="button"
            onClick={handleSubmit}
            disabled={!canSubmit}
            className="gradient-action flex-[2] rounded-full py-3 text-sm font-semibold disabled:opacity-40"
          >
            {submitting ? t("gangs.buying") : t("leaderboard.boostSubmitCta")}
          </button>
        </div>
      </div>
    </div>
  );
}

function SyndicateEntryCard({ entry }: { entry: SyndicateLeaderboardEntry }) {
  const { t } = useLanguage();
  return (
    <div
      className={`flex items-center gap-3 rounded-xl border p-3 ${
        entry.is_mine
          ? "border-amber-500/50 bg-amber-500/10 shadow-[0_0_18px_rgba(245,158,11,0.14)]"
          : "border-purple-900/40 bg-slate-900/80"
      }`}
    >
      <span
        className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-bold ${
          RANK_MEDAL_CLASS[entry.rank] ?? "bg-progress-bg text-nav-inactive"
        }`}
      >
        {entry.rank}
      </span>
      <GangAvatar avatarId={entry.avatar_id} cosmetics={entry} sizeClassName="h-10 w-10" iconClassName="h-5 w-5" />
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-semibold">{entry.name}</p>
        <p className="flex items-center gap-1 text-[11px] text-nav-inactive">
          <Users className="h-3 w-3 shrink-0" />
          {entry.member_count}
          <span className="mx-1">·</span>
          {entry.weekly_influence_points} {t("leaderboard.influenceUnit")}
        </p>
      </div>
      <span className="shrink-0 rounded-full bg-progress-bg px-2.5 py-1 text-xs font-semibold text-gram">
        {t("leaderboard.prizeLabel", { amount: entry.prize_ton })}
      </span>
    </div>
  );
}

/** The Leaderboard screen's "Синдикаты" tab — weekly Influence Points ranking, the 100-TON prize pool banner + reset countdown, and the caller's own gang's quick-boost row. */
export function SyndicateLeaderboardPanel({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const [data, setData] = useState<SyndicateLeaderboard | null>(null);
  const [modalOpen, setModalOpen] = useState(false);

  function load() {
    fetchSyndicateLeaderboard()
      .then(setData)
      .catch(() => setData(null));
  }

  useEffect(() => {
    load();
  }, []);

  function handleBought(next: PlayerState) {
    onStateChange(next);
    load();
  }

  // Any gang member can buy Influence, not just leader/co_leader — see
  // buy_direct_influence (0071_open_battle_boosts_to_members.sql). Only
  // paying from the gang bank stays officer-only, enforced inside the modal.
  const canBoost = Boolean(state.gang);
  const isOfficer = state.gang?.my_role === "leader" || state.gang?.my_role === "co_leader";

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4 pb-24">
      <div className="gradient-surface flex flex-col items-center gap-1 rounded-2xl border border-purple-900/40 p-4 text-center shadow-[0_0_24px_rgba(147,51,234,0.1)]">
        <Trophy className="h-6 w-6 text-amber-400" />
        <h1 className="text-base font-bold">
          {t("leaderboard.syndicatePrizeBanner", { amount: data?.prize_pool_ton ?? WEEKLY_PRIZE_POOL_TON })}
        </h1>
        {data && (
          <p className="text-xs text-nav-inactive">
            {t("leaderboard.syndicateResetCountdown")}: <ResetCountdown targetIso={data.next_reset_at} />
          </p>
        )}
      </div>

      {data === null && <p className="p-3 text-center text-sm text-nav-inactive">{t("common.loading")}</p>}

      {data?.my_gang && (
        <div className="flex flex-col gap-2 rounded-2xl border border-amber-500/40 bg-amber-500/5 p-3">
          <div className="flex items-center gap-3">
            <Crown className="h-5 w-5 shrink-0 text-amber-400" />
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-semibold">{data.my_gang.name}</p>
              <p className="text-[11px] text-nav-inactive">
                {data.my_gang.rank !== null
                  ? t("leaderboard.myRank", { rank: data.my_gang.rank })
                  : t("leaderboard.myRankNone")}
                {" · "}
                {data.my_gang.weekly_influence_points} {t("leaderboard.influenceUnit")}
              </p>
            </div>
            {data.my_gang.prize_ton > 0 && (
              <span className="shrink-0 rounded-full bg-progress-bg px-2.5 py-1 text-xs font-semibold text-gram">
                {t("leaderboard.prizeLabel", { amount: data.my_gang.prize_ton })}
              </span>
            )}
          </div>
          {canBoost && (
            <button
              type="button"
              onClick={() => setModalOpen(true)}
              className="gradient-action flex items-center justify-center gap-1.5 rounded-full py-2.5 text-xs font-semibold"
            >
              <Flame className="h-3.5 w-3.5 shrink-0" />
              {t("leaderboard.boostRowCta", { min: DIRECT_INFLUENCE_MIN_TON })}
            </button>
          )}
        </div>
      )}

      {data?.entries.length === 0 && (
        <p className="p-3 text-center text-sm text-nav-inactive">{t("leaderboard.empty")}</p>
      )}

      <div className="flex flex-col gap-2">
        {data?.entries.map((entry) => (
          <SyndicateEntryCard key={entry.gang_id} entry={entry} />
        ))}
      </div>

      {modalOpen && (
        <BuyInfluenceModal
          isOfficer={isOfficer}
          gangBankBalance={state.gang?.bank_balance_gram ?? 0}
          personalBalance={state.wallet.balance ?? 0}
          onClose={() => setModalOpen(false)}
          onBought={handleBought}
        />
      )}
    </div>
  );
}
