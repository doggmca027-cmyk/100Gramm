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
import { ITEM_ICON } from "@/lib/combo-items";

const KIND_GROUPS: { kind: PartnerTaskKind; label: string; Icon: typeof Handshake }[] = [
  { kind: "ambassador", label: "Смотрящие", Icon: Star },
  { kind: "partner", label: "Связи на районе", Icon: Handshake },
];

type RewardType = "gram" | "item";

// Same catalog combo_item_templates draws from (see lib/combo-items.ts) —
// the boosts a task can hand out instead of GRAM.
const REWARD_ITEM_OPTIONS = [
  { item_type: "time_skip_1pct", label: "Ускоритель -1%" },
  { item_type: "time_skip_3pct", label: "Ускоритель -3%" },
  { item_type: "time_skip_5pct", label: "Ускоритель -5%" },
  { item_type: "time_skip_10pct", label: "Ускоритель -10%" },
  { item_type: "auto_collect_1d", label: "Автосбор 24ч" },
  { item_type: "auto_collect_3d", label: "Автосбор 72ч" },
] as const;

function rewardItemLabel(itemType: string): string {
  return REWARD_ITEM_OPTIONS.find((o) => o.item_type === itemType)?.label ?? itemType;
}

export function PartnerTasksAdminSection() {
  const [tasks, setTasks] = useState<AdminPartnerTask[] | null>(null);
  const [kind, setKind] = useState<PartnerTaskKind>("partner");
  const [title, setTitle] = useState("");
  const [channelLink, setChannelLink] = useState("");
  const [rewardType, setRewardType] = useState<RewardType>("gram");
  const [reward, setReward] = useState("");
  const [rewardItemType, setRewardItemType] = useState<string>(REWARD_ITEM_OPTIONS[0].item_type);
  const [rewardItemQty, setRewardItemQty] = useState("1");
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
      await createAdminPartnerTask(
        rewardType === "item"
          ? {
              title,
              channelLink,
              kind,
              rewardType: "item",
              rewardItemType,
              rewardItemQty: Number(rewardItemQty) || 1,
            }
          : {
              title,
              channelLink,
              kind,
              rewardType: "gram",
              reward: Number(reward.replace(",", ".")),
            },
      );
      setTitle("");
      setChannelLink("");
      setReward("");
      setRewardItemQty("1");
      load();
    } catch (err) {
      setError(
        err instanceof ApiError && err.code === "invalid_channel_link"
          ? "Не понял ссылку на канал — пример: https://t.me/channel или @channel"
          : err instanceof ApiError && err.code === "invalid_reward"
            ? "Проверь награду — сумма должна быть положительной, а количество бустов — целым и больше нуля"
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

        <div className="flex gap-2">
          {(
            [
              { type: "gram" as const, label: "Награда: GRAM" },
              { type: "item" as const, label: "Награда: буст" },
            ]
          ).map(({ type, label }) => (
            <button
              key={type}
              type="button"
              onClick={() => setRewardType(type)}
              className={`flex-1 rounded-full px-3 py-2 text-xs font-semibold ${
                rewardType === type ? "gradient-action" : "bg-progress-bg text-nav-inactive"
              }`}
            >
              {label}
            </button>
          ))}
        </div>

        {rewardType === "gram" ? (
          <input
            value={reward}
            onChange={(e) => setReward(e.target.value)}
            placeholder="Награда, GRAM (например: 2)"
            inputMode="decimal"
            required
            className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
          />
        ) : (
          <div className="flex gap-2">
            <select
              value={rewardItemType}
              onChange={(e) => setRewardItemType(e.target.value)}
              className="flex-1 rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
            >
              {REWARD_ITEM_OPTIONS.map((o) => (
                <option key={o.item_type} value={o.item_type}>
                  {o.label}
                </option>
              ))}
            </select>
            <input
              value={rewardItemQty}
              onChange={(e) => setRewardItemQty(e.target.value)}
              placeholder="Кол-во"
              inputMode="numeric"
              className="w-20 rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
            />
          </div>
        )}

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
              {group.map((t) => {
                const RewardIcon = t.reward_item_type ? ITEM_ICON[t.reward_item_type] : null;
                return (
                  <div
                    key={t.id}
                    className="gradient-surface flex items-center justify-between rounded-xl p-3"
                  >
                    <div>
                      <p className="text-sm font-semibold">{t.title}</p>
                      <p className="flex items-center gap-1 text-xs text-nav-inactive">
                        @{t.channel_username} ·{" "}
                        {t.reward_item_type ? (
                          <span className="flex items-center gap-1 text-purple-400">
                            {RewardIcon && <RewardIcon className="h-3.5 w-3.5 shrink-0" />}
                            {rewardItemLabel(t.reward_item_type)}
                            {t.reward_item_qty > 1 ? ` ×${t.reward_item_qty}` : ""}
                          </span>
                        ) : (
                          `+${formatGramAmount(t.reward_amount)} GRAM`
                        )}
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
                );
              })}
            </div>
          );
        })}
    </div>
  );
}
