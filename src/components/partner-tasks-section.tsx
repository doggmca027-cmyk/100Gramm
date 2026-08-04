"use client";

import { useState } from "react";
import Image from "next/image";
import { openTelegramLink } from "@telegram-apps/sdk-react";
import type { PartnerTask, PlayerState } from "@/lib/types";
import { checkPartnerTaskSubscription, ApiError } from "@/lib/api-client";

type Stage = "todo" | "checking" | "done";

function TaskCard({
  task,
  onClaimed,
}: {
  task: PartnerTask;
  onClaimed: (state: PlayerState) => void;
}) {
  const [stage, setStage] = useState<Stage>(task.completed ? "done" : "todo");
  const [loading, setLoading] = useState(false);
  const [errorText, setErrorText] = useState<string | null>(null);

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
      setStage("done");
    } catch (err) {
      setErrorText(
        err instanceof ApiError && err.code === "not_subscribed"
          ? "Вы не подписались на канал!"
          : "Не получилось проверить, попробуй ещё раз",
      );
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
        <div className="gradient-action flex h-12 w-12 shrink-0 items-center justify-center rounded-xl text-xl">
          🤝
        </div>
      )}

      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-semibold">{task.title}</p>
        {task.description && (
          <p className="truncate text-xs text-nav-inactive">{task.description}</p>
        )}
        <p className="text-xs text-gram">+{task.reward_amount.toFixed(2)} GRAM</p>
        {errorText && <p className="text-xs text-danger">{errorText}</p>}
      </div>

      {stage === "done" ? (
        <button
          type="button"
          disabled
          className="shrink-0 rounded-full bg-progress-bg px-3 py-1.5 text-xs text-profit"
        >
          ✓ Получено
        </button>
      ) : stage === "todo" ? (
        <button
          type="button"
          onClick={handleOpen}
          className="gradient-action shrink-0 rounded-full px-3 py-1.5 text-xs font-semibold"
        >
          Выполнить
        </button>
      ) : (
        <button
          type="button"
          onClick={handleCheck}
          disabled={loading}
          className="gradient-action shrink-0 rounded-full px-3 py-1.5 text-xs font-semibold disabled:opacity-50"
        >
          Проверить
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
  if (tasks.length === 0) return null;

  return (
    <div className="flex flex-col gap-2">
      <h2 className="px-1 text-sm font-semibold text-nav-inactive">
        🤝 Связи на районе
      </h2>
      {tasks.map((task) => (
        <TaskCard key={task.id} task={task} onClaimed={onStateChange} />
      ))}
    </div>
  );
}
