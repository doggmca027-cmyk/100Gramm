"use client";

import { useState } from "react";
import { CHAIN, UserRejectsError, useTonAddress, useTonConnectUI } from "@tonconnect/ui-react";
import type { PlayerState } from "@/lib/types";
import { ApiError, prepareUsdtPayment, verifyUsdtPayment } from "@/lib/api-client";
import { buildJettonTransferBody, JETTON_TRANSFER_GAS_NANO } from "@/lib/usdt-jetton";
import { useLanguage } from "@/lib/i18n/context";
import { openTonConnectModal } from "@/lib/ton-connect-open";

type Phase = "idle" | "preparing" | "awaiting-wallet" | "verifying";

/**
 * "Оплатить в USDT" — pays a tier's GRAM price directly with a Jetton
 * transfer instead of spending GRAM balance (spec §2/§3). Once the payment
 * verifies, the credited GRAM is handed to onPaid alongside the fresh
 * state — the caller (ProductDetailScreen) is the one that decides to
 * immediately spend it via startCycle, same two-step flow a TON deposit
 * already uses (credit balance, then a separate explicit start).
 */
export function UsdtPayButton({
  tier,
  gramAmount,
  rate,
  disabled,
  onPaid,
}: {
  tier: number;
  gramAmount: number;
  rate: number | null;
  disabled?: boolean;
  onPaid: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const [tonConnectUI] = useTonConnectUI();
  const tonAddress = useTonAddress();
  const [phase, setPhase] = useState<Phase>("idle");
  const [error, setError] = useState<string | null>(null);

  const usdtEstimate = rate != null ? (gramAmount * rate).toFixed(2) : null;
  const busy = phase !== "idle";

  async function handleClick() {
    setError(null);

    if (!tonAddress) {
      try {
        await openTonConnectModal(tonConnectUI);
      } catch {
        setError(t("walletConnect.errorConnectFailed"));
      }
      return;
    }

    try {
      setPhase("preparing");
      const prepared = await prepareUsdtPayment({ buyerAddress: tonAddress, tier });

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
      const { state } = await verifyUsdtPayment(prepared.quoteId);
      onPaid(state);
      setPhase("idle");
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

  return (
    <div className="flex flex-col gap-1">
      <button
        type="button"
        onClick={handleClick}
        disabled={disabled || busy}
        className="gradient-surface w-full rounded-full border border-border py-2.5 text-xs font-semibold text-nav-inactive disabled:opacity-40"
      >
        {phase === "preparing" && t("walletConnect.preparing")}
        {phase === "awaiting-wallet" && t("walletConnect.awaitingWallet")}
        {phase === "verifying" && t("walletConnect.verifying")}
        {phase === "idle" && (
          <>
            💵 {t("usdtPay.button")}
            {usdtEstimate ? ` (~${usdtEstimate} USDT)` : ""}
          </>
        )}
      </button>
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}
