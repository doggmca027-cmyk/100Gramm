"use client";

import { useEffect, useState } from "react";
import { beginCell } from "@ton/core";
import { CHAIN, UserRejectsError, useTonAddress, useTonConnectUI } from "@tonconnect/ui-react";
import type { PlayerState } from "@/lib/types";
import { ApiError, prepareTonDeposit, verifyTonDeposit, withdrawGram } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";

type DepositPhase = "idle" | "preparing" | "awaiting-wallet" | "verifying" | "success";

const DEFAULT_WITHDRAW_CONFIG = { withdraw_min: 0.5, withdraw_fee_percent: 15 };
/** 1 GRAM = 1 TON, so this is really just "don't let a dust transfer through" — must match MIN_DEPOSIT_TON server-side. */
const MIN_DEPOSIT_TON = 0.05;

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

function truncateAddress(address: string): string {
  return address.length > 10 ? `${address.slice(0, 5)}…${address.slice(-4)}` : address;
}

/** One-cell BoC of a standard TEP-0 text comment: uint32(0) + UTF-8 tail. */
function buildCommentPayload(comment: string): string {
  return beginCell().storeUint(0, 32).storeStringTail(comment).endCell().toBoc().toString("base64");
}

/**
 * Both directions of the real GRAM wallet live here: deposit sends TON
 * on-chain to the treasury (credited 1:1 once confirmed — see
 * lib/ton-verify.ts), withdraw escrows GRAM and files an admin-approval
 * request that pays out to the same connected wallet. Both need a
 * connected TON Connect wallet up front — there's no such thing as a
 * deposit or a payout without one — see the shared needsWallet branch
 * below. The old instant self-credit "deposit" (no real TON involved) has
 * been removed entirely: it was a straight balance-minting exploit, not a
 * feature.
 */
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
  const [tonConnectUI] = useTonConnectUI();
  const tonAddress = useTonAddress();
  const needsWallet = !tonAddress;

  // withdraw-mode state (GRAM amount -> escrowed request)
  const [withdrawValue, setWithdrawValue] = useState("");
  const [withdrawSubmitting, setWithdrawSubmitting] = useState(false);
  const [withdrawError, setWithdrawError] = useState<string | null>(null);
  const [justSubmitted, setJustSubmitted] = useState<{ amount: number; net: number } | null>(null);

  // Small self-dismissing reminder shown while filling out the withdraw
  // form — fades out on its own after a few seconds instead of needing to
  // be closed.
  const [showTimingNotice, setShowTimingNotice] = useState(true);
  useEffect(() => {
    const timer = setTimeout(() => setShowTimingNotice(false), 6000);
    return () => clearTimeout(timer);
  }, []);

  // deposit-mode state (TON amount -> on-chain send)
  const [depositValue, setDepositValue] = useState("");
  const [depositPhase, setDepositPhase] = useState<DepositPhase>("idle");
  const [depositError, setDepositError] = useState<string | null>(null);
  const [creditedAmount, setCreditedAmount] = useState<number | null>(null);

  const withdrawConfig = state.season.config.wallet ?? DEFAULT_WITHDRAW_CONFIG;
  const pending = state.wallet.pending_withdrawal;

  const withdrawNormalized = withdrawValue.trim().replace(",", ".");
  const withdrawAmount = Number(withdrawNormalized);
  const isValidWithdraw = withdrawNormalized !== "" && Number.isFinite(withdrawAmount) && withdrawAmount > 0;
  const meetsWithdrawMin = isValidWithdraw && withdrawAmount >= withdrawConfig.withdraw_min;
  const hasFunds = isValidWithdraw && withdrawAmount <= state.wallet.balance;
  const canSubmitWithdraw = isValidWithdraw && meetsWithdrawMin && hasFunds && !needsWallet && !withdrawSubmitting;
  const fee = isValidWithdraw ? round2((withdrawAmount * withdrawConfig.withdraw_fee_percent) / 100) : 0;
  const net = isValidWithdraw ? round2(withdrawAmount - fee) : 0;

  const depositNormalized = depositValue.trim().replace(",", ".");
  const depositAmount = Number(depositNormalized);
  const isValidDeposit = depositNormalized !== "" && Number.isFinite(depositAmount) && depositAmount >= MIN_DEPOSIT_TON;
  const depositBusy = depositPhase === "preparing" || depositPhase === "awaiting-wallet" || depositPhase === "verifying";

  async function handleWithdraw() {
    if (!canSubmitWithdraw) return;
    setWithdrawSubmitting(true);
    setWithdrawError(null);
    try {
      // Withdrawals don't pay out on the spot — they file a request an
      // admin has to approve, which then sends the TON automatically to
      // tonAddress. Show a "submitted" step instead of closing right away.
      const { result, state: newState } = await withdrawGram(withdrawAmount, tonAddress);
      onStateChange(newState);
      setJustSubmitted({ amount: result.amount, net: result.net_amount });
    } catch (err) {
      setWithdrawError(
        err instanceof ApiError && err.code === "amount_too_low"
          ? t("wallet.errorTooLow", { min: withdrawConfig.withdraw_min })
          : err instanceof ApiError && err.code === "insufficient_balance"
            ? t("wallet.errorInsufficientBalance")
            : err instanceof ApiError && err.code === "withdrawal_already_pending"
              ? t("wallet.errorAlreadyPending")
              : t("wallet.errorGeneric"),
      );
    } finally {
      setWithdrawSubmitting(false);
    }
  }

  async function handleDeposit() {
    if (!isValidDeposit || depositBusy) return;
    setDepositError(null);

    const treasuryAddress = process.env.NEXT_PUBLIC_GAME_TREASURY_WALLET;
    if (!treasuryAddress) {
      setDepositError(t("walletConnect.errorNotConfigured"));
      return;
    }

    try {
      setDepositPhase("preparing");
      const prepared = await prepareTonDeposit(depositAmount);

      setDepositPhase("awaiting-wallet");
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

      setDepositPhase("verifying");
      const { state: newState } = await verifyTonDeposit({ amountTon: depositAmount, boc });

      setCreditedAmount(depositAmount);
      setDepositPhase("success");
      setDepositValue("");
      onStateChange(newState);
    } catch (err) {
      setDepositPhase("idle");
      if (err instanceof UserRejectsError) {
        setDepositError(t("walletConnect.cancelled"));
        return;
      }
      setDepositError(
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

        {needsWallet ? (
          <div className="flex flex-col items-center gap-3 py-4 text-center">
            <span className="text-3xl">👛</span>
            <p className="text-xs text-nav-inactive">
              {mode === "deposit" ? t("wallet.needsWalletDeposit") : t("wallet.needsWalletWithdraw")}
            </p>
            <button
              type="button"
              onClick={() => tonConnectUI.openModal()}
              className="gradient-action rounded-full px-6 py-3 text-sm font-semibold"
            >
              {t("walletConnect.navLabel")}
            </button>
          </div>
        ) : mode === "deposit" ? (
          depositPhase === "success" ? (
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
            <>
              <p className="text-xs text-nav-inactive">{t("walletConnect.depositSubtitle")}</p>

              <input
                type="text"
                inputMode="decimal"
                value={depositValue}
                onChange={(e) => setDepositValue(e.target.value)}
                placeholder={t("walletConnect.depositPlaceholder")}
                disabled={depositBusy}
                className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none disabled:opacity-60"
                autoFocus
              />

              {depositError && <p className="text-xs text-danger">{depositError}</p>}

              <button
                type="button"
                onClick={handleDeposit}
                disabled={!isValidDeposit || depositBusy}
                className="gradient-action rounded-full py-3 text-sm font-semibold disabled:opacity-40"
              >
                {depositPhase === "preparing" && t("walletConnect.preparing")}
                {depositPhase === "awaiting-wallet" && t("walletConnect.awaitingWallet")}
                {depositPhase === "verifying" && t("walletConnect.verifying")}
                {depositPhase === "idle" &&
                  t("walletConnect.depositButton", { amount: isValidDeposit ? depositAmount : 0 })}
              </button>
            </>
          )
        ) : justSubmitted ? (
          <div className="gradient-surface flex flex-col items-center gap-2 rounded-xl p-6 text-center">
            <span className="text-3xl">✅</span>
            <p className="text-sm font-semibold">{t("wallet.submittedTitle")}</p>
            <p className="text-xs text-nav-inactive">
              {t("wallet.submittedBody", { net: justSubmitted.net })}
            </p>
            <button
              type="button"
              onClick={onClose}
              className="gradient-action mt-2 w-full rounded-full py-3 text-sm font-semibold"
            >
              {t("wallet.gotIt")}
            </button>
          </div>
        ) : pending ? (
          <div className="gradient-surface flex flex-col gap-2 rounded-xl p-4 text-sm">
            <p className="font-semibold">⏳ {t("wallet.pendingTitle")}</p>
            <div className="flex justify-between">
              <span className="text-nav-inactive">{t("wallet.amountLabel")}</span>
              <span>
                {pending.amount.toFixed(2)} {t("common.gram")}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-nav-inactive">{t("wallet.netLabel")}</span>
              <span className="text-profit">
                {pending.net_amount.toFixed(2)} {t("common.gram")}
              </span>
            </div>
            <p className="text-xs text-nav-inactive">{t("wallet.pendingBody")}</p>
          </div>
        ) : (
          <>
            <p className="text-xs text-nav-inactive">
              {t("wallet.balanceLabel")}: {state.wallet.balance.toFixed(2)} {t("common.gram")}
            </p>

            <div
              className={`overflow-hidden transition-all duration-700 ease-out ${
                showTimingNotice ? "max-h-6 opacity-100" : "max-h-0 opacity-0"
              }`}
            >
              <p className="text-[11px] text-nav-inactive/70">{t("wallet.withdrawTimingNotice")}</p>
            </div>

            <input
              type="text"
              inputMode="decimal"
              value={withdrawValue}
              onChange={(e) => setWithdrawValue(e.target.value)}
              placeholder={t("wallet.amountPlaceholder", { min: withdrawConfig.withdraw_min })}
              className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
              autoFocus
            />

            {isValidWithdraw && !meetsWithdrawMin && (
              <p className="text-xs text-danger">
                {t("wallet.errorTooLow", { min: withdrawConfig.withdraw_min })}
              </p>
            )}
            {isValidWithdraw && meetsWithdrawMin && !hasFunds && (
              <p className="text-xs text-danger">{t("wallet.errorInsufficientBalance")}</p>
            )}

            <div className="gradient-surface flex flex-col gap-1 rounded-xl p-3 text-sm">
              <div className="flex justify-between">
                <span className="text-nav-inactive">{t("wallet.amountLabel")}</span>
                <span>
                  {(isValidWithdraw ? withdrawAmount : 0).toFixed(2)} {t("common.gram")}
                </span>
              </div>
              <div className="flex justify-between">
                <span className="text-nav-inactive">
                  {t("wallet.feeLabel", { percent: withdrawConfig.withdraw_fee_percent })}
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
              <div className="flex justify-between text-xs">
                <span className="text-nav-inactive">{t("wallet.payoutTo")}</span>
                <span className="font-mono">{truncateAddress(tonAddress)}</span>
              </div>
            </div>

            {withdrawError && <p className="text-xs text-danger">{withdrawError}</p>}

            <button
              type="button"
              onClick={handleWithdraw}
              disabled={!canSubmitWithdraw}
              className="gradient-action rounded-full py-3 text-sm font-semibold disabled:opacity-40"
            >
              {t("wallet.confirmWithdraw")}
            </button>
          </>
        )}
      </div>
    </div>
  );
}
