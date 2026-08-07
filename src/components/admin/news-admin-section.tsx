"use client";

import { useEffect, useMemo, useState } from "react";
import { Newspaper, Camera, Send } from "lucide-react";
import { sendBroadcastBatch, ApiError } from "@/lib/api-client";

type Progress = { sent: number; failed: number; total: number };
/** Where to resume from if a batch call fails partway through — keeps a retry from re-sending to everyone already reached. */
type Cursor = { offset: number; fileId: string | null };

export function NewsAdminSection() {
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [photoFile, setPhotoFile] = useState<File | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [sending, setSending] = useState(false);
  const [progress, setProgress] = useState<Progress | null>(null);
  const [cursor, setCursor] = useState<Cursor | null>(null);
  const [error, setError] = useState<string | null>(null);

  const maxLen = photoFile ? 1024 : 4096;
  const captionLength = title.length + body.length;
  const hasContent = title.trim() || body.trim();
  const resuming = cursor !== null;

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
    setProgress(null);
    setCursor(null);
  }

  /**
   * The recipient list is 1000+ users — sending them all from one request
   * used to time out the serverless function partway through (see
   * api/admin/broadcast/route.ts), which is why this was failing. Now each
   * call only sends one batch; this loops it, updating live sent/total
   * progress, until the server says `done`. If a batch call itself fails
   * (network hiccup, one bad request), `cursor` keeps the resume point so
   * hitting "Отправить всем" again continues instead of re-messaging
   * everyone already reached.
   */
  async function handleSend() {
    // Belt-and-suspenders — the buttons that call this are already disabled
    // while `sending`, but a second guard here means a stray double-call
    // can never start two overlapping batch loops racing the same cursor.
    if (sending) return;
    setSending(true);
    setError(null);

    let offset = cursor?.offset ?? 0;
    let fileId = cursor?.fileId ?? null;
    let sentAcc = progress?.sent ?? 0;
    let failedAcc = progress?.failed ?? 0;

    try {
      let done = false;
      while (!done) {
        const form = new FormData();
        form.set("title", title.trim());
        form.set("body", body.trim());
        form.set("offset", String(offset));
        if (fileId) form.set("fileId", fileId);
        else if (photoFile) form.set("photo", photoFile);

        const batch = await sendBroadcastBatch(form);
        sentAcc += batch.sent;
        failedAcc += batch.failed;
        offset = batch.nextOffset;
        fileId = batch.fileId;
        done = batch.done;

        setProgress({ sent: sentAcc, failed: failedAcc, total: batch.total });
        setCursor(done ? null : { offset, fileId });
      }

      setConfirming(false);
      setTitle("");
      setBody("");
      setPhotoFile(null);
    } catch (err) {
      setError(
        err instanceof ApiError && err.code === "content_too_long"
          ? `Слишком длинно — максимум ${maxLen} символов ${photoFile ? "с фото" : "без фото"}.`
          : `Рассылка прервалась (отправлено ${sentAcc} из ${progress?.total ?? "?"}) — нажми ещё раз, чтобы продолжить с этого места.`,
      );
      setConfirming(false);
    } finally {
      setSending(false);
    }
  }

  return (
    <div className="flex flex-col gap-3">
      <h2 className="flex items-center gap-1.5 px-1 text-sm font-semibold text-nav-inactive">
        <Newspaper className="h-4 w-4 text-neutral-400" />
        Новости — рассылка
      </h2>

      <div className="gradient-surface flex flex-col gap-2 rounded-xl p-3">
        <input
          value={title}
          onChange={(e) => {
            setTitle(e.target.value);
            setProgress(null);
            setCursor(null);
          }}
          placeholder="Заголовок"
          disabled={resuming || sending}
          className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none disabled:opacity-50"
        />
        <textarea
          value={body}
          onChange={(e) => {
            setBody(e.target.value);
            setProgress(null);
            setCursor(null);
          }}
          placeholder="Текст новости"
          rows={4}
          disabled={resuming || sending}
          className="resize-none rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none disabled:opacity-50"
        />
        <label className="flex cursor-pointer items-center justify-between rounded-lg bg-progress-bg px-3 py-2 text-sm text-nav-inactive">
          <span className="flex items-center gap-1.5">
            {!photoFile && <Camera className="h-4 w-4 shrink-0" />}
            {photoFile ? photoFile.name : "Прикрепить фото (необязательно)"}
          </span>
          <input
            type="file"
            accept="image/*"
            onChange={handlePhotoChange}
            disabled={resuming || sending}
            className="hidden"
          />
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

      {progress && (
        <p className="px-1 text-xs text-profit">
          Отправлено: {progress.sent} из {progress.total}
          {progress.failed > 0 ? ` · не удалось: ${progress.failed}` : ""}
          {sending ? " · отправка..." : resuming ? " · остановлено, можно продолжить" : ""}
        </p>
      )}

      {!confirming ? (
        <button
          type="button"
          onClick={() => (resuming ? handleSend() : setConfirming(true))}
          disabled={sending || ((!hasContent || captionLength > maxLen) && !resuming)}
          className="gradient-action flex items-center justify-center gap-1.5 rounded-full py-2 text-sm font-semibold disabled:opacity-40"
        >
          <Send className="h-4 w-4" />
          {resuming ? "Продолжить рассылку" : "Отправить всем"}
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
