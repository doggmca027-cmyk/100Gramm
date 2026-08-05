"use client";

import { useEffect, useState } from "react";
import { fetchAdminWithdrawals, type AdminWithdrawalRequest } from "@/lib/api-client";
import { WithdrawalConfirmModal } from "./withdrawal-confirm-modal";

type StatusFilter = "pending" | "approved" | "rejected";

const STATUS_LABELS: Record<StatusFilter, string> = {
  pending: "⏳ Ожидают",
  approved: "✅ Одобрены",
  rejected: "❌ Отклонены",
};

export function WithdrawalsAdminSection() {
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("pending");
  const [requests, setRequests] = useState<AdminWithdrawalRequest[] | null>(null);
  const [selected, setSelected] = useState<AdminWithdrawalRequest | null>(null);
  // Bumped after an approve/reject to re-trigger the fetch below without a
  // synchronous setState call in the effect body (previous list stays on
  // screen — briefly stale, never blank — until the refetch resolves).
  const [refreshKey, setRefreshKey] = useState(0);

  useEffect(() => {
    let cancelled = false;
    fetchAdminWithdrawals(statusFilter)
      .then((data) => {
        if (!cancelled) setRequests(data);
      })
      .catch(() => {
        if (!cancelled) setRequests([]);
      });
    return () => {
      cancelled = true;
    };
  }, [statusFilter, refreshKey]);

  return (
    <div className="flex flex-col gap-3">
      <h2 className="px-1 text-sm font-semibold text-nav-inactive">💸 Заявки на вывод</h2>

      <div className="flex gap-2">
        {(Object.keys(STATUS_LABELS) as StatusFilter[]).map((status) => (
          <button
            key={status}
            type="button"
            onClick={() => setStatusFilter(status)}
            className={`flex-1 rounded-full py-2 text-xs font-semibold ${
              statusFilter === status ? "gradient-action" : "gradient-surface text-nav-inactive"
            }`}
          >
            {STATUS_LABELS[status]}
          </button>
        ))}
      </div>

      <div className="flex flex-col gap-2">
        {requests === null && <p className="text-sm text-nav-inactive">Загрузка...</p>}
        {requests?.length === 0 && (
          <p className="text-sm text-nav-inactive">Пусто.</p>
        )}
        {requests?.map((req) => (
          <button
            key={req.id}
            type="button"
            onClick={() => statusFilter === "pending" && setSelected(req)}
            className="gradient-surface flex items-center justify-between rounded-xl p-3 text-left disabled:opacity-70"
            disabled={statusFilter !== "pending"}
          >
            <div>
              <p className="text-sm font-semibold">
                {req.user?.username ? `@${req.user.username}` : (req.user?.first_name ?? "Без имени")}
              </p>
              <p className="text-xs text-nav-inactive">
                {new Date(req.created_at).toLocaleString("ru-RU")}
              </p>
              {req.admin_note && (
                <p className="text-xs text-nav-inactive">💬 {req.admin_note}</p>
              )}
            </div>
            <div className="text-right">
              <p className="font-semibold text-gram">{req.net_amount.toFixed(2)} GRAM</p>
              <p className="text-xs text-nav-inactive">запрос {req.amount.toFixed(2)}</p>
            </div>
          </button>
        ))}
      </div>

      {selected && (
        <WithdrawalConfirmModal
          request={selected}
          onClose={() => setSelected(null)}
          onResolved={() => setRefreshKey((k) => k + 1)}
        />
      )}
    </div>
  );
}
