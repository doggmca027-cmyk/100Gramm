"use client";

import { useState } from "react";
import { Check, Lock, Save, UserPlus, Users, X } from "lucide-react";
import type { PlayerGang, PlayerState } from "@/lib/types";
import { respondGangJoinRequest, updateGangSettings, ApiError } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";
import { LANGUAGE_LOCALE } from "@/lib/i18n/types";

const DESCRIPTION_MAX_LENGTH = 200;

function settingsErrorMessage(err: unknown, t: ReturnType<typeof useLanguage>["t"]): string {
  const code = err instanceof ApiError ? err.code : null;
  switch (code) {
    case "invalid_price":
      return t("gangs.errInvalidPrice");
    case "description_too_long":
      return t("gangs.errDescriptionTooLong");
    case "invalid_description_chars":
      return t("gangs.invalidNameChars");
    case "not_gang_leader":
      return t("gangs.customizationLeaderOnly");
    case "requester_already_in_gang":
      return t("gangs.errRequesterAlreadyInGang");
    case "requester_insufficient_balance":
      return t("gangs.errRequesterInsufficientBalance");
    case "gang_full":
      return t("gangs.full");
    default:
      return t("gangs.actionFailed");
  }
}

/**
 * Leader-only tab (gated one level up — the "Settings" tab button itself
 * only renders for gang.my_role === 'leader', see gangs-screen.tsx) for
 * the three knobs update_gang_settings controls, plus the pending-
 * applications queue closed-gang membership feeds. Two independent forms
 * sharing one screen: saving settings never touches join_requests and
 * vice versa, so they're wired to onStateChange separately rather than
 * through one combined submit.
 */
