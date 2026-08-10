"use client";

import { useEffect, useState } from "react";
import {
  Shield,
  Crown,
  Trophy,
  Coins,
  Users,
  Skull,
  Flame,
  Swords,
  Ghost,
  Anchor,
  Search,
  Plus,
  LogOut,
  X,
  UserPlus,
  UserMinus,
  ArrowUp,
  ArrowDown,
  HandCoins,
  Sparkles,
  Gem,
  type LucideIcon,
} from "lucide-react";
import type { GangAvatarId, GangCosmeticFields, GangListEntry, GangMember, GangRole, PlayerState } from "@/lib/types";
import {
  CO_LEADER_SLOT_COST,
  GANG_AVATAR_IDS,
  GANG_CREATION_COST,
  GANG_SLOT_PACK_COST,
  GANG_SLOT_PACK_SIZE,
  VIP_TREASURY_COST,
} from "@/lib/gang-avatars";
import { gangGlowClassName } from "@/lib/gang-cosmetics";
import {
  createGang,
  disbandGang,
  distributeDividends,
  donateToGangBank,
  fetchGangs,
  joinGang,
  kickGangMember,
  leaveGang,
  purchaseCoLeaderSlot,
  purchaseVipTreasury,
  setGangMemberRole,
  upgradeGangCapacity,
  ApiError,
} from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";
import { DistrictMapScreen } from "./district-map-screen";
import { GangCustomizationScreen } from "./gang-customization-screen";

/** avatar_id -> emblem icon + accent color. Keep in sync with GANG_AVATAR_IDS (src/lib/gang-avatars.ts). Exported for district-map-screen.tsx's controlling-gang/leaderboard badges. */
export const GANG_AVATARS: Record<GangAvatarId, { Icon: LucideIcon; className: string }> = {
  default_gang: { Icon: Users, className: "text-purple-300" },
  skull: { Icon: Skull, className: "text-red-400" },
  crown: { Icon: Crown, className: "text-amber-400" },
  flame: { Icon: Flame, className: "text-orange-400" },
  shield: { Icon: Shield, className: "text-sky-400" },
  swords: { Icon: Swords, className: "text-slate-300" },
  ghost: { Icon: Ghost, className: "text-violet-400" },
  anchor: { Icon: Anchor, className: "text-cyan-400" },
};

/** `cosmetics` (premium_avatar_id/frame_id) draws a gold/neon ring around gangs that bought customization — see gang-cosmetics.ts. Purely decorative, never changes the underlying emblem icon (no per-cosmetic art in this MVP). */
export function GangAvatar({
  avatarId,
  cosmetics,
  sizeClassName = "h-12 w-12",
  iconClassName = "h-6 w-6",
}: {
  avatarId: GangAvatarId;
  cosmetics?: Partial<GangCosmeticFields> | null;
  sizeClassName?: string;
  iconClassName?: string;
}) {
  const { Icon, className } = GANG_AVATARS[avatarId] ?? GANG_AVATARS.default_gang;
  return (
    <div
      className={`${sizeClassName} flex shrink-0 items-center justify-center rounded-full border border-purple-900/40 bg-slate-900/80 ${gangGlowClassName(cosmetics)}`}
    >
      <Icon className={`${iconClassName} ${className}`} />
    </div>
  );
}

function RoleBadge({ role }: { role: GangRole }) {
  const { t } = useLanguage();
  if (role === "leader") {
    return (
      <span className="flex items-center gap-1 rounded-full bg-amber-500/15 px-2 py-0.5 text-[10px] font-semibold text-amber-400">
        <Crown className="h-3 w-3 shrink-0" />
        {t("gangs.roleLeader")}
      </span>
    );
  }
  if (role === "co_leader") {
    return (
      <span className="flex items-center gap-1 rounded-full bg-purple-500/15 px-2 py-0.5 text-[10px] font-semibold text-purple-300">
        <Shield className="h-3 w-3 shrink-0" />
        {t("gangs.roleCoLeader")}
      </span>
    );
  }
  return (
    <span className="rounded-full bg-white/5 px-2 py-0.5 text-[10px] font-semibold text-nav-inactive">
      {t("gangs.roleMember")}
    </span>
  );
}

