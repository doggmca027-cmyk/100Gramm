"use client";

import { useState } from "react";
import { CHAIN, UserRejectsError, useTonAddress, useTonConnectUI } from "@tonconnect/ui-react";
import type { PlayerState } from "@/lib/types";
import { ApiError, prepareUsdtPayment, verifyUsdtPayment } from "@/lib/api-client";
import { buildJettonTransferBody, JETTON_TRANSFER_GAS_NANO } from "@/lib/usdt-jetton";
import { useLanguage } from "@/lib/i18n/context";

type Phase = "idle" | "preparing" | "awaiting-wallet" | "verifying" | "success";

/** Mirrors MIN_GRAM_AMOUNT in /api/wallet/usdt-payment/prepare/route.ts. */
const MIN_GRAM_AMOUNT = 0.05;

/**
 * "Автопополнение через кошелёк" — enter a GRAM amount, pay the USDT
 * equivalent via a TON Connect Jetton transfer, same underlying
 * prepare/verify flow UsdtPayButton uses for a fixed tier price, just with
 * a free-form amount instead. Shown alongside ManualDepositRequisites on
 * the USDT tab, not instead of it — this is for players who *do* have a
 * TON Connect-paired wallet handy and want the one-tap flow.
 */
export function UsdtAutoDeposit({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const [tonConnectUI] = useTonConnectUI();
  const tonAddress = useTonAddress();
  const [value, setValue] = useState("");
  const [phase, setPhase] = useState<Phase>("idle");
  const [error, setError] = useState<string | null>(null);
  const [creditedAmount, setCreditedAmount] = useState<number | null>(null);

  const normalized = value.trim().replace(",", ".");
  const gramAmount = Number(normalized);
  const isValid = normalized !== "" && Number.isFinite(gramAmount) && gramAmount >= MIN_GRAM_AMOUNT;
  const busy = phase === "preparing" || phase === "awaiting-wallet" || phase === "verifying";
  const usdtEstimate =
    isValid && state.exchange_rate != null ? (gramAmount * state.exchange_rate.rate).toFixed(2) : null;

  async function handlePay() {
    setError(null);
    if (!isValid || busy) return;

    if (!tonAddress) {
      tonConnectUI.openModal();
      return;
    }

    try {
      setPhase("preparing");
      const prepared = await prepareUsdtPayment({ buyerAddress: tonAddress, gramAmount });

      setPhase("awaiting-wallet");
      const network =
        process.env.NEXT_PUBLIC_TON_NETWORK === "testnet" ? CHAIN.TESTNET : CHAIN.MAINNET;
      const body = buildJettonTransferBody({
        jettonAmountUnits: BigInt(prepared.usdtAmountUnits),
        destination: prepared.destinationAddress,
        responseDestination: prepared.responseDestination,
        forwardTonAmountNano: BigInt(prepared.forwardTonAmountNano),
        comment: prepared.comment,
      });

      await tonConnectUI.sendTransaction({
        validUntil: prepared.validUntil,
        network,
        messages: [
          {
            address: prepared.jettonWalletAddress,
            amount: JETTON_TRANSFER_GAS_NANO.toString(),
            payload: body.toBoc().toString("base64"),
          },
        ],
      });

      setPhase("verifying");
      const { state: newState } = await verifyUsdtPayment(prepared.quoteId);
      setCreditedAmount(prepared.gramAmount);
      setPhase("success");
      setValue("");
      onStateChange(newState);
    } catch (err) {
      setPhase("idle");
      if (err instanceof UserRejectsError) {
        setError(t("walletConnect.cancelled"));
        return;
      }
      setError(
        err instanceof ApiError && err.code === "jetton_wallet_not_found"
          ? t("usdtPay.noJettonWallet")
          : err instanceof ApiError && err.code === "payment_not_found"
            ? t("walletConnect.errorNotConfirmed")
            : t("walletConnect.errorGeneric"),
      );
    }
  }

  if (phase === "success") {
    return (
      <div className="gradient-surface flex flex-col items-center gap-2 rounded-xl p-4 text-center">
        <span className="text-2xl">✅</span>
        <p className="text-sm font-semibold">
          {t("walletConnect.depositSuccess", { amount: creditedAmount ?? 0 })}
        </p>
        <button
          type="button"
          onClick={() => setPhase("idle")}
          className="gradient-action mt-1 w-full rounded-full py-2 text-xs font-semibold"
        >
          {t("walletConnect.close")}
        </button>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-2">
      <p className="text-xs text-nav-inactive">{t("usdtDeposit.autoSubtitle")}</p>

      <input
        type="text"
        inputMode="decimal"
        value={value}
        onChange={(e) => setValue(e.target.value)}
        placeholder={t("usdtDeposit.autoPlaceholder", { min: MIN_GRAM_AMOUNT })}
        disabled={busy}
        className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none disabled:opacity-60"
      />

      {isValid && usdtEstimate != null && (
        <p className="text-[11px] text-nav-inactive/70">
          ≈ {usdtEstimate} USDT
          {state.exchange_rate != null &&
            ` · ${t("usdtPay.rateBadge", { rate: state.exchange_rate.rate.toFixed(2) })}`}
        </p>
      )}

      {error && <p className="text-xs text-danger">{error}</p>}

      <button
        type="button"
        onClick={handlePay}
        disabled={!isValid || busy}
        className="gradient-action rounded-full py-3 text-sm font-semibold disabled:opacity-40"
      >
        {phase === "preparing" && t("walletConnect.preparing")}
        {phase === "awaiting-wallet" && t("walletConnect.awaitingWallet")}
        {phase === "verifying" && t("walletConnect.verifying")}
        {phase === "idle" &&
          (!tonAddress
            ? t("walletConnect.navLabel")
            : t("usdtDeposit.autoButton", { amount: isValid ? usdtEstimate ?? "0" : "0" }))}
      </button>
    </div>
  );
}