export function GangSettingsScreen({
  gang,
  onStateChange,
}: {
  gang: PlayerGang;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t, lang } = useLanguage();
  const [isClosed, setIsClosed] = useState(gang.is_closed);
  const [priceInput, setPriceInput] = useState(String(gang.entry_price_gram || ""));
  const [description, setDescription] = useState(gang.description ?? "");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [respondingId, setRespondingId] = useState<string | null>(null);
  const [requestError, setRequestError] = useState<string | null>(null);

  const parsedPrice = Number(priceInput);
  const validPrice = priceInput.trim() === "" || (Number.isFinite(parsedPrice) && parsedPrice >= 0);

  function formatDate(iso: string): string {
    return new Date(iso).toLocaleString(LANGUAGE_LOCALE[lang], {
      day: "2-digit",
      month: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    });
  }

  async function handleSave() {
    if (!validPrice) return;
    setSubmitting(true);
    setError(null);
    setSaved(false);
    try {
      const { state } = await updateGangSettings({
        isClosed,
        entryPriceGram: priceInput.trim() === "" ? 0 : parsedPrice,
        description,
      });
      onStateChange(state);
      setSaved(true);
      setTimeout(() => setSaved(false), 2000);
    } catch (err) {
      setError(settingsErrorMessage(err, t));
    } finally {
      setSubmitting(false);
    }
  }

  async function handleRespond(requestId: string, approve: boolean) {
    setRespondingId(requestId);
    setRequestError(null);
    try {
      const { state } = await respondGangJoinRequest(requestId, approve);
      onStateChange(state);
    } catch (err) {
      setRequestError(settingsErrorMessage(err, t));
    } finally {
      setRespondingId(null);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="gradient-surface flex flex-col gap-3 rounded-2xl p-4">
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-2 text-sm font-semibold">
            {isClosed ? <Lock className="h-4 w-4 shrink-0 text-amber-400" /> : <UserPlus className="h-4 w-4 shrink-0 text-amber-400" />}
            {t("gangs.closedToggleLabel")}
          </div>
          <button
            type="button"
            role="switch"
            aria-checked={isClosed}
            onClick={() => setIsClosed((v) => !v)}
            className={`relative h-6 w-11 shrink-0 rounded-full transition-colors ${isClosed ? "bg-amber-500" : "bg-progress-bg"}`}
          >
            <span
              className={`absolute top-0.5 h-5 w-5 rounded-full bg-white transition-transform ${isClosed ? "translate-x-5 rtl:-translate-x-5" : "translate-x-0.5 rtl:-translate-x-0.5"}`}
            />
          </button>
        </div>
        <p className="text-xs text-nav-inactive">{t("gangs.closedToggleHint")}</p>

        <div className="flex flex-col gap-1">
          <label className="text-xs font-semibold text-nav-inactive">{t("gangs.entryPriceLabel")}</label>
          <input
            type="number"
            inputMode="decimal"
            min={0}
            value={priceInput}
            onChange={(e) => setPriceInput(e.target.value)}
            placeholder="0"
            className={`rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none ring-1 transition-colors ${
              !validPrice ? "ring-danger" : "ring-transparent"
            }`}
          />
          <p className="text-xs text-nav-inactive">{t("gangs.entryPriceHint")}</p>
        </div>

        <div className="flex flex-col gap-1">
          <label className="text-xs font-semibold text-nav-inactive">{t("gangs.descriptionLabel")}</label>
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value.slice(0, DESCRIPTION_MAX_LENGTH))}
            placeholder={t("gangs.descriptionPlaceholder")}
            rows={3}
            className="resize-none rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
          />
          <p className="text-right text-[10px] text-nav-inactive">
            {description.length} / {DESCRIPTION_MAX_LENGTH}
          </p>
        </div>

        {error && <p className="text-xs text-danger">{error}</p>}

        <button
          type="button"
          onClick={handleSave}
          disabled={submitting || !validPrice}
          className="gradient-action flex items-center justify-center gap-1.5 rounded-full py-2.5 text-sm font-semibold disabled:opacity-40"
        >
          <Save className="h-4 w-4 shrink-0" />
          {submitting ? t("gangs.saving") : saved ? t("gangs.saved") : t("gangs.saveSettings")}
        </button>
      </div>

      <div className="gradient-surface flex flex-col gap-2 rounded-2xl p-4">
        <p className="flex items-center gap-1.5 text-sm font-semibold">
          <Users className="h-4 w-4 shrink-0 text-amber-400" />
          {t("gangs.joinRequestsTitle")}
        </p>
        {requestError && <p className="text-xs text-danger">{requestError}</p>}
        {gang.join_requests.length === 0 ? (
          <p className="text-xs text-nav-inactive">{t("gangs.noJoinRequests")}</p>
        ) : (
          <div className="flex flex-col divide-y divide-white/5">
            {gang.join_requests.map((req) => (
              <div key={req.id} className="flex items-center gap-3 py-2.5 text-sm">
                <div className="flex h-9 w-9 shrink-0 items-center justify-center overflow-hidden rounded-full bg-progress-bg">
                  {req.photo_url ? (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img src={req.photo_url} alt="" className="h-full w-full object-cover" />
                  ) : (
                    <span className="text-sm font-bold">{req.display_name.charAt(0).toUpperCase()}</span>
                  )}
                </div>
                <div className="min-w-0 flex-1">
                  <p className="truncate">{req.display_name}</p>
                  <p className="text-[11px] text-nav-inactive">{formatDate(req.created_at)}</p>
                </div>
                <div className="flex shrink-0 items-center gap-1">
                  <button
                    type="button"
                    onClick={() => handleRespond(req.id, true)}
                    disabled={respondingId === req.id}
                    aria-label={t("gangs.approveRequest")}
                    className="rounded-full bg-profit/10 p-1.5 text-profit disabled:opacity-40"
                  >
                    <Check className="h-3.5 w-3.5" />
                  </button>
                  <button
                    type="button"
                    onClick={() => handleRespond(req.id, false)}
                    disabled={respondingId === req.id}
                    aria-label={t("gangs.rejectRequest")}
                    className="rounded-full bg-danger/10 p-1.5 text-danger disabled:opacity-40"
                  >
                    <X className="h-3.5 w-3.5" />
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
