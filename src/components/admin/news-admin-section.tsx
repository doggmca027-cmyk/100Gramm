"use client";

import { useEffect, useMemo, useState } from "react";
import { sendBroadcast, ApiError, type BroadcastResult } from "@/lib/api-client";

export function NewsAdminSection() {
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [photoFile, setPhotoFile] = useState<File | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [sending, setSending] = useState(false);
  const [result, setResult] = useState<BroadcastResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  const maxLen = photoFile ? 1024 : 4096;
  const captionLength = title.length + body.length;
  const hasContent = title.trim() || body.trim();

  // Derived, not state — the effect below only owns cleanup (revoking the
  // previous URL), it never calls setState.
  const photoPreviewUrl = useMemo(
    () => (photoFile ? URL.createObjectURL(photoFile) : null),
    [photoFile],
  );

  useEffect(() => {
    return () => {
      if (photoPreviewUrl) URL.revokeObjectURL(photoPreviewUrl);
    };
  }, [photoPreviewUrl]);

  function handlePhotoChange(e: React.ChangeEvent<HTMLInputElement>) {
    setPhotoFile(e.target.files?.[0] ?? null);
    setResult(null);
  }

  async function handleSend() {
    setSending(true);
    setError(null);
    try {
      const form = new FormData();
      form.set("title", title.trim());
      form.set("body", body.trim());
      if (photoFile) form.set("photo", photoFile);

      const res = await sendBroadcast(form);
      setResult(res);
      setConfirming(false);
      setTitle("");
      setBody("");
      setPhotoFile(null);
    } catch (err) {
      setError(
        err instanceof ApiError && err.code === "content_too_long"
          ? `Слишком длинно — максимум ${maxLen} символов ${photoFile ? "с фото" : "без фото"}.`
          : "Не получилось отправить рассылку",
      );
      setConfirming(false);
    } finally {
      setSending(false);
    }
  }

  return (
    <div className="flex flex-col gap-3">
      <h2 className="px-1 text-sm font-semibold text-nav-inactive">📰 Новости — рассылка</h2>

      <div className="gradient-surface flex flex-col gap-2 rounded-xl p-3">
        <input
          value={title}
          onChange={(e) => {
            setTitle(e.target.value);
            setResult(null);
          }}
          placeholder="Заголовок"
          className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
        />
        <textarea
          value={body}
          onChange={(e) => {
            setBody(e.target.value);
            setResult(null);
          }}
          placeholder="Текст новости"
          rows={4}
          className="resize-none rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
        />
        <label className="flex cursor-pointer items-center justify-between rounded-lg bg-progress-bg px-3 py-2 text-sm text-nav-inactive">
          <span>{photoFile ? photoFile.name : "📷 Прикрепить фото (необязательно)"}</span>
          <input type="file" accept="image/*" onChange={handlePhotoChange} className="hidden" />
        </label>
        <p className="px-1 text-[11px] text-nav-inactive">
          {captionLength}/{maxLen} символов
        </p>
      </div>

      {hasContent && (
        <div>
          <p className="mb-1 px-1 text-xs text-nav-inactive">Превью поста:</p>
          <div className="gradient-surface overflow-hidden rounded-2xl">
            {photoPreviewUrl && (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={photoPreviewUrl} alt="" className="max-h-64 w-full object-cover" />
            )}
            <div className="p-4">
              {title && <p className="font-semibold">{title}</p>}
              {body && <p className="mt-1 whitespace-pre-wrap text-sm">{body}</p>}
            </div>
          </div>
        </div>
      )}

      {error && <p className="px-1 text-xs text-danger">{error}</p>}

      {result && (
        <p className="px-1 text-xs text-profit">
          Отправлено: {result.sent} из {result.total}
          {result.failed > 0 ? ` · не удалось: ${result.failed}` : ""}
        </p>
      )}

      {!confirming ? (
        <button
          type="button"
          onClick={() => setConfirming(true)}
          disabled={!hasContent || captionLength > maxLen}
          className="gradient-action rounded-full py-2 text-sm font-semibold disabled:opacity-40"
        >
          📤 Отправить всем
        </button>
      ) : (
        <div className="gradient-surface flex flex-col gap-2 rounded-xl p-3">
          <p className="text-sm">Точно отправить это всем пользователям бота?</p>
          <div className="flex gap-2">
            <button
              type="button"
              onClick={() => setConfirming(false)}
              disabled={sending}
              className="flex-1 rounded-full bg-progress-bg py-2 text-sm text-nav-inactive disabled:opacity-50"
            >
              Отмена
            </button>
            <button
              type="button"
              onClick={handleSend}
              disabled={sending}
              className="flex-1 rounded-full bg-danger py-2 text-sm font-semibold disabled:opacity-50"
            >
              {sending ? "Отправка..." : "Да, отправить"}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
