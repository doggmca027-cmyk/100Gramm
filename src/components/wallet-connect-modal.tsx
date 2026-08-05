"use client";

import { useState } from "react";
import { beginCell } from "@ton/core";
import {
  CHAIN,
  TonConnectButton,
  UserRejectsError,
  useTonAddress,
  useTonConnectUI,
  useTonWallet,
} from "@tonconnect/ui-react";
import type { PlayerState } from "@/lib/types";
import { ApiError, prepareTonDeposit, verifyTonDeposit } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";

type DepositPhase = "idle" | "preparing" | "awaiting-wallet" | "verifying" | "success";

function truncateAddress(address: string): string {
  return address.length > 10 ? `${address.slice(0, 5)}…${address.slice(-4)}` : address;
}

/** One-cell BoC of a standard TEP-0 text comment: uint32(0) + UTF-8 tail. */
function buildCommentPayload(comment: string): string {
  return beginCell().storeUint(0, 32).storeStringTail(comment).endCell().toBoc().toString("base64");
}

/**
 * Single TON entry point: connect/disconnect status, and — once connected —
 * a direct deposit form. GRAM *is* TON here (this game's branded name for
 * it), so there's no pack/price list — the player just names an amount and
 * sends it, credited back 1:1 once confirmed on-chain.
 *
 * Reached only while already connected — balance-screen.tsx calls
 * tonConnectUI.openModal() directly when disconnected, skipping this modal
 * entirely. The disconnected branch below is a safety net for the rare case
 * the wallet disconnects while this is still open, not the primary path.
 */
export function WalletConnectModal({
  onStateChange,
  onClose,
}: {
  onStateChange: (state: PlayerState) => void;
  onClose: () => void;
}) {
  const { t } = useLanguage();
  const [tonConnectUI] = useTonConnectUI();
  const address = useTonAddress();
  const wallet = useTonWallet();
  const [disconnecting, setDisconnecting] = useState(false);
  const [copied, setCopied] = useState(false);

  const [amount, setAmount] = useState("");
  const [phase, setPhase] = useState<DepositPhase>("idle");
  const [error, setError] = useState<string | null>(null);
  const [creditedAmount, setCreditedAmount] = useState<number | null>(null);

  const busy = phase === "preparing" || phase === "awaiting-wallet" || phase === "verifying";
  const normalized = amount.trim().replace(",", ".");
  const amountTon = Number(normalized);
  const isValidAmount = normalized !== "" && Number.isFinite(amountTon) && amountTon > 0;

  async function handleDisconnect() {
    setDisconnecting(true);
    try {
      await tonConnectUI.disconnect();
    } finally {
      setDisconnecting(false);
    }
  }

  async function handleCopy() {
    if (!address) return;
    try {
      await navigator.clipboard.writeText(address);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // clipboard API unavailable — silently ignore, address is on screen anyway
    }
  }

  async function handleDeposit() {
    if (!isValidAmount || busy) return;
    setError(null);

    const treasuryAddress = process.env.NEXT_PUBLIC_GAME_TREASURY_WALLET;
    if (!treasuryAddress) {
      setError(t("walletConnect.errorNotConfigured"));
      return;
    }

    try {
      setPhase("preparing");
      const prepared = await prepareTonDeposit(amountTon);

      setPhase("awaiting-wallet");
      const network =
        process.env.NEXT_PUBLIC_TON_NETWORK === "testnet" ? CHAIN.TESTNET : CHAIN.MAINNET;
      const { boc } = await tonConnectUI.sendTransaction({
        validUntil: prepared.validUntil,
        network,
        messages: [
          {
            address: treasuryAddress,
            amount: prepared.amountNano,
            payload: buildCommentPayload(prepared.comment),
          },
        ],
      });

      setPhase("verifying");
      const { state } = await verifyTonDeposit({ amountTon, boc });

      setCreditedAmount(amountTon);
      setPhase("success");
      setAmount("");
      onStateChange(state);
    } catch (err) {
      setPhase("idle");
      if (err instanceof UserRejectsError) {
        setError(t("walletConnect.cancelled"));
        return;
      }
      setError(
        err instanceof ApiError && err.code === "payment_not_found"
          ? t("walletConnect.errorNotConfirmed")
          : err instanceof ApiError && err.code === "amount_too_low"
            ? t("walletConnect.errorTooLow")
            : t("walletConnect.errorGeneric"),
      );
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end bg-black/60" onClick={onClose}>
      <div
        className="bg-nav flex flex-col gap-3 rounded-t-2xl p-4"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between">
          <h2 className="text-base font-semibold">{t("walletConnect.title")}</h2>
          <button type="button" onClick={onClose} className="text-nav-inactive" aria-label={t("common.back")}>
            ✕
          </button>
        </div>

        {!address ? (
          <div className="flex flex-col items-center gap-3 py-4 text-center">
            <span className="text-3xl">👛</span>
            <p className="text-xs text-nav-inactive">{t("walletConnect.subtitle")}</p>
            <TonConnectButton />
          </div>
        ) : phase === "success" ? (
          <div className="gradient-surface flex flex-col items-center gap-2 rounded-xl p-6 text-center">
            <span className="text-3xl">✅</span>
            <p className="text-sm font-semibold">
              {t("walletConnect.depositSuccess", { amount: creditedAmount ?? 0 })}
            </p>
            <button
              type="button"
              onClick={onClose}
              className="gradient-action mt-2 w-full rounded-full py-3 text-sm font-semibold"
            >
              {t("walletConnect.close")}
            </button>
          </div>
        ) : (
          <div className="flex flex-col gap-3">
            <div className="gradient-surface flex flex-col gap-2 rounded-xl p-4 text-sm">
              <p className="text-xs text-nav-inactive">
                {t("walletConnect.connectedLabel")}
                {wallet ? ` · ${wallet.device.appName}` : ""}
              </p>
              <button
                type="button"
                onClick={handleCopy}
                className="flex items-center justify-between rounded-lg bg-progress-bg px-3 py-2 font-mono text-sm"
              >
                <span>{truncateAddress(address)}</span>
                <span className="text-xs text-nav-inactive">
                  {copied ? t("walletConnect.copied") : "📋"}
                </span>
              </button>
              <button
                type="button"
                onClick={handleDisconnect}
                disabled={disconnecting}
                className="rounded-full bg-progress-bg py-2 text-xs font-semibold text-danger disabled:opacity-50"
              >
                {t("walletConnect.disconnect")}
              </button>
            </div>

            <div className="gradient-surface flex flex-col gap-2 rounded-xl p-4">
              <p className="text-sm font-semibold">{t("walletConnect.depositTitle")}</p>
              <p className="text-xs text-nav-inactive">{t("walletConnect.depositSubtitle")}</p>
              <input
                type="text"
                inputMode="decimal"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                placeholder={t("walletConnect.depositPlaceholder")}
                disabled={busy}
                className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none disabled:opacity-60"
              />

              {error && <p className="text-xs text-danger">{error}</p>}

              <button
                type="button"
                onClick={handleDeposit}
                disabled={!isValidAmount || busy}
                className="gradient-action rounded-full py-3 text-sm font-semibold disabled:opacity-40"
              >
                {phase === "preparing" && t("walletConnect.preparing")}
                {phase === "awaiting-wallet" && t("walletConnect.awaitingWallet")}
                {phase === "verifying" && t("walletConnect.verifying")}
                {phase === "idle" &&
                  t("walletConnect.depositButton", { amount: isValidAmount ? amountTon : 0 })}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
