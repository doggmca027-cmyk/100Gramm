"use client";

import { useState, type ReactNode } from "react";
import { Vault, Coins, Lock, Zap, Clock } from "lucide-react";
import type { PlayerState, BankDeposit, BankPlanDays } from "@/lib/types";
import { BANK_PLANS, bankPlan } from "@/lib/bank-plans";
import { createBankDeposit, ApiError } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";
import { formatGramAmount } from "@/lib/format-gram";
import { useCountdown, formatDuration, useDurationUnits } from "@/hooks/use-countdown";

/** The next UTC calendar-day rollover — daily installments are credited exactly at this boundary, see resolve_due_bank_payouts (0057_bank_daily_payouts.sql). */
function nextUtcMidnightIso(): string {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1)).toISOString();
}

/** Shared shell for both the active and history rows. */
function DepositCard({
  deposit,
  body,
  error,
  action,
}: {
  deposit: BankDeposit;
  body: ReactNode;
  error: string | null;
  action: ReactNode;
}) {
  const { t } = useLanguage();
  return (
    <div className="flex flex-col gap-2 rounded-xl border border-purple-900/40 bg-black/30 p-3 shadow-[0_0_20px_rgba(147,51,234,0.08)]">
      <div className="flex items-center justify-between">
        <span className="flex items-center gap-1.5 text-sm font-semibold">
          <Lock className="h-4 w-4 shrink-0 text-purple-400" />
          {t("bank.planLabel", { days: deposit.plan_days })}
        </span>
        <span className="text-sm font-semibold text-amber-400">{formatGramAmount(deposit.amount)} GRAM</span>
      </div>

      {body}

      {deposit.status === "active" && (deposit.bonus_speed || deposit.bonus_slot) && (
        <div className="flex gap-3 text-[11px] text-purple-300">
          {deposit.bonus_speed && (
            <span className="flex items-center gap-1">
              <Zap className="h-3 w-3 shrink-0 text-amber-400" />
              {t("bank.buffSpeed")}
            </span>
          )}
          {deposit.bonus_slot && (
            <span className="flex items-center gap-1">
              <Coins className="h-3 w-3 shrink-0 text-amber-400" />
              {t("bank.buffSlot")}
            </span>
          )}
        </div>
      )}

      {error && <p className="text-xs text-danger">{error}</p>}

      {action}
    </div>
  );
}

/** An active deposit — shows daily-payout progress + a live countdown to the next installment. Frozen for the full staking term, no early-exit action (nothing to manually claim either, see 0057_bank_daily_payouts.sql). */
function ActiveDepositRow({ deposit }: { deposit: BankDeposit }) {
  const { t } = useLanguage();
  const units = useDurationUnits();
  const untilNextPayout = useCountdown(nextUtcMidnightIso());

  const totalPayable = deposit.amount + deposit.expected_reward;
  const paidSoFar = deposit.principal_paid + deposit.reward_paid;
  const progressPercent = Math.min(100, Math.round((deposit.days_paid / deposit.plan_days) * 100));

  return (
    <DepositCard
      deposit={deposit}
      error={null}
      body={
        <div className="flex flex-col gap-1.5">
          <div className="flex items-center justify-between text-xs text-nav-inactive">
            <span>
              {t("bank.paidProgress", { paid: formatGramAmount(paidSoFar), total: formatGramAmount(totalPayable) })}
            </span>
            <span>{t("bank.daysProgress", { done: deposit.days_paid, total: deposit.plan_days })}</span>
          </div>
          <div className="h-1.5 w-full overflow-hidden rounded-full bg-progress-bg">
            <div
              className="h-full rounded-full bg-gradient-to-r from-purple-500 to-amber-400 transition-all"
              style={{ width: `${progressPercent}%` }}
            />
          </div>
          <span className="flex items-center gap-1 text-xs text-boost">
            <Clock className="h-3.5 w-3.5 shrink-0" />
            {t("bank.nextPayoutIn", { time: formatDuration(untilNextPayout, units) })}
          </span>
        </div>
      }
      action={null}
    />
  );
}

/** A resolved (fully paid out / early-closed) deposit — static, no countdown, no action. */
function PastDepositRow({ deposit }: { deposit: BankDeposit }) {
  const { t } = useLanguage();
  const totalPayable = deposit.amount + deposit.expected_reward;
  const paidSoFar = deposit.principal_paid + deposit.reward_paid;
  return (
    <DepositCard
      deposit={deposit}
      error={null}
      body={
        <div className="flex items-center justify-between text-xs text-nav-inactive">
          <span>{deposit.status === "claimed" ? t("bank.statusClaimed") : t("bank.statusEarlyClosed")}</span>
          <span>{t("bank.paidProgress", { paid: formatGramAmount(paidSoFar), total: formatGramAmount(totalPayable) })}</span>
        </div>
      }
      action={null}
    />
  );
}

