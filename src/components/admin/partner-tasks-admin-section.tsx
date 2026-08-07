"use client";

import { useEffect, useState } from "react";
import { Handshake, Star } from "lucide-react";
import {
  fetchAdminPartnerTasks,
  createAdminPartnerTask,
  deactivateAdminPartnerTask,
  ApiError,
  type AdminPartnerTask,
} from "@/lib/api-client";
import type { PartnerTaskKind } from "@/lib/types";
import { formatGramAmount } from "@/lib/format-gram";

const KIND_GROUPS: { kind: PartnerTaskKind; label: string; Icon: typeof Handshake }[] = [
  { kind: "ambassador", label: "Смотрящие", Icon: Star },
  { kind: "partner", label: "Связи на районе", Icon: Handshake },
];

export function PartnerTasksAdminSection() {
  const [tasks, setTasks] = useState<AdminPartnerTask[] | null>(null);
  const [kind, setKind] = useState<PartnerTaskKind>("partner");
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
        kind,
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
      <h2 className="flex items-center gap-1.5 px-1 text-sm font-semibold text-nav-inactive">
        <Handshake className="h-4 w-4 text-purple-400" />
        Связи на районе — задания на подписку
      </h2>

      <form onSubmit={handleSubmit} className="gradient-surface flex flex-col gap-2 rounded-xl p-3">
        <div className="flex gap-2">
          {KIND_GROUPS.map(({ kind: k, label, Icon }) => (
            <button
              key={k}
              type="button"
              onClick={() => setKind(k)}
              className={`flex flex-1 items-center justify-center gap-1.5 rounded-full px-3 py-2 text-xs font-semibold ${
                kind === k ? "gradient-action" : "bg-progress-bg text-nav-inactive"
              }`}
            >
              <Icon className="h-3.5 w-3.5" />
              {label}
            </button>
          ))}
        </div>
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

      {tasks === null && <p className="text-sm text-nav-inactive">Загрузка...</p>}

      {tasks !== null &&
        KIND_GROUPS.map(({ kind: k, label, Icon }) => {
          const group = tasks.filter((t) => t.is_active && t.kind === k);
          return (
            <div key={k} className="flex flex-col gap-2">
              <h3 className="flex items-center gap-1.5 px-1 text-xs font-semibold text-nav-inactive">
                <Icon className="h-3.5 w-3.5" />
                {label}
              </h3>
              {group.length === 0 && (
                <p className="px-1 text-xs text-nav-inactive">Задач пока нет.</p>
              )}
              {group.map((t) => (
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
          );
        })}
    </div>
  );
}
