"use client";

import { useState } from "react";
import Image from "next/image";
import { Handshake, CheckCircle2, Hourglass, Gift, type LucideIcon } from "lucide-react";
import { openTelegramLink } from "@telegram-apps/sdk-react";
import type { PartnerTask, PlayerState } from "@/lib/types";
import { checkPartnerTaskSubscription, createExternalTaskClick, ApiError } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";
import { formatGramAmount } from "@/lib/format-gram";
import { ITEM_ICON, itemNameKey } from "@/lib/combo-items";
import { useCountdown, formatDuration, useDurationUnits } from "@/hooks/use-countdown";

// "awaiting_partner" only exists client-side, for external_api tasks: there
// is no player-triggered check for these (unlike telegram_channel's
// checking/pending), completion is entirely driven by the partner's own
// postback to /api/partner/callback/[slug] — this is just "we opened their
// app, now we wait", reset to "todo" on remount since the server has
// nothing to resume it from besides completed itself.
type Stage = "todo" | "checking" | "pending" | "awaiting_partner" | "done";

// Placeholder for useCountdown when there's no available_at yet — avoids
// computing `new Date()` (impure) during render just to produce an unused
// fallback, same idiom as product-card.tsx's EPOCH.
const EPOCH = "1970-01-01T00:00:00.000Z";

function initialStage(task: PartnerTask): Stage {
  if (task.completed) return "done";
  if (task.available_at) return "pending";
  return "todo";
}