export function BankScreen({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const [selectedPlan, setSelectedPlan] = useState<BankPlanDays>(7);
  const [amountInput, setAmountInput] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const plan = bankPlan(selectedPlan);
  const balance = state.wallet.balance ?? 0;

  const normalized = amountInput.trim().replace(",", ".");
  const amount = Number(normalized);
  const hasValue = normalized !== "" && Number.isFinite(amount) && amount > 0;
  // Client-side only, for the red-border/disabled-button UX — create_bank_deposit
  // re-validates this exact threshold server-side regardless (see lib/bank-plans.ts).
  const belowMin = hasValue && amount < plan.minAmount;
  const overBalance = hasValue && amount > balance;
  const canSubmit = hasValue && !belowMin && !overBalance && !submitting;

  async function handleSubmit() {
    if (!canSubmit) return;
    setSubmitting(true);
    setError(null);
    try {
      const { state: newState } = await createBankDeposit(selectedPlan, amount);
      onStateChange(newState);
      setAmountInput("");
    } catch (err) {
      setError(
        err instanceof ApiError && err.code === "amount_too_low"
          ? t("bank.minAmountError", { min: plan.minAmount })
          : err instanceof ApiError && err.code === "insufficient_balance"
            ? t("bank.insufficientBalance")
            : t("bank.actionFailed"),
      );
    } finally {
      setSubmitting(false);
    }
  }

  const activeDeposits = state.bank_deposits.filter((d) => d.status === "active");
  const pastDeposits = state.bank_deposits.filter((d) => d.status !== "active");

  return (
    <div className="flex flex-1 flex-col gap-5 overflow-y-auto p-4 pb-24">
      <div>
        <h1 className="flex items-center gap-1.5 text-lg font-bold">
          <Vault className="h-5 w-5 text-amber-400" />
          {t("bank.title")}
        </h1>
        <p className="mt-1 text-xs text-nav-inactive">{t("bank.subtitle")}</p>
      </div>

      <div className="grid grid-cols-3 gap-2">
        {BANK_PLANS.map((p) => (
          <button
            key={p.days}
            type="button"
            onClick={() => setSelectedPlan(p.days)}
            className={`flex flex-col items-center gap-1.5 rounded-xl border p-3 text-center transition-colors ${
              selectedPlan === p.days
                ? "border-amber-500/50 bg-amber-500/10 shadow-[0_0_18px_rgba(245,158,11,0.18)]"
                : "border-purple-900/40 bg-black/20 shadow-[0_0_18px_rgba(147,51,234,0.08)]"
            }`}
          >
            <span className="text-base font-bold text-amber-400">+{p.yieldPercent}%</span>
            <span className="text-[11px] font-semibold text-nav-inactive">{t("bank.days", { n: p.days })}</span>
            <span className="text-[10px] text-nav-inactive">{t("bank.minFrom", { amount: p.minAmount })}</span>
            <div className="flex items-center gap-1.5">
              {p.grantsSpeed && <Zap className="h-3.5 w-3.5 shrink-0 text-purple-400" />}
              {p.grantsSlot && <Coins className="h-3.5 w-3.5 shrink-0 text-amber-400" />}
              {p.days === 14 && (
                <span className="text-[9px] leading-tight text-nav-inactive">{t("bank.orBonus")}</span>
              )}
            </div>
          </button>
        ))}
      </div>

      {/* Full sentence per plan, not just icons — what exactly you get, spelled out. */}
      <div className="flex flex-col gap-1.5 rounded-xl bg-progress-bg p-3 text-xs text-nav-inactive">
        {BANK_PLANS.map((p) => (
          <p key={p.days} className={p.days === selectedPlan ? "font-semibold text-white" : undefined}>
            <span className="text-amber-400">{t("bank.days", { n: p.days })}:</span> {t(p.perkDescriptionKey)}
          </p>
        ))}
      </div>

      <div className="gradient-surface flex flex-col gap-2 rounded-2xl border border-purple-900/40 p-4 shadow-[0_0_24px_rgba(147,51,234,0.1)]">
        <p className="text-xs text-nav-inactive">
          {t("bank.depositSubtitle", { days: plan.days, min: plan.minAmount })}
        </p>

        <input
          type="text"
          inputMode="decimal"
          dir="ltr"
          value={amountInput}
          onChange={(e) => setAmountInput(e.target.value)}
          placeholder={t("bank.amountPlaceholder", { min: plan.minAmount })}
          className={`rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none ring-1 transition-colors ${
            belowMin || overBalance ? "ring-danger" : "ring-transparent"
          }`}
        />

        <div className="flex gap-2">
          {[3, 10, 15].map((quick) => (
            <button
              key={quick}
              type="button"
              onClick={() => setAmountInput(String(quick))}
              className="flex-1 rounded-full bg-progress-bg py-1.5 text-xs font-semibold text-nav-inactive"
            >
              {quick}
            </button>
          ))}
          <button
            type="button"
            onClick={() => setAmountInput(String(balance))}
            className="flex-1 rounded-full bg-progress-bg py-1.5 text-xs font-semibold text-nav-inactive"
          >
            {t("bank.max")}
          </button>
        </div>

        {belowMin && (
          <p className="text-xs text-danger">{t("bank.minAmountError", { min: plan.minAmount })}</p>
        )}
        {overBalance && !belowMin && <p className="text-xs text-danger">{t("bank.insufficientBalance")}</p>}
        {error && <p className="text-xs text-danger">{error}</p>}

        <button
          type="button"
          onClick={handleSubmit}
          disabled={!canSubmit}
          className="gradient-action rounded-full py-3 text-sm font-semibold disabled:opacity-40"
        >
          {submitting ? t("bank.opening") : t("bank.openDeposit")}
        </button>
      </div>

      {activeDeposits.length > 0 && (
        <div className="flex flex-col gap-2">
          <h2 className="px-1 text-xs font-semibold text-nav-inactive">{t("bank.activeDeposits")}</h2>
          {activeDeposits.map((d) => (
            <ActiveDepositRow key={d.id} deposit={d} />
          ))}
        </div>
      )}

      {pastDeposits.length > 0 && (
        <div className="flex flex-col gap-2">
          <h2 className="px-1 text-xs font-semibold text-nav-inactive">{t("bank.pastDeposits")}</h2>
          {pastDeposits.map((d) => (
            <PastDepositRow key={d.id} deposit={d} />
          ))}
        </div>
      )}
    </div>
  );
}