/** Maps known RPC error codes to a translated message, falling back to the generic "try again" copy for anything else. */
function gangErrorMessage(err: unknown, t: ReturnType<typeof useLanguage>["t"]): string {
  const code = err instanceof ApiError ? err.code : null;
  switch (code) {
    case "name_taken":
      return t("gangs.nameTaken");
    case "invalid_name_length":
      return t("gangs.invalidNameLength");
    case "invalid_name_chars":
      return t("gangs.invalidNameChars");
    case "insufficient_balance":
      return t("gangs.insufficientBalance");
    case "gang_full":
      return t("gangs.full");
    case "leader_cannot_leave":
      return t("gangs.leaderCannotLeave");
    case "amount_too_low":
      return t("gangs.invalidAmount");
    case "insufficient_gang_bank":
      return t("gangs.insufficientGangBank");
    default:
      return t("gangs.actionFailed");
  }
}

/** Bottom-sheet modal for founding a gang — name + emblem picker. Mirrors history-modal.tsx's shell. */
function CreateGangModal({
  balance,
  onClose,
  onCreated,
}: {
  balance: number;
  onClose: () => void;
  onCreated: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const [name, setName] = useState("");
  const [avatarId, setAvatarId] = useState<GangAvatarId>("default_gang");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const trimmed = name.trim();
  const validLength = trimmed.length >= 3 && trimmed.length <= 15;
  const canSubmit = validLength && balance >= GANG_CREATION_COST && !submitting;

  async function handleSubmit() {
    if (!canSubmit) return;
    setSubmitting(true);
    setError(null);
    try {
      const { state } = await createGang(trimmed, avatarId);
      onCreated(state);
      onClose();
    } catch (err) {
      setError(gangErrorMessage(err, t));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end bg-black/60" onClick={onClose}>
      <div
        className="flex max-h-[85vh] flex-col gap-4 rounded-t-2xl bg-nav p-4"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between">
          <h2 className="flex items-center gap-1.5 text-base font-semibold">
            <Shield className="h-4 w-4 text-amber-400" />
            {t("gangs.createModalTitle")}
          </h2>
          <button type="button" onClick={onClose} className="text-nav-inactive" aria-label={t("common.back")}>
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="flex flex-col gap-2 overflow-y-auto">
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            maxLength={15}
            placeholder={t("gangs.namePlaceholder")}
            className={`rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none ring-1 transition-colors ${
              trimmed.length > 0 && !validLength ? "ring-danger" : "ring-transparent"
            }`}
          />
          <p className="text-[11px] text-nav-inactive">{t("gangs.nameHint")}</p>

          <p className="mt-2 text-xs font-semibold text-nav-inactive">{t("gangs.avatarLabel")}</p>
          <div className="grid grid-cols-4 gap-2">
            {GANG_AVATAR_IDS.map((id) => (
              <button
                key={id}
                type="button"
                onClick={() => setAvatarId(id)}
                className={`flex items-center justify-center rounded-xl border p-2 transition-colors ${
                  avatarId === id
                    ? "border-amber-500/60 bg-amber-500/10 shadow-[0_0_18px_rgba(245,158,11,0.18)]"
                    : "border-purple-900/40 bg-black/20"
                }`}
              >
                <GangAvatar avatarId={id} sizeClassName="h-10 w-10" iconClassName="h-5 w-5" />
              </button>
            ))}
          </div>

          {balance < GANG_CREATION_COST && (
            <p className="mt-1 text-xs text-danger">
              {t("gangs.createNeedBalance", { cost: GANG_CREATION_COST })}
            </p>
          )}
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>

        <div className="flex gap-2">
          <button
            type="button"
            onClick={onClose}
            className="flex-1 rounded-full bg-progress-bg py-3 text-sm font-semibold text-nav-inactive"
          >
            {t("gangs.cancel")}
          </button>
          <button
            type="button"
            onClick={handleSubmit}
            disabled={!canSubmit}
            className="gradient-action flex-[2] rounded-full py-3 text-sm font-semibold disabled:opacity-40"
          >
            {submitting ? t("gangs.creating") : t("gangs.create", { cost: GANG_CREATION_COST })}
          </button>
        </div>
      </div>
    </div>
  );
}

/** Bottom-sheet modal for topping up the gang's bank from the caller's own GRAM balance. Mirrors CreateGangModal's shell. */
function DonateModal({
  balance,
  onClose,
  onDonated,
}: {
  balance: number;
  onClose: () => void;
  onDonated: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const [amount, setAmount] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const parsed = Number(amount);
  const validAmount = amount.trim().length > 0 && Number.isFinite(parsed) && parsed > 0;
  const canSubmit = validAmount && parsed <= balance && !submitting;

  async function handleSubmit() {
    if (!canSubmit) return;
    setSubmitting(true);
    setError(null);
    try {
      const { state } = await donateToGangBank(parsed);
      onDonated(state);
      onClose();
    } catch (err) {
      setError(gangErrorMessage(err, t));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end bg-black/60" onClick={onClose}>
      <div
        className="flex max-h-[85vh] flex-col gap-4 rounded-t-2xl bg-nav p-4"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between">
          <h2 className="flex items-center gap-1.5 text-base font-semibold">
            <HandCoins className="h-4 w-4 text-amber-400" />
            {t("gangs.donateModalTitle")}
          </h2>
          <button type="button" onClick={onClose} className="text-nav-inactive" aria-label={t("common.back")}>
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="flex flex-col gap-2">
          <input
            type="number"
            inputMode="decimal"
            min={0}
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder={t("gangs.donateAmountPlaceholder")}
            className={`rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none ring-1 transition-colors ${
              validAmount && parsed > balance ? "ring-danger" : "ring-transparent"
            }`}
          />
          {validAmount && parsed > balance && (
            <p className="text-xs text-danger">{t("gangs.insufficientBalance")}</p>
          )}
          {error && <p className="text-xs text-danger">{error}</p>}
        </div>

        <div className="flex gap-2">
          <button
            type="button"
            onClick={onClose}
            className="flex-1 rounded-full bg-progress-bg py-3 text-sm font-semibold text-nav-inactive"
          >
            {t("gangs.cancel")}
          </button>
          <button
            type="button"
            onClick={handleSubmit}
            disabled={!canSubmit}
            className="gradient-action flex-[2] rounded-full py-3 text-sm font-semibold disabled:opacity-40"
          >
            {submitting ? t("gangs.donating") : t("gangs.donateCta")}
          </button>
        </div>
      </div>
    </div>
  );
}

function GangListRow({
  gang,
  onJoin,
  joining,
}: {
  gang: GangListEntry;
  onJoin: ((id: string) => void) | null;
  joining: boolean;
}) {
  const { t } = useLanguage();
  const isFull = gang.member_count >= gang.max_members;

  return (
    <div
      className={`flex items-center gap-3 rounded-xl border p-3 ${
        gang.is_mine
          ? "border-amber-500/50 bg-amber-500/10 shadow-[0_0_18px_rgba(245,158,11,0.14)]"
          : "border-purple-900/40 bg-slate-900/80"
      }`}
    >
      <GangAvatar avatarId={gang.avatar_id} cosmetics={gang} sizeClassName="h-11 w-11" iconClassName="h-5 w-5" />
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-semibold">{gang.name}</p>
        <div className="flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[11px] text-nav-inactive">
          <span className="flex items-center gap-1">
            <Trophy className="h-3 w-3 shrink-0 text-amber-400" />
            {t("gangs.level", { level: gang.level })}
          </span>
          <span>{t("gangs.membersCount", { count: gang.member_count, max: gang.max_members })}</span>
        </div>
      </div>
      {onJoin && (
        <button
          type="button"
          onClick={() => onJoin(gang.id)}
          disabled={isFull || joining}
          className="gradient-action shrink-0 rounded-full px-3 py-1.5 text-xs font-semibold disabled:opacity-40"
        >
          {isFull ? t("gangs.full") : t("gangs.join")}
        </button>
      )}
    </div>
  );
}

/** Shared list fetch — powers both the browse-to-join screen and the ranking table, same get_gangs ordering either way. */
function useGangList() {
  const [entries, setEntries] = useState<GangListEntry[] | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    fetchGangs()
      .then((data) => {
        if (!cancelled) setEntries(data);
      })
      .catch(() => {
        if (!cancelled) setEntries([]);
      });
    return () => {
      cancelled = true;
    };
  }, [reloadKey]);

  return { entries, reload: () => setReloadKey((k) => k + 1) };
}

function GangsWithoutOne({
  balance,
  onStateChange,
}: {
  balance: number;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const { entries, reload } = useGangList();
  const [query, setQuery] = useState("");
  const [modalOpen, setModalOpen] = useState(false);
  const [joiningId, setJoiningId] = useState<string | null>(null);
  const [joinError, setJoinError] = useState<string | null>(null);

  const filtered = entries?.filter((g) => g.name.toLowerCase().includes(query.trim().toLowerCase())) ?? null;

  async function handleJoin(gangId: string) {
    setJoiningId(gangId);
    setJoinError(null);
    try {
      const { state } = await joinGang(gangId);
      onStateChange(state);
    } catch (err) {
      setJoinError(gangErrorMessage(err, t));
      reload();
    } finally {
      setJoiningId(null);
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-5 overflow-y-auto p-4 pb-24">
      <div className="gradient-surface flex flex-col items-center gap-2 rounded-2xl border border-purple-900/40 p-5 text-center shadow-[0_0_24px_rgba(147,51,234,0.1)]">
        <Shield className="h-8 w-8 text-amber-400" />
        <h1 className="text-lg font-bold">{t("gangs.title")}</h1>
        <button
          type="button"
          onClick={() => setModalOpen(true)}
          disabled={balance < GANG_CREATION_COST}
          className="gradient-action mt-2 flex items-center gap-1.5 rounded-full px-5 py-3 text-sm font-semibold disabled:opacity-40"
        >
          <Plus className="h-4 w-4 shrink-0" />
          {t("gangs.createCta", { cost: GANG_CREATION_COST })}
        </button>
        {balance < GANG_CREATION_COST && (
          <p className="text-xs text-danger">{t("gangs.createNeedBalance", { cost: GANG_CREATION_COST })}</p>
        )}
      </div>

      <div className="flex flex-col gap-2">
        <h2 className="flex items-center gap-1.5 px-1 text-xs font-semibold text-nav-inactive">
          <Trophy className="h-3.5 w-3.5 shrink-0" />
          {t("gangs.browseTitle")}
        </h2>
        <div className="relative">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-nav-inactive rtl:right-3 rtl:left-auto" />
          <input
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={t("gangs.searchPlaceholder")}
            className="w-full rounded-lg bg-progress-bg py-2 pl-9 pr-3 text-sm outline-none rtl:pl-3 rtl:pr-9"
          />
        </div>

        {joinError && <p className="text-xs text-danger">{joinError}</p>}

        {filtered === null && <p className="p-3 text-center text-sm text-nav-inactive">{t("common.loading")}</p>}
        {filtered?.length === 0 && <p className="p-3 text-center text-sm text-nav-inactive">{t("gangs.empty")}</p>}

        <div className="flex flex-col gap-2">
          {filtered?.map((gang) => (
            <GangListRow key={gang.id} gang={gang} onJoin={handleJoin} joining={joiningId === gang.id} />
          ))}
        </div>
      </div>

      {modalOpen && (
        <CreateGangModal
          balance={balance}
          onClose={() => setModalOpen(false)}
          onCreated={onStateChange}
        />
      )}
    </div>
  );
}

/**
 * `management` is only passed for the leader's own view, and only for rows
 * other than the leader's own (see the `member.role !== "leader"` filter at
 * the call site) — set_gang_member_role/kick_gang_member both reject
 * retargeting the leader server-side regardless, this just keeps the
 * buttons from ever showing where they'd only bounce.
 */
function GangMemberRow({
  member,
  management,
}: {
  member: GangMember;
  management?: {
    busy: boolean;
    onPromote: (userId: string) => void;
    onDemote: (userId: string) => void;
    onKick: (userId: string, displayName: string) => void;
  };
}) {
  const { t } = useLanguage();
  return (
    <div className="flex items-center gap-3 p-3 text-sm">
      <div className="flex h-9 w-9 shrink-0 items-center justify-center overflow-hidden rounded-full bg-progress-bg">
        {member.photo_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={member.photo_url} alt="" className="h-full w-full object-cover" />
        ) : (
          <span className="text-sm font-bold">{member.display_name.charAt(0).toUpperCase()}</span>
        )}
      </div>
      <span className="flex-1 truncate">{member.display_name}</span>
      <RoleBadge role={member.role} />
      {management && (
        <div className="flex shrink-0 items-center gap-1">
          {member.role === "co_leader" ? (
            <button
              type="button"
              onClick={() => management.onDemote(member.user_id)}
              disabled={management.busy}
              aria-label={t("gangs.demote")}
              className="rounded-full bg-progress-bg p-1.5 text-nav-inactive disabled:opacity-40"
            >
              <ArrowDown className="h-3.5 w-3.5" />
            </button>
          ) : (
            <button
              type="button"
              onClick={() => management.onPromote(member.user_id)}
              disabled={management.busy}
              aria-label={t("gangs.promote")}
              className="rounded-full bg-progress-bg p-1.5 text-nav-inactive disabled:opacity-40"
            >
              <ArrowUp className="h-3.5 w-3.5" />
            </button>
          )}
          <button
            type="button"
            onClick={() => management.onKick(member.user_id, member.display_name)}
            disabled={management.busy}
            aria-label={t("gangs.kick")}
            className="rounded-full bg-danger/10 p-1.5 text-danger disabled:opacity-40"
          >
            <UserMinus className="h-3.5 w-3.5" />
          </button>
        </div>
      )}
    </div>
  );
}

function GangWithOne({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const gang = state.gang!;
  const { entries } = useGangList();
  const [tabView, setTabView] = useState<"members" | "treasury" | "customization" | "top">("members");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [donateOpen, setDonateOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  const [dividendAmount, setDividendAmount] = useState("");
  const [dividendSubmitting, setDividendSubmitting] = useState(false);
  const [dividendError, setDividendError] = useState<string | null>(null);
  const [slotSubmitting, setSlotSubmitting] = useState(false);
  const [vipSubmitting, setVipSubmitting] = useState(false);
  const botUsername = process.env.NEXT_PUBLIC_BOT_USERNAME;
  const inviteLink = botUsername ? `https://t.me/${botUsername}?startapp=gang_${gang.id}` : null;

  const progressPercent = Math.min(100, Math.round((gang.exp_into_level / gang.exp_per_level) * 100));

  async function handleCopyInvite() {
    if (!inviteLink) return;
    await navigator.clipboard.writeText(inviteLink);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  async function handlePromote(userId: string) {
    setBusy(true);
    setError(null);
    try {
      const { state: next } = await setGangMemberRole(userId, "co_leader");
      onStateChange(next);
    } catch (err) {
      setError(gangErrorMessage(err, t));
    } finally {
      setBusy(false);
    }
  }

  async function handleDemote(userId: string) {
    setBusy(true);
    setError(null);
    try {
      const { state: next } = await setGangMemberRole(userId, "member");
      onStateChange(next);
    } catch (err) {
      setError(gangErrorMessage(err, t));
    } finally {
      setBusy(false);
    }
  }

  async function handleKick(userId: string, displayName: string) {
    if (!confirm(t("gangs.kickConfirm", { name: displayName }))) return;
    setBusy(true);
    setError(null);
    try {
      const { state: next } = await kickGangMember(userId);
      onStateChange(next);
    } catch (err) {
      setError(gangErrorMessage(err, t));
    } finally {
      setBusy(false);
    }
  }

  async function handleUpgradeCapacity() {
    setBusy(true);
    setError(null);
    try {
      const { state: next } = await upgradeGangCapacity();
      onStateChange(next);
    } catch (err) {
      setError(gangErrorMessage(err, t));
    } finally {
      setBusy(false);
    }
  }

  const dividendParsed = Number(dividendAmount);
  const dividendValid = dividendAmount.trim().length > 0 && Number.isFinite(dividendParsed) && dividendParsed > 0;

  async function handleDistributeDividends() {
    if (!dividendValid) return;
    setDividendSubmitting(true);
    setDividendError(null);
    try {
      const { state: next } = await distributeDividends(dividendParsed);
      onStateChange(next);
      setDividendAmount("");
    } catch (err) {
      setDividendError(gangErrorMessage(err, t));
    } finally {
      setDividendSubmitting(false);
    }
  }

  async function handlePurchaseCoLeaderSlot() {
    setSlotSubmitting(true);
    setError(null);
    try {
      const { state: next } = await purchaseCoLeaderSlot();
      onStateChange(next);
    } catch (err) {
      setError(gangErrorMessage(err, t));
    } finally {
      setSlotSubmitting(false);
    }
  }

  async function handlePurchaseVipTreasury() {
    setVipSubmitting(true);
    setError(null);
    try {
      const { state: next } = await purchaseVipTreasury();
      onStateChange(next);
    } catch (err) {
      setError(gangErrorMessage(err, t));
    } finally {
      setVipSubmitting(false);
    }
  }

  async function handleLeave() {
    if (!confirm(t("gangs.leaveConfirm"))) return;
    setBusy(true);
    setError(null);
    try {
      const { state: next } = await leaveGang();
      onStateChange(next);
    } catch (err) {
      setError(gangErrorMessage(err, t));
    } finally {
      setBusy(false);
    }
  }

  async function handleDisband() {
    if (!confirm(t("gangs.disbandConfirm"))) return;
    setBusy(true);
    setError(null);
    try {
      const { state: next } = await disbandGang();
      onStateChange(next);
    } catch (err) {
      setError(gangErrorMessage(err, t));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4 pb-24">
      <div className="gradient-surface flex flex-col gap-3 rounded-2xl border border-purple-900/40 p-4 shadow-[0_0_24px_rgba(147,51,234,0.1)]">
        <div className="flex items-center gap-3">
          <GangAvatar avatarId={gang.avatar_id} cosmetics={gang} sizeClassName="h-14 w-14" iconClassName="h-7 w-7" />
          <div className="min-w-0 flex-1">
            <h1 className="truncate text-lg font-bold">{gang.name}</h1>
            <p className="flex items-center gap-1 text-xs text-nav-inactive">
              <Crown className="h-3.5 w-3.5 shrink-0 text-amber-400" />
              {t("gangs.leaderLabel")}: {gang.leader_name}
            </p>
          </div>
          <span className="flex shrink-0 items-center gap-1 rounded-full bg-progress-bg px-2.5 py-1 text-xs font-semibold text-amber-400">
            <Trophy className="h-3.5 w-3.5 shrink-0" />
            {t("gangs.level", { level: gang.level })}
          </span>
        </div>

        <div className="flex flex-col gap-1">
          <div className="flex items-center justify-between text-[11px] text-nav-inactive">
            <span>EXP</span>
            <span>
              {gang.exp_into_level} / {gang.exp_per_level}
            </span>
          </div>
          <div className="h-1.5 w-full overflow-hidden rounded-full bg-progress-bg">
            <div
              className="h-full rounded-full bg-gradient-to-r from-purple-500 to-amber-400 transition-all"
              style={{ width: `${progressPercent}%` }}
            />
          </div>
        </div>

        {gang.target_district_name && (
          <p className="flex items-center gap-1.5 text-xs text-nav-inactive">
            <Swords className="h-3.5 w-3.5 shrink-0 text-red-400" />
            {t("gangs.attackingDistrict", { name: gang.target_district_name })}
          </p>
        )}

        <div className="rounded-2xl border border-purple-900/40 bg-slate-900/80 p-3 text-sm">
          <div className="grid grid-cols-2 gap-2">
            <div>
              <p className="text-[11px] text-nav-inactive">{t("gangs.bankBalance")}</p>
              <p className="text-lg font-semibold text-gram">{gang.bank_balance_gram.toFixed(2)}</p>
              <p className="text-xs text-nav-inactive">{t("common.gram")}</p>
            </div>
            <div>
              <p className="text-[11px] text-nav-inactive">{t("gangs.bankCurrency")}</p>
              <p className="text-lg font-semibold text-gram">{gang.bank_balance_ton.toFixed(2)}</p>
              <p className="text-xs text-nav-inactive">{t("common.gram")}</p>
            </div>
          </div>
          <button
            type="button"
            onClick={() => setDonateOpen(true)}
            className="mt-2 flex w-full items-center justify-center gap-1.5 rounded-full bg-progress-bg py-2 text-xs font-semibold text-gram"
          >
            <HandCoins className="h-3.5 w-3.5 shrink-0" />
            {t("gangs.donate")}
          </button>
        </div>

        <div className="grid grid-cols-2 gap-2">
          <div className="rounded-2xl border border-purple-900/40 bg-slate-900/80 p-3 text-sm">
            <p className="text-[11px] text-nav-inactive">{t("gangs.topDonors")}</p>
            {gang.bank_top_donors.length === 0 ? (
              <p className="mt-2 text-xs text-nav-inactive">{t("gangs.noDonors")}</p>
            ) : (
              <div className="mt-2 space-y-2">
                {gang.bank_top_donors.slice(0, 3).map((donor) => (
                  <div key={donor.user_id} className="flex items-center justify-between text-xs">
                    <span className="truncate">{donor.display_name}</span>
                    <span className="font-semibold text-gram">{donor.amount.toFixed(2)}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
          <div className="rounded-2xl border border-purple-900/40 bg-slate-900/80 p-3 text-sm">
            <p className="text-[11px] text-nav-inactive">{t("gangs.recentBankTransactions")}</p>
            {gang.bank_transactions.length === 0 ? (
              <p className="mt-2 text-xs text-nav-inactive">{t("gangs.noTransactions")}</p>
            ) : (
              <div className="mt-2 space-y-2">
                {gang.bank_transactions.slice(0, 3).map((tx) => (
                  <div key={tx.id} className="flex items-center justify-between text-xs">
                    <span className="truncate">{tx.display_name}</span>
                    <span className="font-semibold text-gram">{tx.amount_gram.toFixed(2)}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>

        <div className="flex items-center justify-between gap-2">
          <p className="flex items-center gap-1.5 text-xs text-nav-inactive">
            <Coins className="h-3.5 w-3.5 shrink-0 text-amber-400" />
            {t("gangs.membersCount", { count: gang.members.length, max: gang.max_members })}
          </p>
          {gang.my_role === "leader" && (
            <button
              type="button"
              onClick={handleUpgradeCapacity}
              disabled={busy || gang.bank_balance_gram < GANG_SLOT_PACK_COST}
              className="flex shrink-0 items-center gap-1 rounded-full bg-progress-bg px-2.5 py-1 text-[11px] font-semibold text-gram disabled:opacity-40"
            >
              <Plus className="h-3 w-3 shrink-0" />
              {t("gangs.upgradeCapacity", { slots: GANG_SLOT_PACK_SIZE, cost: GANG_SLOT_PACK_COST })}
            </button>
          )}
        </div>
      </div>

      <button
        type="button"
        onClick={handleCopyInvite}
        disabled={!inviteLink}
        className="gradient-action flex items-center justify-center gap-1.5 rounded-full py-3 text-sm font-semibold disabled:opacity-40"
      >
        {!copied && <UserPlus className="h-4 w-4" />}
        {copied ? t("gangs.copied") : t("gangs.invite")}
      </button>

      <div className="flex gap-1.5">
        {(["members", "treasury", "customization", "top"] as const).map((view) => (
          <button
            key={view}
            type="button"
            onClick={() => setTabView(view)}
            className={`flex flex-1 items-center justify-center gap-1 rounded-full py-2 text-[11px] font-semibold transition-colors ${
              tabView === view ? "gradient-action" : "gradient-surface text-nav-inactive"
            }`}
          >
            {view === "members" && <Users className="h-3.5 w-3.5 shrink-0" />}
            {view === "treasury" && <HandCoins className="h-3.5 w-3.5 shrink-0" />}
            {view === "customization" && <Sparkles className="h-3.5 w-3.5 shrink-0" />}
            {view === "top" && <Trophy className="h-3.5 w-3.5 shrink-0" />}
            {view === "members"
              ? t("gangs.membersTitle")
              : view === "treasury"
                ? t("gangs.treasuryTitle")
                : view === "customization"
                  ? t("gangs.customizationTitle")
                  : t("gangs.topTitle")}
          </button>
        ))}
      </div>

      {tabView === "members" && (
        <div className="gradient-surface flex flex-col divide-y divide-white/5 rounded-xl">
          {gang.members.map((member) => (
            <GangMemberRow
              key={member.user_id}
              member={member}
              management={
                gang.my_role === "leader" && member.role !== "leader"
                  ? { busy, onPromote: handlePromote, onDemote: handleDemote, onKick: handleKick }
                  : undefined
              }
            />
          ))}
        </div>
      )}

      {tabView === "treasury" && (
        <div className="gradient-surface flex flex-col gap-3 rounded-2xl p-4">
          <p className="flex items-center gap-1.5 text-sm font-semibold">
            <HandCoins className="h-4 w-4 shrink-0 text-amber-400" />
            {t("gangs.dividendsTitle")}
          </p>
          <p className="text-xs text-nav-inactive">
            {t("gangs.dividendsHint", { count: gang.members.length })}
          </p>
          {gang.my_role === "leader" ? (
            <>
              <input
                type="number"
                inputMode="decimal"
                min={0}
                value={dividendAmount}
                onChange={(e) => setDividendAmount(e.target.value)}
                placeholder={t("gangs.donateAmountPlaceholder")}
                className={`rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none ring-1 transition-colors ${
                  dividendValid && dividendParsed > gang.bank_balance_gram ? "ring-danger" : "ring-transparent"
                }`}
              />
              {dividendValid && dividendParsed > gang.bank_balance_gram && (
                <p className="text-xs text-danger">{t("gangs.insufficientGangBank")}</p>
              )}
              {dividendError && <p className="text-xs text-danger">{dividendError}</p>}
              <button
                type="button"
                onClick={handleDistributeDividends}
                disabled={!dividendValid || dividendSubmitting}
                className="gradient-action rounded-full py-3 text-sm font-semibold disabled:opacity-40"
              >
                {dividendSubmitting ? t("gangs.donating") : t("gangs.dividendsCta")}
              </button>
            </>
          ) : (
            <p className="text-xs text-nav-inactive">{t("gangs.dividendsLeaderOnly")}</p>
          )}

          {gang.my_role === "leader" && (
            <div className="mt-2 flex flex-col gap-3 border-t border-white/5 pt-3">
              <div className="flex items-center justify-between gap-2">
                <div>
                  <p className="text-xs font-semibold">{t("gangs.coLeaderSlotsTitle")}</p>
                  <p className="text-[11px] text-nav-inactive">
                    {t("gangs.coLeaderSlotsHint", { count: gang.co_leader_slots })}
                  </p>
                </div>
                <button
                  type="button"
                  onClick={handlePurchaseCoLeaderSlot}
                  disabled={slotSubmitting || (state.wallet.balance ?? 0) < CO_LEADER_SLOT_COST}
                  className="shrink-0 rounded-full bg-progress-bg px-3 py-1.5 text-[11px] font-semibold text-gram disabled:opacity-40"
                >
                  {slotSubmitting ? t("gangs.buying") : t("gangs.buySlot", { cost: CO_LEADER_SLOT_COST })}
                </button>
              </div>

              <div className="flex items-center justify-between gap-2">
                <div>
                  <p className="flex items-center gap-1 text-xs font-semibold text-amber-300">
                    <Gem className="h-3.5 w-3.5 shrink-0" />
                    {t("gangs.vipTreasuryTitle")}
                  </p>
                  <p className="text-[11px] text-nav-inactive">
                    {gang.vip_treasury ? t("gangs.vipTreasuryActive") : t("gangs.vipTreasuryHint")}
                  </p>
                </div>
                {!gang.vip_treasury && (
                  <button
                    type="button"
                    onClick={handlePurchaseVipTreasury}
                    disabled={vipSubmitting || (state.wallet.balance ?? 0) < VIP_TREASURY_COST}
                    className="shrink-0 rounded-full bg-gradient-to-r from-amber-500 to-amber-300 px-3 py-1.5 text-[11px] font-semibold text-bg disabled:opacity-40"
                  >
                    {vipSubmitting ? t("gangs.buying") : t("gangs.unlockVip", { cost: VIP_TREASURY_COST })}
                  </button>
                )}
              </div>
            </div>
          )}
        </div>
      )}

      {tabView === "customization" && (
        <GangCustomizationScreen gang={gang} balance={state.wallet.balance ?? 0} onStateChange={onStateChange} />
      )}

      {tabView === "top" && (
        <div className="flex flex-col gap-2">
          {entries === null && <p className="p-3 text-center text-sm text-nav-inactive">{t("common.loading")}</p>}
          {entries?.map((g) => (
            <GangListRow key={g.id} gang={g} onJoin={null} joining={false} />
          ))}
        </div>
      )}

      {error && <p className="text-center text-xs text-danger">{error}</p>}

      {gang.my_role === "leader" ? (
        <button
          type="button"
          onClick={handleDisband}
          disabled={busy}
          className="flex items-center justify-center gap-1.5 rounded-full border border-danger/40 py-3 text-sm font-semibold text-danger disabled:opacity-40"
        >
          <LogOut className="h-4 w-4 shrink-0" />
          {busy ? t("gangs.disbanding") : t("gangs.disband")}
        </button>
      ) : (
        <button
          type="button"
          onClick={handleLeave}
          disabled={busy}
          className="flex items-center justify-center gap-1.5 rounded-full border border-danger/40 py-3 text-sm font-semibold text-danger disabled:opacity-40"
        >
          <LogOut className="h-4 w-4 shrink-0" />
          {busy ? t("gangs.leaving") : t("gangs.leave")}
        </button>
      )}

      {donateOpen && (
        <DonateModal
          balance={state.wallet.balance ?? 0}
          onClose={() => setDonateOpen(false)}
          onDonated={onStateChange}
        />
      )}
    </div>
  );
}

export function GangsScreen({
  state,
  onStateChange,
}: {
  state: PlayerState;
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const [view, setView] = useState<"gang" | "districts">("gang");
  const balance = state.wallet.balance ?? 0;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex gap-2 p-4 pb-0">
        {(["gang", "districts"] as const).map((v) => (
          <button
            key={v}
            type="button"
            onClick={() => setView(v)}
            className={`flex flex-1 items-center justify-center gap-1.5 rounded-full py-2 text-xs font-semibold transition-colors ${
              view === v ? "gradient-action" : "gradient-surface text-nav-inactive"
            }`}
          >
            {v === "gang" ? <Shield className="h-3.5 w-3.5 shrink-0" /> : <Trophy className="h-3.5 w-3.5 shrink-0" />}
            {v === "gang" ? t("gangs.title") : t("districts.title")}
          </button>
        ))}
      </div>

      {view === "gang" ? (
        state.gang ? (
          <GangWithOne state={state} onStateChange={onStateChange} />
        ) : (
          <GangsWithoutOne balance={balance} onStateChange={onStateChange} />
        )
      ) : (
        <DistrictMapScreen state={state} onStateChange={onStateChange} />
      )}
    </div>
  );
}
