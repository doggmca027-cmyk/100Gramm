"use client";

import { useState } from "react";
import { Radio, Handshake, Target, CheckCircle2, Sparkles, type LucideIcon } from "lucide-react";
import { openTelegramLink } from "@telegram-apps/sdk-react";
import type { PlayerState, SystemTask } from "@/lib/types";
import { claimSystemTask, ApiError } from "@/lib/api-client";
import { useLanguage } from "@/lib/i18n/context";
import { itemIcon, itemNameKey } from "@/lib/combo-items";
import { useCountdown, formatDuration } from "@/hooks/use-countdown";

type Stage = "todo" | "checking" | "pending" | "done";

// Placeholder for useCountdown when there's no available_at yet — avoids
// computing `new Date()` (impure) during render just to produce an unused
// fallback, same idiom as product-card.tsx's EPOCH.
const EPOCH = "1970-01-01T00:00:00.000Z";

const CATEGORY_ICON: Record<SystemTask["category"], LucideIcon> = {
  social: Radio,
  referral: Handshake,
  gameplay: Target,
};

function targetUrl(targetValue: string): string {
  return targetValue.startsWith("http") ? targetValue : `https://t.me/${targetValue}`;
}

function initialStage(task: SystemTask): Stage {
  if (task.completed) return "done";
  if (task.available_at) return "pending";
  return "todo";
}

function TaskCard({
  task,
  onClaimed,
}: {
  task: SystemTask;
  onClaimed: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  const isSocial = task.category === "social";
  const [stage, setStage] = useState<Stage>(() => initialStage(task));
  const [availableAt, setAvailableAt] = useState<string | null>(task.available_at);
  const [loading, setLoading] = useState(false);
  const [errorText, setErrorText] = useState<string | null>(null);

  const remaining = useCountdown(availableAt ?? EPOCH);
  const waiting = stage === "pending" && remaining > 0;

  const progressMet = task.progress >= task.required_count;
  const canClaim = !isSocial && progressMet;
  const CategoryIcon = CATEGORY_ICON[task.category];

  function handleOpen() {
    if (!task.target_value) return;
    const url = targetUrl(task.target_value);
    if (openTelegramLink.isAvailable() && url.includes("t.me")) {
      openTelegramLink(url);
    } else {
      window.open(url, "_blank");
    }
    setStage("checking");
    setErrorText(null);
  }

  async function handleClaim() {
    setLoading(true);
    setErrorText(null);
    try {
      const result = await claimSystemTask(task.slug);
      onClaimed(result.state);
      if (result.status === "claimed") {
        setStage("done");
      } else {
        // channel_sub/chat_join, first pass — verified, but the reward
        // only unlocks 24h from now.
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
      } else if (err instanceof ApiError && err.code === "task_not_claimable") {
        setErrorText(t("systemTasks.notReadyYet"));
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
    <div className="gradient-surface flex flex-col gap-2 rounded-xl p-3">
      <div className="flex items-start gap-3">
        <div className="gradient-action flex h-12 w-12 shrink-0 items-center justify-center rounded-xl">
          <CategoryIcon className="h-6 w-6 text-white" />
        </div>
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-semibold">{task.title}</p>
          {task.description && (
            <p className="truncate text-xs text-nav-inactive">{task.description}</p>
          )}
          <div className="mt-1 flex flex-wrap items-center gap-2 text-xs">
            {task.rewards.map((r) => {
              const RewardIcon = itemIcon(r.item_type);
              return (
                <span key={r.item_type} className="flex items-center gap-1 text-gram">
                  <RewardIcon className="h-3.5 w-3.5 shrink-0 text-purple-400" />
                  {t(itemNameKey(r.item_type))}
                  {r.quantity > 1 ? ` ×${r.quantity}` : ""}
                </span>
              );
            })}
            <span className="flex items-center gap-1 text-boost">
              <Sparkles className="h-3.5 w-3.5" />
              +{task.reward_xp} XP
            </span>
          </div>
        </div>
      </div>

      {!isSocial && !task.completed && (
        <div className="flex flex-col gap-1">
          <div className="h-1.5 rounded-full bg-progress-bg">
            <div
              className="h-1.5 rounded-full bg-progress-fill"
              style={{ width: `${Math.min(100, (task.progress / task.required_count) * 100)}%` }}
            />
          </div>
          <p className="text-xs text-nav-inactive">
            {t("systemTasks.progress", { done: Math.min(task.progress, task.required_count), total: task.required_count })}
          </p>
        </div>
      )}

      {waiting && (
        <p className="text-xs text-boost">
          {t("partnerTasks.availableIn", { time: formatDuration(remaining) })}
        </p>
      )}

      {errorText && <p className="text-xs text-danger">{errorText}</p>}

      <div className="flex justify-end">
        {stage === "done" ? (
          <span className="flex items-center gap-1 rounded-full bg-progress-bg px-3 py-1.5 text-xs text-profit">
            <CheckCircle2 className="h-3.5 w-3.5" />
            {t("quests.claimed")}
          </span>
        ) : isSocial ? (
          stage === "todo" ? (
            <button
              type="button"
              onClick={handleOpen}
              className="gradient-action rounded-full px-3 py-1.5 text-xs font-semibold"
            >
              {t("partnerTasks.doIt")}
            </button>
          ) : waiting ? (
            <button
              type="button"
              disabled
              className="rounded-full bg-progress-bg px-3 py-1.5 text-xs text-nav-inactive disabled:opacity-50"
            >
              {t("partnerTasks.check")}
            </button>
          ) : (
            <button
              type="button"
              onClick={handleClaim}
              disabled={loading}
              className="gradient-action rounded-full px-3 py-1.5 text-xs font-semibold disabled:opacity-50"
            >
              {t("partnerTasks.check")}
            </button>
          )
        ) : (
          <button
            type="button"
            onClick={handleClaim}
            disabled={!canClaim || loading}
            className="gradient-action rounded-full px-3 py-1.5 text-xs font-semibold disabled:opacity-40"
          >
            {t("systemTasks.claim")}
          </button>
        )}
      </div>
    </div>
  );
}

export function SystemTasksSection({
  tasks,
  onStateChange,
}: {
  tasks: SystemTask[];
  onStateChange: (state: PlayerState) => void;
}) {
  const { t } = useLanguage();
  if (tasks.length === 0) return null;

  return (
    <div className="flex flex-col gap-2">
      <h2 className="flex items-center gap-1.5 px-1 text-sm font-semibold text-nav-inactive">
        <Target className="h-4 w-4 text-amber-400" />
        {t("systemTasks.title")}
      </h2>
      {tasks.map((task) => (
        <TaskCard key={task.id} task={task} onClaimed={onStateChange} />
      ))}
    </div>
  );
}
