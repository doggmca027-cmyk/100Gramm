"use client";

import { useEffect, useState } from "react";
import { Banknote, Hourglass, CheckCircle2, XCircle, MessageSquare, Link as LinkIcon, type LucideIcon } from "lucide-react";
import { fetchAdminWithdrawals, type AdminWithdrawalRequest } from "@/lib/api-client";
import { WithdrawalConfirmModal } from "./withdrawal-confirm-modal";

function formatDisplayName(username: string | null, firstName: string | null) {
  const safeName = [firstName, username].find((value) => typeof value === "string" && value.trim().length > 0);
  if (!safeName) return "Без имени";

  const normalized = safeName.trim();
  return normalized.startsWith("@") ? normalized : `@${normalized}`;
}

type StatusFilter = "pending" | "approved" | "rejected";

const STATUS_LABELS: Record<StatusFilter, string> = {
  pending: "Ожидают",
  approved: "Одобрены",
  rejected: "Отклонены",
};

const STATUS_ICON: Record<StatusFilter, LucideIcon> = {
  pending: Hourglass,
  approved: CheckCircle2,
  rejected: XCircle,
};

const STATUS_COLOR: Record<StatusFilter, string> = {
  pending: "text-amber-400",
  approved: "text-emerald-400",
  rejected: "text-red-400",
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
      <h2 className="flex items-center gap-1.5 px-1 text-sm font-semibold text-nav-inactive">
        <Banknote className="h-4 w-4 text-amber-400" />
        Заявки на вывод
      </h2>

      <div className="flex gap-2">
        {(Object.keys(STATUS_LABELS) as StatusFilter[]).map((status) => {
          const StatusIcon = STATUS_ICON[status];
          return (
            <button
              key={status}
              type="button"
              onClick={() => setStatusFilter(status)}
              className={`flex flex-1 items-center justify-center gap-1 rounded-full py-2 text-xs font-semibold ${
                statusFilter === status ? "gradient-action" : "gradient-surface text-nav-inactive"
              }`}
            >
              <StatusIcon className={`h-3.5 w-3.5 ${statusFilter === status ? "" : STATUS_COLOR[status]}`} />
              {STATUS_LABELS[status]}
            </button>
          );
        })}
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
            className="gradient-surface flex items-center justify-between rounded-xl p-3 text-left rtl:text-right disabled:opacity-70"
            disabled={statusFilter !== "pending"}
          >
            <div>
              <p className="text-sm font-semibold">
                {formatDisplayName(req.user?.username ?? null, req.user?.first_name ?? null)}
              </p>
              <p className="text-xs text-nav-inactive">
                {new Date(req.created_at).toLocaleString("ru-RU")}
              </p>
              {req.admin_note && (
                <p className="flex items-center gap-1 text-xs text-nav-inactive">
                  <MessageSquare className="h-3 w-3 shrink-0" />
                  {req.admin_note}
                </p>
              )}
              {req.payout_tx_hash && (
                <p className="flex items-center gap-1 truncate text-xs text-nav-inactive" title={req.payout_tx_hash}>
                  <LinkIcon className="h-3 w-3 shrink-0" />
                  {req.payout_tx_hash.slice(0, 12)}…
                </p>
              )}
            </div>
            <div className="text-right rtl:text-left">
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
