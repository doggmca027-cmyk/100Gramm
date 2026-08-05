"use client";

import { useState } from "react";
import type { PlayerState } from "@/lib/types";
import { depositGram, withdrawGram, ApiError } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";

const DEFAULT_WALLET_CONFIG = { deposit_min: 1, withdraw_min: 0.5, withdraw_fee_percent: 10 };

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

export function WalletModal({
  mode,
  state,
  onStateChange,
  onClose,
}: {
  mode: "deposit" | "withdraw";
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
  onClose: () => void;
}) {
  const { t } = useLanguage();
  const [value, setValue] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const wallet = state.season.config.wallet ?? DEFAULT_WALLET_CONFIG;
  const min = mode === "deposit" ? wallet.deposit_min : wallet.withdraw_min;

  const normalized = value.trim().replace(",", ".");
  const amount = Number(normalized);
  const isValidNumber = normalized !== "" && Number.isFinite(amount) && amount > 0;
  const meetsMin = isValidNumber && amount >= min;
  const hasFunds = mode === "deposit" || (isValidNumber && amount <= state.wallet.balance);
  const canSubmit = isValidNumber && meetsMin && hasFunds && !submitting;

  const fee = mode === "withdraw" && isValidNumber ? round2((amount * wallet.withdraw_fee_percent) / 100) : 0;
  const net = mode === "withdraw" && isValidNumber ? round2(amount - fee) : 0;

  async function handleSubmit() {
    if (!canSubmit) return;
    setSubmitting(true);
    setError(null);
    try {
      const { state: newState } = mode === "deposit" ? await depositGram(amount) : await withdrawGram(amount);
      onStateChange(newState);
      onClose();
    } catch (err) {
      setError(
        err instanceof ApiError && err.code === "amount_too_low"
          ? t("wallet.errorTooLow", { min })
          : err instanceof ApiError && err.code === "insufficient_balance"
            ? t("wallet.errorInsufficientBalance")
            : t("wallet.errorGeneric"),
      );
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end bg-black/60" onClick={onClose}>
      <div
        className="bg-nav flex flex-col gap-3 rounded-t-2xl p-4"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between">
          <h2 className="text-base font-semibold">
            {mode === "deposit" ? t("wallet.depositTitle") : t("wallet.withdrawTitle")}
          </h2>
          <button
            type="button"
            onClick={onClose}
            className="text-nav-inactive"
            aria-label={t("common.back")}
          >
            ✕
          </button>
        </div>

        <p className="text-xs text-nav-inactive">
          {t("wallet.balanceLabel")}: {state.wallet.balance.toFixed(2)} {t("common.gram")}
        </p>

        <input
          type="text"
          inputMode="decimal"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          placeholder={t("wallet.amountPlaceholder", { min })}
          className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
          autoFocus
        />

        {isValidNumber && !meetsMin && (
          <p className="text-xs text-danger">{t("wallet.errorTooLow", { min })}</p>
        )}
        {mode === "withdraw" && isValidNumber && meetsMin && !hasFunds && (
          <p className="text-xs text-danger">{t("wallet.errorInsufficientBalance")}</p>
        )}

        {mode === "withdraw" && (
          <div className="gradient-surface flex flex-col gap-1 rounded-xl p-3 text-sm">
            <div className="flex justify-between">
              <span className="text-nav-inactive">{t("wallet.amountLabel")}</span>
              <span>
                {(isValidNumber ? amount : 0).toFixed(2)} {t("common.gram")}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-nav-inactive">
                {t("wallet.feeLabel", { percent: wallet.withdraw_fee_percent })}
              </span>
              <span className="text-danger">
                -{fee.toFixed(2)} {t("common.gram")}
              </span>
            </div>
            <div className="flex justify-between font-semibold">
              <span>{t("wallet.netLabel")}</span>
              <span className="text-profit">
                {net.toFixed(2)} {t("common.gram")}
              </span>
            </div>
          </div>
        )}

        {error && <p className="text-xs text-danger">{error}</p>}

        <button
          type="button"
          onClick={handleSubmit}
          disabled={!canSubmit}
          className="gradient-action rounded-full py-3 text-sm font-semibold disabled:opacity-40"
        >
          {mode === "deposit" ? t("wallet.confirmDeposit") : t("wallet.confirmWithdraw")}
        </button>
      </div>
    </div>
  );
}
