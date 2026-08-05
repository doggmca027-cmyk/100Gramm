"use client";

import { useEffect, useState } from "react";
import { beginCell } from "@ton/core";
import { CHAIN, TonConnectButton, UserRejectsError, useTonAddress, useTonConnectUI } from "@tonconnect/ui-react";
import type { PlayerState } from "@/lib/types";
import {
  ApiError,
  fetchShopPacks,
  prepareShopPurchase,
  verifyShopPurchase,
  type ShopPack,
} from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";

type Phase = "idle" | "preparing" | "awaiting-wallet" | "verifying" | "success";

/** One-cell BoC of a standard TEP-0 text comment: uint32(0) + UTF-8 tail. */
function buildCommentPayload(comment: string): string {
  return beginCell().storeUint(0, 32).storeStringTail(comment).endCell().toBoc().toString("base64");
}

export function BuyItemModal({
  onStateChange,
  onClose,
}: {
  onStateChange: (state: PlayerState) => void;
  onClose: () => void;
}) {
  const { t } = useLanguage();
  const [tonConnectUI] = useTonConnectUI();
  const walletAddress = useTonAddress();

  const [packs, setPacks] = useState<ShopPack[] | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [selectedPackId, setSelectedPackId] = useState<string | null>(null);
  const [phase, setPhase] = useState<Phase>("idle");
  const [error, setError] = useState<string | null>(null);
  const [creditedAmount, setCreditedAmount] = useState<number | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetchShopPacks()
      .then(({ packs }) => {
        if (cancelled) return;
        setPacks(packs);
        setSelectedPackId((current) => current ?? packs[0]?.id ?? null);
      })
      .catch(() => !cancelled && setLoadFailed(true));
    return () => {
      cancelled = true;
    };
  }, []);

  const selectedPack = packs?.find((p) => p.id === selectedPackId) ?? null;
  const busy = phase === "preparing" || phase === "awaiting-wallet" || phase === "verifying";

  async function handleBuy() {
    if (!selectedPack || busy) return;
    setError(null);

    const treasuryAddress = process.env.NEXT_PUBLIC_GAME_TREASURY_WALLET;
    if (!treasuryAddress) {
      setError(t("shop.errorNotConfigured"));
      return;
    }

    try {
      setPhase("preparing");
      const prepared = await prepareShopPurchase(selectedPack.id);

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
      const { state } = await verifyShopPurchase({ packId: selectedPack.id, boc });

      setCreditedAmount(selectedPack.gram_amount);
      setPhase("success");
      onStateChange(state);
    } catch (err) {
      setPhase("idle");
      if (err instanceof UserRejectsError) {
        setError(t("shop.cancelled"));
        return;
      }
      setError(
        err instanceof ApiError && err.code === "payment_not_found"
          ? t("shop.errorNotConfirmed")
          : t("shop.errorGeneric"),
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
          <h2 className="text-base font-semibold">{t("shop.title")}</h2>
          <button type="button" onClick={onClose} className="text-nav-inactive" aria-label={t("common.back")}>
            ✕
          </button>
        </div>

        {phase === "success" ? (
          <div className="gradient-surface flex flex-col items-center gap-2 rounded-xl p-6 text-center">
            <span className="text-3xl">✅</span>
            <p className="text-sm font-semibold">
              {t("shop.success", { amount: creditedAmount ?? 0 })}
            </p>
            <button
              type="button"
              onClick={onClose}
              className="gradient-action mt-2 w-full rounded-full py-3 text-sm font-semibold"
            >
              {t("shop.close")}
            </button>
          </div>
        ) : (
          <>
            <p className="text-xs text-nav-inactive">{t("shop.subtitle")}</p>

            {loadFailed && <p className="text-xs text-danger">{t("common.loadFailed")}</p>}

            {!packs && !loadFailed && (
              <p className="py-6 text-center text-xs text-nav-inactive">{t("common.loading")}</p>
            )}

            {packs && (
              <div className="flex flex-col gap-2">
                {packs.map((pack) => (
                  <button
                    key={pack.id}
                    type="button"
                    disabled={busy}
                    onClick={() => setSelectedPackId(pack.id)}
                    className={`gradient-surface flex items-center justify-between rounded-xl p-3 text-left text-sm disabled:opacity-60 ${
                      selectedPackId === pack.id ? "outline outline-2 outline-gram" : ""
                    }`}
                  >
                    <span>
                      <span className="block font-semibold">{pack.title}</span>
                      <span className="text-xs text-nav-inactive">
                        {pack.gram_amount} {t("common.gram")}
                      </span>
                    </span>
                    <span className="font-semibold text-gram">{pack.price_ton} TON</span>
                  </button>
                ))}
              </div>
            )}

            {!walletAddress && (
              <div className="flex flex-col items-center gap-2 py-2">
                <p className="text-xs text-nav-inactive">{t("shop.connectWallet")}</p>
                <TonConnectButton />
              </div>
            )}

            {error && <p className="text-xs text-danger">{error}</p>}

            {walletAddress && (
              <button
                type="button"
                onClick={handleBuy}
                disabled={!selectedPack || busy}
                className="gradient-action rounded-full py-3 text-sm font-semibold disabled:opacity-40"
              >
                {phase === "preparing" && t("shop.preparing")}
                {phase === "awaiting-wallet" && t("shop.awaitingWallet")}
                {phase === "verifying" && t("shop.verifying")}
                {phase === "idle" &&
                  selectedPack &&
                  t("shop.buy", { price: selectedPack.price_ton })}
              </button>
            )}
          </>
        )}
      </div>
    </div>
  );
}
