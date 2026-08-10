"use client";

import { useEffect, useState } from "react";
import { Check, Frame as FrameIcon, Sparkles } from "lucide-react";
import type { GangCosmetic, PlayerGang, PlayerState } from "@/lib/types";
import { fetchGangCosmetics, purchaseGangCosmetic, ApiError } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";

function cosmeticErrorMessage(err: unknown, t: ReturnType<typeof useLanguage>["t"]): string {
  const code = err instanceof ApiError ? err.code : null;
  switch (code) {
    case "not_gang_leader":
      return t("gangs.customizationLeaderOnly");
    case "insufficient_balance":
      return t("gangs.insufficientBalance");
    case "cosmetic_not_found":
      return t("gangs.actionFailed");
    default:
      return t("gangs.actionFailed");
  }
}

/** Small circular preview swatch of a glow, independent of gang-cosmetics.ts's Tailwind classes (this needs to render for items the gang doesn't own yet, not just equipped ones). */
const GLOW_PREVIEW: Record<string, string> = {
  gold: "shadow-[0_0_10px_3px_rgba(250,204,21,0.6)] border-amber-400",
  diamond: "shadow-[0_0_10px_3px_rgba(103,232,249,0.6)] border-cyan-300",
  fire: "shadow-[0_0_10px_3px_rgba(251,146,60,0.6)] border-orange-400",
  neon_purple: "shadow-[0_0_10px_3px_rgba(192,132,252,0.6)] border-purple-400",
  neon_red: "shadow-[0_0_10px_3px_rgba(248,113,113,0.6)] border-red-400",
};

function CosmeticCard({
  cosmetic,
  equipped,
  canBuy,
  balance,
  submitting,
  onBuy,
}: {
  cosmetic: GangCosmetic;
  equipped: boolean;
  canBuy: boolean;
  balance: number;
  submitting: boolean;
  onBuy: (code: string) => void;
}) {
  const { t } = useLanguage();
  const affordable = balance >= cosmetic.price;

  return (
    <div
      className={`flex flex-col items-center gap-2 rounded-2xl border p-3 text-center ${
        equipped ? "border-amber-500/60 bg-amber-500/10" : "border-purple-900/40 bg-slate-900/80"
      }`}
    >
      <div
        className={`flex h-12 w-12 items-center justify-center rounded-full border-2 bg-progress-bg ${GLOW_PREVIEW[cosmetic.glow] ?? "border-purple-900/40"}`}
      >
        {cosmetic.cosmetic_type === "avatar" ? (
          <Sparkles className="h-5 w-5 text-amber-300" />
        ) : (
          <FrameIcon className="h-5 w-5 text-amber-300" />
        )}
      </div>
      <p className="text-xs font-semibold">{cosmetic.name}</p>
      {equipped ? (
        <span className="flex items-center gap-1 rounded-full bg-amber-500/15 px-2 py-0.5 text-[10px] font-semibold text-amber-400">
          <Check className="h-3 w-3 shrink-0" />
          {t("gangs.equipped")}
        </span>
      ) : (
        <button
          type="button"
          onClick={() => onBuy(cosmetic.code)}
          disabled={!canBuy || !affordable || submitting}
          className="w-full rounded-full bg-progress-bg py-1.5 text-[11px] font-semibold text-gram disabled:opacity-40"
        >
          {submitting ? t("gangs.buying") : t("gangs.buyFor", { cost: cosmetic.price })}
        </button>
      )}
    </div>
  );
}

export function GangCustomizationScreen({
  gang,
  balance,
  onStateChange,
}: {
  gang: PlayerGang;
  balance: number;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const [catalog, setCatalog] = useState<GangCosmetic[] | null>(null);
  const [buyingCode, setBuyingCode] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetchGangCosmetics()
      .then(setCatalog)
      .catch(() => setCatalog([]));
  }, []);

  const canBuy = gang.my_role === "leader";

  async function handleBuy(code: string) {
    setBuyingCode(code);
    setError(null);
    try {
      const { state } = await purchaseGangCosmetic(code);
      onStateChange(state);
    } catch (err) {
      setError(cosmeticErrorMessage(err, t));
    } finally {
      setBuyingCode(null);
    }
  }

  const avatars = catalog?.filter((c) => c.cosmetic_type === "avatar") ?? [];
  const frames = catalog?.filter((c) => c.cosmetic_type === "frame") ?? [];

  return (
    <div className="flex flex-col gap-4">
      <p className="px-1 text-xs text-nav-inactive">{t("gangs.customizationSubtitle")}</p>
      {!canBuy && <p className="px-1 text-xs text-nav-inactive">{t("gangs.customizationLeaderOnly")}</p>}
      {error && <p className="px-1 text-xs text-danger">{error}</p>}

      {catalog === null ? (
        <p className="p-3 text-center text-sm text-nav-inactive">{t("common.loading")}</p>
      ) : (
        <>
          <div className="flex flex-col gap-2">
            <p className="px-1 text-xs font-semibold text-nav-inactive">{t("gangs.premiumAvatars")}</p>
            <div className="grid grid-cols-3 gap-2">
              {avatars.map((c) => (
                <CosmeticCard
                  key={c.code}
                  cosmetic={c}
                  equipped={gang.premium_avatar_id === c.code}
                  canBuy={canBuy}
                  balance={balance}
                  submitting={buyingCode === c.code}
                  onBuy={handleBuy}
                />
              ))}
            </div>
          </div>

          <div className="flex flex-col gap-2">
            <p className="px-1 text-xs font-semibold text-nav-inactive">{t("gangs.neonFrames")}</p>
            <div className="grid grid-cols-3 gap-2">
              {frames.map((c) => (
                <CosmeticCard
                  key={c.code}
                  cosmetic={c}
                  equipped={gang.frame_id === c.code}
                  canBuy={canBuy}
                  balance={balance}
                  submitting={buyingCode === c.code}
                  onBuy={handleBuy}
                />
              ))}
            </div>
          </div>
        </>
      )}
    </div>
  );
}
