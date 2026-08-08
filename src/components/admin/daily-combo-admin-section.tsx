"use client";

import { useEffect, useState } from "react";
import { Sparkles, Copy, CheckCircle2, RefreshCw } from "lucide-react";
import {
  fetchAdminDailyCombo,
  regenerateAdminDailyCombo,
  setAdminDailyComboTiers,
  ApiError,
  type AdminDailyCombo,
} from "@/lib/api-client";

/** Human-readable summary of the ambassador re-notify outcome after a regenerate. */
function notifySummary(notify: NonNullable<AdminDailyCombo["notify"]>): string {
  if (notify.skipped === "server_misconfigured") return "Не отправлено: не настроен TELEGRAM_BOT_TOKEN.";
  if (notify.skipped === "no_active_season") return "Не отправлено: нет активного сезона.";
  if (notify.total === 0) return "Амбассадоров пока нет — уведомлять некого.";
  const base = `Уведомлено амбассадоров: ${notify.sent}/${notify.total}.`;
  if (notify.failed === 0) return base;
  return (
    `${base} Не дошло до ${notify.failed}: ID ${notify.failedTelegramIds.join(", ")} — ` +
    `скорее всего они ни разу не открывали чат с ботом напрямую (заходили только через кнопку ` +
    `приложения). Попроси их написать /start боту в личке — это разово чинит доставку.`
  );
}

/** Plain-text summary the admin can copy straight into a Telegram channel post. */
function shillText(combo: AdminDailyCombo): string {
  const list = combo.tiers.map((t) => `${t.tier}. ${t.name}`).join("\n");
  return `🎁 Комбо дня (${combo.combo_date}):\n${list}\n\nСобери все 4 — получи случайный буст (ускоритель цикла или автосбор)!`;
}

export function DailyComboAdminSection() {
  const [combo, setCombo] = useState<AdminDailyCombo | null>(null);
  const [picks, setPicks] = useState<(number | "")[]>(["", "", "", ""]);
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notifyResult, setNotifyResult] = useState<AdminDailyCombo["notify"] | null>(null);

  function load() {
    fetchAdminDailyCombo()
      .then((data) => {
        setCombo(data);
        setPicks(data.tiers.map((t) => t.tier));
      })
      .catch(() => setCombo(null));
  }

  useEffect(load, []);

  async function handleRegenerate() {
    setBusy(true);
    setError(null);
    setNotifyResult(null);
    try {
      const data = await regenerateAdminDailyCombo();
      setCombo(data);
      setPicks(data.tiers.map((t) => t.tier));
      setNotifyResult(data.notify ?? null);
    } catch {
      setError("Не получилось перегенерировать комбо");
    } finally {
      setBusy(false);
    }
  }

  async function handleSavePicks() {
    if (picks.some((p) => p === "")) {
      setError("Выбери карточку в каждый из 4 слотов");
      return;
    }
    const tiers = picks as number[];
    if (new Set(tiers).size !== 4) {
      setError("Все 4 карточки должны быть разными");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const data = await setAdminDailyComboTiers(tiers);
      setCombo(data);
      setPicks(data.tiers.map((t) => t.tier));
    } catch (err) {
      setError(
        err instanceof ApiError && err.code === "invalid_combo_tiers"
          ? "Некорректный набор карточек"
          : "Не получилось сохранить комбо",
      );
    } finally {
      setBusy(false);
    }
  }

  async function handleCopy() {
    if (!combo) return;
    try {
      await navigator.clipboard.writeText(shillText(combo));
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // clipboard API unavailable — silently ignore, text is on screen anyway
    }
  }

  if (!combo) {
    return <p className="text-sm text-nav-inactive">Загрузка...</p>;
  }

  return (
    <div className="flex flex-col gap-3">
      <h2 className="flex items-center gap-1.5 px-1 text-sm font-semibold text-nav-inactive">
        <Sparkles className="h-4 w-4 text-purple-400" />
        Daily Combo — комбо на {combo.combo_date}
      </h2>

      <div className="gradient-surface flex flex-col gap-2 rounded-xl p-3">
        <p className="text-xs text-nav-inactive">
          Активное комбо сегодня · награда — случайный буст из инвентаря
        </p>
        <div className="grid grid-cols-2 gap-2">
          {combo.tiers.map((t) => (
            <div key={t.tier} className="rounded-lg bg-progress-bg px-3 py-2 text-sm">
              <span className="text-nav-inactive">#{t.tier}</span> {t.name}
            </div>
          ))}
        </div>
        <button
          type="button"
          onClick={handleCopy}
          className="gradient-action flex items-center justify-center gap-1.5 rounded-full py-2 text-sm font-semibold"
        >
          {copied ? <CheckCircle2 className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
          {copied ? "Скопировано" : "Скопировать текст для шилла"}
        </button>
        <button
          type="button"
          onClick={handleRegenerate}
          disabled={busy}
          className="flex items-center justify-center gap-1.5 rounded-full bg-progress-bg py-2 text-sm font-semibold text-danger disabled:opacity-50"
        >
          <RefreshCw className="h-4 w-4" />
          Перегенерировать (сбросит прогресс всех игроков за сегодня)
        </button>
        {notifyResult && (
          <p className="text-xs text-nav-inactive">{notifySummary(notifyResult)}</p>
        )}
      </div>

      <div className="gradient-surface flex flex-col gap-2 rounded-xl p-3">
        <p className="text-xs text-nav-inactive">Назначить карточки вручную</p>
        <div className="grid grid-cols-2 gap-2">
          {[0, 1, 2, 3].map((slot) => (
            <select
              key={slot}
              value={picks[slot]}
              onChange={(e) => {
                const value = e.target.value ? Number(e.target.value) : "";
                setPicks((prev) => prev.map((p, i) => (i === slot ? value : p)));
              }}
              className="rounded-lg bg-progress-bg px-2 py-2 text-sm outline-none"
            >
              <option value="">Слот {slot + 1}</option>
              {combo.all_tiers.map((t) => (
                <option key={t.tier} value={t.tier}>
                  #{t.tier} {t.name}
                </option>
              ))}
            </select>
          ))}
        </div>
        {error && <p className="text-xs text-danger">{error}</p>}
        <button
          type="button"
          onClick={handleSavePicks}
          disabled={busy}
          className="gradient-action rounded-full py-2 text-sm font-semibold disabled:opacity-50"
        >
          Сохранить выбор
        </button>
      </div>
    </div>
  );
}
