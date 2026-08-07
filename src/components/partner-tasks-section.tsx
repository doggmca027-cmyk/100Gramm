"use client";

import { useState } from "react";
import Image from "next/image";
import { Handshake, CheckCircle2 } from "lucide-react";
import { openTelegramLink } from "@telegram-apps/sdk-react";
import type { PartnerTask, PlayerState } from "@/lib/types";
import { checkPartnerTaskSubscription, ApiError } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";
import { formatGramAmount } from "@/lib/format-gram";
import { useCountdown, formatDuration } from "@/hooks/use-countdown";

type Stage = "todo" | "checking" | "pending" | "done";

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
  const [stage, setStage] = useState<Stage>(() => initialStage(task));
  const [availableAt, setAvailableAt] = useState<string | null>(task.available_at);
  const [loading, setLoading] = useState(false);
  const [errorText, setErrorText] = useState<string | null>(null);

  // Ticks down to 0 once available_at passes — the button unlocks itself,
  // no need for the user to reopen the app.
  const remaining = useCountdown(availableAt ?? EPOCH);
  const waiting = stage === "pending" && remaining > 0;

  function handleOpen() {
    const url = `https://t.me/${task.channel_username}`;
    if (openTelegramLink.isAvailable()) {
      openTelegramLink(url);
    } else {
      window.open(url, "_blank");
    }
    setStage("checking");
    setErrorText(null);
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
        <p className="text-xs text-gram">
          +{formatGramAmount(task.reward_amount)} {t("common.gram")}
        </p>
        {waiting && (
          <p className="text-xs text-boost">
            {t("partnerTasks.availableIn", { time: formatDuration(remaining) })}
          </p>
        )}
        {errorText && <p className="text-xs text-danger">{errorText}</p>}
      </div>

      {stage === "done" ? (
        <button type="button" disabled className="flex shrink-0 items-center gap-1 rounded-full bg-progress-bg px-3 py-1.5 text-xs text-profit">
          <CheckCircle2 className="h-3.5 w-3.5" />
          {t("quests.claimed")}
        </button>
      ) : stage === "todo" ? (
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

export function PartnerTasksSection({
  tasks,
  onStateChange,
}: {
  tasks: PartnerTask[];
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  if (tasks.length === 0) return null;

  return (
    <div className="flex flex-col gap-2">
      <h2 className="flex items-center gap-1.5 px-1 text-sm font-semibold text-nav-inactive">
        <Handshake className="h-4 w-4 text-purple-400" />
        {t("partnerTasks.title")}
      </h2>
      {tasks.map((task) => (
        <TaskCard key={task.id} task={task} onClaimed={onStateChange} />
      ))}
    </div>
  );
}
