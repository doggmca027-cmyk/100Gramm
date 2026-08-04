"use client";

import { useEffect, useState } from "react";
import {
  fetchAdminPartnerTasks,
  createAdminPartnerTask,
  deactivateAdminPartnerTask,
  ApiError,
  type AdminPartnerTask,
} from "@/lib/api-client";

export function AdminPanelModal({ onClose }: { onClose: () => void }) {
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
    <div
      className="fixed inset-0 z-50 flex flex-col justify-end bg-black/60"
      onClick={onClose}
    >
      <div
        className="bg-nav flex max-h-[85vh] flex-col gap-4 overflow-y-auto rounded-t-2xl p-4"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between">
          <h2 className="text-base font-semibold">⚙️ Связи на районе — управление</h2>
          <button type="button" onClick={onClose} className="text-nav-inactive" aria-label="Закрыть">
            ✕
          </button>
        </div>

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
                    @{t.channel_username} · +{t.reward_amount.toFixed(2)} GRAM
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
    </div>
  );
}
