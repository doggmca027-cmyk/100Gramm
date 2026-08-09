"use client";

import { useEffect, useState } from "react";
import { Link2, Copy, RefreshCw, CheckCircle2 } from "lucide-react";
import {
  fetchAdminPartnerApps,
  createAdminPartnerApp,
  updateAdminPartnerApp,
  ApiError,
  type AdminPartnerApp,
} from "@/lib/api-client";

/**
 * Registry of the other apps 100GRAM cross-promotes with, for the
 * external_api verification path on "Смотрящие"/"Связи на районе" tasks
 * (see 0055_partner_cross_app_tasks.sql). The secret shown here is the
 * shared HMAC key both directions sign their postback with — give it to
 * the partner out of band (not over this UI), same trust level as any
 * other credential exchange between two teams.
 */
export function PartnerAppsAdminSection() {
  const [apps, setApps] = useState<AdminPartnerApp[] | null>(null);
  const [slug, setSlug] = useState("");
  const [name, setName] = useState("");
  const [outgoingCallbackUrl, setOutgoingCallbackUrl] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copiedId, setCopiedId] = useState<string | null>(null);

  function load() {
    fetchAdminPartnerApps()
      .then(setApps)
      .catch(() => setApps([]));
  }

  useEffect(load, []);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await createAdminPartnerApp({
        slug: slug.trim().toLowerCase(),
        name: name.trim(),
        outgoingCallbackUrl: outgoingCallbackUrl.trim() || undefined,
      });
      setSlug("");
      setName("");
      setOutgoingCallbackUrl("");
      load();
    } catch (err) {
      setError(
        err instanceof ApiError && err.code === "duplicate_slug"
          ? "Такой slug уже занят"
          : err instanceof ApiError && err.code === "invalid_slug"
            ? "Slug: латиница/цифры/дефис, 2-32 символа"
            : "Не получилось создать приложение",
      );
    } finally {
      setSubmitting(false);
    }
  }

  async function handleToggleActive(app: AdminPartnerApp) {
    await updateAdminPartnerApp(app.id, { isActive: !app.is_active }).catch(() => null);
    load();
  }

  async function handleRotateSecret(app: AdminPartnerApp) {
    if (!confirm(`Перевыпустить секрет для «${app.name}»? Старый сразу перестанет работать.`)) return;
    await updateAdminPartnerApp(app.id, { rotateSecret: true }).catch(() => null);
    load();
  }

  async function handleCopy(id: string, value: string) {
    try {
      await navigator.clipboard.writeText(value);
      setCopiedId(id);
      setTimeout(() => setCopiedId((cur) => (cur === id ? null : cur)), 1500);
    } catch {
      // clipboard API unavailable — the value is right there on screen anyway
    }
  }

  return (
    <div className="flex flex-col gap-3">
      <h2 className="flex items-center gap-1.5 px-1 text-sm font-semibold text-nav-inactive">
        <Link2 className="h-4 w-4 text-purple-400" />
        Партнёрские приложения (кросс-промо по API)
      </h2>
      <p className="px-1 text-xs text-nav-inactive">
        Регистрируй здесь другое приложение, чтобы ставить задания «выполни там» с проверкой
        через подписанный callback вместо Telegram-подписки. Секрет и slug передай партнёру
        отдельно (не через этот экран).
      </p>

      <form onSubmit={handleSubmit} className="gradient-surface flex flex-col gap-2 rounded-xl p-3">
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Название (например: FunFarm)"
          required
          className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
        />
        <input
          value={slug}
          onChange={(e) => setSlug(e.target.value)}
          placeholder="Slug (латиница/цифры/дефис, например: funfarm)"
          required
          pattern="[a-z0-9-]{2,32}"
          className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
        />
        <input
          value={outgoingCallbackUrl}
          onChange={(e) => setOutgoingCallbackUrl(e.target.value)}
          placeholder="URL callback партнёра (необязательно — можно добавить позже)"
          className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
        />
        {error && <p className="text-xs text-danger">{error}</p>}
        <button
          type="submit"
          disabled={submitting}
          className="gradient-action rounded-full py-2 text-sm font-semibold disabled:opacity-50"
        >
          Зарегистрировать
        </button>
      </form>

      {apps === null && <p className="text-sm text-nav-inactive">Загрузка...</p>}
      {apps?.length === 0 && (
        <p className="px-1 text-xs text-nav-inactive">Партнёров пока нет.</p>
      )}

      {apps?.map((app) => (
        <div key={app.id} className="gradient-surface flex flex-col gap-2 rounded-xl p-3">
          <div className="flex items-center justify-between">
            <p className="text-sm font-semibold">
              {app.name}{" "}
              <span className="font-mono text-xs text-nav-inactive">/{app.slug}</span>
            </p>
            <button
              type="button"
              onClick={() => handleToggleActive(app)}
              className={`rounded-full px-3 py-1 text-xs font-semibold ${
                app.is_active ? "bg-emerald-500/10 text-emerald-400" : "bg-progress-bg text-nav-inactive"
              }`}
            >
              {app.is_active ? "Активен" : "Отключён"}
            </button>
          </div>

          <div className="flex flex-col gap-1 text-xs text-nav-inactive">
            <span>
              Входящий callback (для партнёра): <br />
              <span dir="ltr" className="font-mono text-[11px]">
                /api/partner/callback/{app.slug}
              </span>
            </span>
            <span>
              Исходящий callback (наш к партнёру):{" "}
              {app.outgoing_callback_url ? (
                <span dir="ltr" className="break-all font-mono text-[11px]">
                  {app.outgoing_callback_url}
                </span>
              ) : (
                "не задан"
              )}
            </span>
          </div>

          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={() => handleCopy(app.id, app.secret)}
              className="flex items-center gap-1 rounded-full bg-progress-bg px-3 py-1.5 text-xs text-nav-inactive"
            >
              {copiedId === app.id ? (
                <CheckCircle2 className="h-3.5 w-3.5 text-emerald-400" />
              ) : (
                <Copy className="h-3.5 w-3.5" />
              )}
              Скопировать секрет
            </button>
            <button
              type="button"
              onClick={() => handleRotateSecret(app)}
              className="flex items-center gap-1 rounded-full bg-progress-bg px-3 py-1.5 text-xs text-danger"
            >
              <RefreshCw className="h-3.5 w-3.5" />
              Перевыпустить
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}
