"use client";

import { useState } from "react";
import { TonConnectButton, useTonAddress, useTonConnectUI, useTonWallet } from "@tonconnect/ui-react";
import { useLanguage } from "@/lib/i18n/context";

function truncateAddress(address: string): string {
  return address.length > 10 ? `${address.slice(0, 5)}…${address.slice(-4)}` : address;
}

/**
 * Pure connect/disconnect status — nothing else. Depositing/withdrawing GRAM
 * lives in WalletModal (both need a connected wallet too, but the actual
 * money-moving flow belongs with the rest of the wallet UI, not bundled
 * into "am I connected").
 *
 * Reached only while already connected — balance-screen.tsx calls
 * tonConnectUI.openModal() directly when disconnected, skipping this modal
 * entirely. The disconnected branch below is a safety net for the rare case
 * the wallet disconnects while this is still open, not the primary path.
 */
export function WalletConnectModal({ onClose }: { onClose: () => void }) {
  const { t } = useLanguage();
  const [tonConnectUI] = useTonConnectUI();
  const address = useTonAddress();
  const wallet = useTonWallet();
  const [disconnecting, setDisconnecting] = useState(false);
  const [copied, setCopied] = useState(false);

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

        {address ? (
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
              <span dir="ltr">{truncateAddress(address)}</span>
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
        ) : (
          <div className="flex flex-col items-center gap-3 py-4 text-center">
            <span className="text-3xl">👛</span>
            <p className="text-xs text-nav-inactive">{t("walletConnect.subtitle")}</p>
            <TonConnectButton />
          </div>
        )}
      </div>
    </div>
  );
}
