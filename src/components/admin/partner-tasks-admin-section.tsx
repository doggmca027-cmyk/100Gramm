"use client";

import { useEffect, useState } from "react";
import {
  fetchAdminPartnerTasks,
  createAdminPartnerTask,
  deactivateAdminPartnerTask,
  ApiError,
  type AdminPartnerTask,
} from "@/lib/api-client";
import { formatGramAmount } from "@/lib/format-gram";

export function PartnerTasksAdminSection() {
  const [tasks, setTasks] = useState<AdminPartnerTask[] | null>(null);
  const [title, setTitle] = useState("");
  const [channelLink, setChannelLink] = useState("");
  const [reward, setReward] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function load() {
    fetchAdminPartnerTasks()
      .then(setTasks)
      .catch(() => setTasks([]));
  }

  useEffect(load, []);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await createAdminPartnerTask({
        title,
        channelLink,
        reward: Number(reward.replace(",", ".")),
      });
      setTitle("");
      setChannelLink("");
      setReward("");
      load();
    } catch (err) {
      setError(
        err instanceof ApiError && err.code === "invalid_channel_link"
          ? "Не понял ссылку на канал — пример: https://t.me/channel или @channel"
          : err instanceof ApiError && err.code === "invalid_reward"
            ? "Награда должна быть положительным числом"
            : "Не получилось создать задачу",
      );
    } finally {
      setSubmitting(false);
    }
  }

  async function handleDeactivate(id: string) {
    await deactivateAdminPartnerTask(id).catch(() => null);
    load();
  }

  return (
    <div className="flex flex-col gap-3">
      <h2 className="px-1 text-sm font-semibold text-nav-inactive">
        🤝 Связи на районе — партнёрские задачи
      </h2>

      <form onSubmit={handleSubmit} className="gradient-surface flex flex-col gap-2 rounded-xl p-3">
        <input
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          placeholder="Название (например: Канал Главы Банды)"
          required
          className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
        />
        <input
          value={channelLink}
          onChange={(e) => setChannelLink(e.target.value)}
          placeholder="Ссылка на канал (t.me/channel или @channel)"
          required
          className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
        />
        <input
          value={reward}
          onChange={(e) => setReward(e.target.value)}
          placeholder="Награда, GRAM (например: 2)"
          inputMode="decimal"
          required
          className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
        />
        {error && <p className="text-xs text-danger">{error}</p>}
        <button
          type="submit"
          disabled={submitting}
          className="gradient-action rounded-full py-2 text-sm font-semibold disabled:opacity-50"
        >
          Добавить
        </button>
      </form>

      <div className="flex flex-col gap-2">
        {tasks === null && <p className="text-sm text-nav-inactive">Загрузка...</p>}
        {tasks?.length === 0 && (
          <p className="text-sm text-nav-inactive">Задач пока нет.</p>
        )}
        {tasks
          ?.filter((t) => t.is_active)
          .map((t) => (
            <div
              key={t.id}
              className="gradient-surface flex items-center justify-between rounded-xl p-3"
            >
              <div>
                <p className="text-sm font-semibold">{t.title}</p>
                <p className="text-xs text-nav-inactive">
                  @{t.channel_username} · +{formatGramAmount(t.reward_amount)} GRAM
                </p>
              </div>
              <button
                type="button"
                onClick={() => handleDeactivate(t.id)}
                className="shrink-0 rounded-full bg-progress-bg px-3 py-1.5 text-xs text-danger"
              >
                Скрыть
              </button>
            </div>
          ))}
      </div>
    </div>
  );
}
