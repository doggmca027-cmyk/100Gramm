"use client";

import { useState } from "react";
import type { PlayerState } from "@/lib/types";
import { fetchState } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";

function CopyRow({ label, value }: { label: string; value: string }) {
  const { t } = useLanguage();
  const [copied, setCopied] = useState(false);

  async function handleCopy() {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // clipboard API unavailable — the value is right there on screen anyway
    }
  }

  return (
    <div className="flex flex-col gap-1">
      <p className="text-xs text-nav-inactive">{label}</p>
      <button
        type="button"
        onClick={handleCopy}
        className="flex w-full items-center justify-between gap-2 rounded-lg bg-progress-bg px-3 py-2 text-left font-mono text-sm"
      >
        <span className="truncate">{value}</span>
        <span className="shrink-0 text-xs text-nav-inactive">
          {copied ? t("walletConnect.copied") : "📋"}
        </span>
      </button>
    </div>
  );
}

/**
 * Manual top-up — address + memo to paste into *any* wallet or exchange,
 * not just a TON Connect-paired one (spec: "транзакции могут проводить с
 * кошельков, которых не предоставляет TON Connect"). No sendTransaction
 * call happens here, so there's nothing to actively verify against —
 * crediting instead relies on the passive background sweep
 * (lib/ton-deposit-sweep.ts / lib/usdt-deposit-sweep.ts) that scans the
 * treasury's incoming transfers and matches each one's memo back to a
 * user. "Проверить сейчас" just re-fetches state, which piggybacks that
 * same sweep — see /api/state. Shown alongside the TON Connect auto-flow
 * on both currency tabs, not instead of it.
 */
export function ManualDepositRequisites({
  currency,
  state,
  onStateChange,
}: {
  currency: "TON" | "USDT";
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const [checking, setChecking] = useState(false);

  const treasuryAddress = process.env.NEXT_PUBLIC_GAME_TREASURY_WALLET;
  const memo = state.squad.invite_code;
  const copy = currency === "TON" ? TON_COPY : USDT_COPY;

  async function handleCheckNow() {
    setChecking(true);
    try {
      const newState = await fetchState();
      onStateChange(newState);
    } catch {
      // Transient — the ambient sweep on every /api/state call picks it up regardless.
    } finally {
      setChecking(false);
    }
  }

  if (!treasuryAddress) {
    return <p className="text-xs text-danger">{t("walletConnect.errorNotConfigured")}</p>;
  }

  return (
    <div className="flex flex-col gap-3">
      <p className="text-xs text-nav-inactive">{t(copy.subtitle)}</p>

      <CopyRow label={t(copy.addressLabel)} value={treasuryAddress} />
      <CopyRow label={t(copy.memoLabel)} value={memo} />

      <div className="gradient-surface flex flex-col gap-1 rounded-xl p-3 text-xs text-nav-inactive">
        <p>⚠️ {t(copy.memoWarning)}</p>
        {currency === "USDT" && state.exchange_rate != null && (
          <p>{t("usdtPay.rateBadge", { rate: state.exchange_rate.rate.toFixed(2) })}</p>
        )}
        {currency === "TON" && <p>{t("tonDeposit.pegNote")}</p>}
      </div>

      <button
        type="button"
        onClick={handleCheckNow}
        disabled={checking}
        className="gradient-action rounded-full py-3 text-sm font-semibold disabled:opacity-40"
      >
        {checking ? t("usdtDeposit.checking") : t("usdtDeposit.checkNow")}
      </button>
    </div>
  );
}

const TON_COPY = {
  subtitle: "tonDeposit.subtitle",
  addressLabel: "tonDeposit.addressLabel",
  memoLabel: "tonDeposit.memoLabel",
  memoWarning: "tonDeposit.memoWarning",
} as const;

const USDT_COPY = {
  subtitle: "usdtDeposit.subtitle",
  addressLabel: "usdtDeposit.addressLabel",
  memoLabel: "usdtDeposit.memoLabel",
  memoWarning: "usdtDeposit.memoWarning",
} as const;
