"use client";

import { useState } from "react";
import { resolveAdminWithdrawal, type AdminWithdrawalRequest } from "@/lib/api-client";

/**
 * Separate confirmation window for a single withdrawal request — deliberately
 * not an inline approve/reject button on the list row, since this moves real
 * money and a stray tap shouldn't be enough to trigger it.
 */
export function WithdrawalConfirmModal({
  request,
  onResolved,
  onClose,
}: {
  request: AdminWithdrawalRequest;
  onResolved: (updated: AdminWithdrawalRequest) => void;
  onClose: () => void;
}) {
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleResolve(approve: boolean) {
    setBusy(true);
    setError(null);
    try {
      const updated = await resolveAdminWithdrawal(request.id, approve, note.trim() || undefined);
      onResolved(updated);
      onClose();
    } catch {
      setError("Не получилось выполнить действие, попробуй ещё раз");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end bg-black/60" onClick={onClose}>
      <div
        className="bg-nav flex flex-col gap-3 rounded-t-2xl p-4"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between">
          <h2 className="text-base font-semibold">💸 Заявка на вывод</h2>
          <button type="button" onClick={onClose} className="text-nav-inactive" aria-label="Назад">
            ✕
          </button>
        </div>

        <div className="gradient-surface flex flex-col gap-2 rounded-xl p-3 text-sm">
          <div className="flex items-center justify-between">
            <span className="text-nav-inactive">Игрок</span>
            <span className="font-semibold">
              {request.user?.username ? `@${request.user.username}` : (request.user?.first_name ?? "Без имени")}
            </span>
          </div>
          <div className="flex items-center justify-between">
            <span className="text-nav-inactive">Telegram ID</span>
            <span>{request.user?.telegram_id ?? "—"}</span>
          </div>
          <div className="flex items-center justify-between">
            <span className="text-nav-inactive">Запрошено</span>
            <span>{request.amount.toFixed(2)} GRAM</span>
          </div>
          <div className="flex items-center justify-between">
            <span className="text-nav-inactive">Комиссия</span>
            <span className="text-danger">-{request.fee.toFixed(2)} GRAM</span>
          </div>
          <div className="flex items-center justify-between font-semibold">
            <span>К выплате</span>
            <span className="text-profit">{request.net_amount.toFixed(2)} GRAM</span>
          </div>
          <div className="flex items-center justify-between text-xs text-nav-inactive">
            <span>Подана</span>
            <span>{new Date(request.created_at).toLocaleString("ru-RU")}</span>
          </div>
        </div>

        <textarea
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="Комментарий (необязательно) — например реквизиты выплаты"
          rows={2}
          className="rounded-lg bg-progress-bg px-3 py-2 text-sm outline-none"
        />

        {error && <p className="text-xs text-danger">{error}</p>}

        <div className="flex gap-2">
          <button
            type="button"
            onClick={() => handleResolve(false)}
            disabled={busy}
            className="flex-1 rounded-full bg-progress-bg py-3 text-sm font-semibold text-danger disabled:opacity-50"
          >
            ✕ Отклонить
          </button>
          <button
            type="button"
            onClick={() => handleResolve(true)}
            disabled={busy}
            className="gradient-action flex-1 rounded-full py-3 text-sm font-semibold disabled:opacity-50"
          >
            ✓ Подтвердить
          </button>
        </div>
      </div>
    </div>
  );
}