function TaskCard({
  task,
  onClaimed,
}: {
  task: PartnerTask;
  onClaimed: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const units = useDurationUnits();
  const ItemIcon = task.reward_item_type ? (ITEM_ICON[task.reward_item_type] ?? Gift) : null;
  const [stage, setStage] = useState<Stage>(() => initialStage(task));
  const [availableAt, setAvailableAt] = useState<string | null>(task.available_at);
  const [loading, setLoading] = useState(false);
  const [errorText, setErrorText] = useState<string | null>(null);

  // Derived, not synced via effect: task.completed always wins over
  // whatever the local `stage` happens to be. Matters most for
  // external_api tasks, where completion is entirely driven by the
  // partner's async postback, not a click the player made just now —
  // without this, a card stuck showing "awaiting_partner" (stage only
  // ever transitions from the player's own actions) would never notice
  // the reward was already paid on a background state refresh, and
  // re-tapping "Выполнить" would just hit already_claimed.
  const effectiveStage: Stage = task.completed ? "done" : stage;

  // Ticks down to 0 once available_at passes — the button unlocks itself,
  // no need for the user to reopen the app.
  const remaining = useCountdown(availableAt ?? EPOCH);
  const waiting = effectiveStage === "pending" && remaining > 0;

  function openUrl(url: string) {
    if (openTelegramLink.isAvailable()) {
      openTelegramLink(url);
    } else {
      window.open(url, "_blank");
    }
  }

  function handleOpen() {
    openUrl(`https://t.me/${task.channel_username}`);
    setStage("checking");
    setErrorText(null);
  }

  async function handleOpenExternal() {
    setErrorText(null);
    setLoading(true);
    try {
      const { target_url } = await createExternalTaskClick(task.id);
      openUrl(target_url);
      setStage("awaiting_partner");
    } catch {
      setErrorText(t("partnerTasks.checkFailed"));
    } finally {
      setLoading(false);
    }
  }

  async function handleCheck() {
    setLoading(true);
    setErrorText(null);
    try {
      const result = await checkPartnerTaskSubscription(task.id);
      onClaimed(result.state);
      if (result.status === "claimed") {
        setStage("done");
      } else {
        // First pass — verified, but the reward only unlocks 24h from now.
        setAvailableAt(result.available_at);
        setStage("pending");
      }
    } catch (err) {
      if (err instanceof ApiError && err.code === "not_subscribed") {
        // If this was the 24h-later re-check and the server found the
        // subscription gone, it already wiped the pending verification —
        // start over from "todo" instead of leaving a stuck button.
        if (stage === "pending") setStage("todo");
        setErrorText(t("partnerTasks.notSubscribed"));
      } else if (err instanceof ApiError && err.code === "too_early" && typeof err.details?.available_at === "string") {
        // Only reachable via a race (e.g. a double-tap landing within the
        // same ~1s window useCountdown needs to resync after the first
        // check) — the server already knows the real available_at, so
        // resync to it instead of showing a generic, misleading error.
        setAvailableAt(err.details.available_at);
        setStage("pending");
      } else {
        setErrorText(t("partnerTasks.checkFailed"));
      }
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="gradient-surface flex items-center gap-3 rounded-xl p-3">
      {task.icon_url ? (
        <Image
          src={task.icon_url}
          alt=""
          width={48}
          height={48}
          className="h-12 w-12 shrink-0 rounded-xl object-cover"
        />
      ) : (
        <div className="gradient-action flex h-12 w-12 shrink-0 items-center justify-center rounded-xl">
          <Handshake className="h-6 w-6 text-white" />
        </div>
      )}

      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-semibold">{task.title}</p>
        {task.description && (
          <p className="truncate text-xs text-nav-inactive">{task.description}</p>
        )}
        {ItemIcon ? (
          <p className="flex items-center gap-1 text-xs text-purple-400">
            <ItemIcon className="h-3.5 w-3.5 shrink-0" />
            {t(itemNameKey(task.reward_item_type!))}
            {task.reward_item_qty > 1 ? ` ×${task.reward_item_qty}` : ""}
          </p>
        ) : (
          <p className="text-xs text-gram">
            +{formatGramAmount(task.reward_amount)} {t("common.gram")}
          </p>
        )}
        {waiting && (
          <p className="text-xs text-boost">
            {t("partnerTasks.availableIn", { time: formatDuration(remaining, units) })}
          </p>
        )}
        {effectiveStage === "awaiting_partner" && (
          <p className="flex items-center gap-1 text-xs text-boost">
            <Hourglass className="h-3 w-3 shrink-0" />
            {t("partnerTasks.awaitingPartner")}
          </p>
        )}
        {errorText && <p className="text-xs text-danger">{errorText}</p>}
      </div>

      {effectiveStage === "done" ? (
        <button type="button" disabled className="flex shrink-0 items-center gap-1 rounded-full bg-progress-bg px-3 py-1.5 text-xs text-profit">
          <CheckCircle2 className="h-3.5 w-3.5" />
          {t("quests.claimed")}
        </button>
      ) : task.verification_method === "external_api" ? (
        <button
          type="button"
          onClick={handleOpenExternal}
          disabled={loading}
          className="gradient-action shrink-0 rounded-full px-3 py-1.5 text-xs font-semibold disabled:opacity-50"
        >
          {t("partnerTasks.doIt")}
        </button>
      ) : effectiveStage === "todo" ? (
        <button type="button" onClick={handleOpen} className="gradient-action shrink-0 rounded-full px-3 py-1.5 text-xs font-semibold">
          {t("partnerTasks.doIt")}
        </button>
      ) : waiting ? (
        <button type="button" disabled className="shrink-0 rounded-full bg-progress-bg px-3 py-1.5 text-xs text-nav-inactive disabled:opacity-50">
          {t("partnerTasks.check")}
        </button>
      ) : (
        <button type="button" onClick={handleCheck} disabled={loading} className="gradient-action shrink-0 rounded-full px-3 py-1.5 text-xs font-semibold disabled:opacity-50">
          {t("partnerTasks.check")}
        </button>
      )}
    </div>
  );
}

/**
 * Renders one flat list of partner_tasks rows — the caller decides which
 * `kind` slice to pass in (see TasksScreen, which splits state.partner_tasks
 * into the "Смотрящие" and "Связи на районе" tabs from the same array).
 */
export function PartnerTasksSection({
  tasks,
  onStateChange,
  title,
  icon: Icon = Handshake,
  emptyText,
}: {
  tasks: PartnerTask[];
  onStateChange: (state: PlayerState) => void;
  title: string;
  icon?: LucideIcon;
  emptyText?: string;
}) {
  return (
    <div className="flex flex-col gap-2">
      <h2 className="flex items-center gap-1.5 px-1 text-sm font-semibold text-nav-inactive">
        <Icon className="h-4 w-4 text-purple-400" />
        {title}
      </h2>
      {tasks.length === 0 && emptyText && (
        <p className="px-1 text-sm text-nav-inactive">{emptyText}</p>
      )}
      {tasks.map((task) => (
        <TaskCard key={task.id} task={task} onClaimed={onStateChange} />
      ))}
    </div>
  );
}
