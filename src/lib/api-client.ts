import type { HistoryEntry, PlayerState } from "./types";

export class ApiError extends Error {
  constructor(public code: string) {
    super(code);
  }
}

async function request<T>(input: string, init?: RequestInit): Promise<T> {
  const res = await fetch(input, {
    ...init,
    credentials: "include",
    headers: { "Content-Type": "application/json", ...init?.headers },
  });

  if (!res.ok) {
    const body = await res.json().catch(() => null);
    throw new ApiError(body?.error ?? `http_${res.status}`);
  }

  return res.json() as Promise<T>;
}

export function fetchState() {
  return request<PlayerState>("/api/state");
}

export function startCycle(tier: number) {
  return request<{ cycleId: string; state: PlayerState }>("/api/cycles/start", {
    method: "POST",
    body: JSON.stringify({ tier }),
  });
}

/** Wholesale purchase — only valid once a tier's slots are fully upgraded (5/5). */
export function buyMaxSlots(tier: number) {
  return request<{ cycleId: string; state: PlayerState }>("/api/cycles/buy-max", {
    method: "POST",
    body: JSON.stringify({ tier }),
  });
}

export function openContainer(id: string) {
  return request<{ reward: number; state: PlayerState }>(`/api/containers/${id}/open`, {
    method: "POST",
  });
}

export interface ClaimQuestResult {
  reward_amount: number;
  boost_granted: boolean;
}

export function claimQuest(id: string) {
  return request<{ result: ClaimQuestResult; state: PlayerState }>(`/api/quests/${id}/claim`, {
    method: "POST",
  });
}

export interface WalletTxResult {
  id: string;
  amount: number;
  fee: number;
  net_amount: number;
}

export function depositGram(amount: number) {
  return request<{ result: WalletTxResult; state: PlayerState }>("/api/wallet/deposit", {
    method: "POST",
    body: JSON.stringify({ amount }),
  });
}

export interface WithdrawalRequestResult extends WalletTxResult {
  status: "pending";
}

/** Doesn't pay out — files a pending request an admin has to approve/reject. */
export function withdrawGram(amount: number) {
  return request<{ result: WithdrawalRequestResult; state: PlayerState }>("/api/wallet/withdraw", {
    method: "POST",
    body: JSON.stringify({ amount }),
  });
}

export interface ShopPack {
  id: string;
  title: string;
  gram_amount: number;
  price_ton: number;
}

export function fetchShopPacks() {
  return request<{ packs: ShopPack[] }>("/api/shop/packs");
}

export interface PreparedPurchase {
  packId: string;
  gramAmount: number;
  priceTon: number;
  /** Nanotons, decimal string — pass straight through as the TON Connect message's `amount`. */
  amountNano: string;
  /** Exact text to attach as the transfer comment — binds the payment to this user + pack. */
  comment: string;
  /** Unix seconds — use as the TON Connect message's `validUntil`. */
  validUntil: number;
}

export function prepareShopPurchase(packId: string) {
  return request<PreparedPurchase>("/api/shop/prepare-purchase", {
    method: "POST",
    body: JSON.stringify({ packId }),
  });
}

export interface ShopPurchaseResult {
  id: string;
  pack_id: string;
  gram_amount: number;
  amount_ton: number;
  tx_hash: string;
}

/**
 * Confirms a TON Connect payment already broadcast by the wallet. The
 * on-chain transfer can take a few seconds to confirm and get indexed by
 * TonAPI, so the server may reply `payment_not_found` while it's still
 * pending — this polls verify-purchase itself for a while before giving up,
 * on top of the short poll the server already does per call.
 */
export async function verifyShopPurchase(
  input: { packId: string; boc: string },
  { attempts = 6, delayMs = 3000 }: { attempts?: number; delayMs?: number } = {},
): Promise<{ result: ShopPurchaseResult; state: PlayerState }> {
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      return await request<{ result: ShopPurchaseResult; state: PlayerState }>(
        "/api/shop/verify-purchase",
        { method: "POST", body: JSON.stringify(input) },
      );
    } catch (err) {
      const isLastAttempt = attempt === attempts - 1;
      if (isLastAttempt || !(err instanceof ApiError) || err.code !== "payment_not_found") {
        throw err;
      }
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }

  // Unreachable — the loop above always returns or throws — but keeps TS happy.
  throw new ApiError("payment_not_found");
}

export function applyBoost(boostId: string, tier: number) {
  return request<{ state: PlayerState }>(`/api/boosts/${boostId}/apply`, {
    method: "POST",
    body: JSON.stringify({ tier }),
  });
}

export interface ComboGuessResult {
  is_win: boolean;
  correct: boolean[];
  attempts_used: number;
  attempts_max: number;
  reward_amount: number;
}

export function submitComboGuess(tiers: number[]) {
  return request<{ result: ComboGuessResult; state: PlayerState }>("/api/combo/guess", {
    method: "POST",
    body: JSON.stringify({ tiers }),
  });
}

export function markIntroSeen() {
  return request<{ ok: true }>("/api/intro/seen", { method: "POST" });
}

export interface LeaderboardEntry {
  display_name: string;
  total_earned: number;
  completed_cycles_total: number;
}

export function fetchLeaderboard(metric: "total_earned" | "completed_cycles_total" = "total_earned") {
  return request<LeaderboardEntry[]>(`/api/leaderboard?metric=${metric}`);
}

export function fetchHistory() {
  return request<HistoryEntry[]>("/api/history");
}

export function checkPartnerTaskSubscription(taskId: string) {
  return request<{ reward: number; state: PlayerState }>("/api/tasks/check-sub", {
    method: "POST",
    body: JSON.stringify({ taskId }),
  });
}

export interface AdminPartnerTask {
  id: string;
  title: string;
  description: string | null;
  reward_amount: number;
  channel_username: string;
  is_active: boolean;
  sort_order: number;
}

export function fetchAdminPartnerTasks() {
  return request<AdminPartnerTask[]>("/api/admin/partner-tasks");
}

export function createAdminPartnerTask(input: {
  title: string;
  channelLink: string;
  reward: number;
}) {
  return request<AdminPartnerTask>("/api/admin/partner-tasks", {
    method: "POST",
    body: JSON.stringify(input),
  });
}

export function deactivateAdminPartnerTask(id: string) {
  return request<{ ok: true }>(`/api/admin/partner-tasks/${id}`, { method: "PATCH" });
}

export interface AdminUser {
  id: string;
  telegram_id: number;
  username: string | null;
  first_name: string | null;
  is_ambassador: boolean;
}

export function searchAdminUsers(q: string) {
  return request<AdminUser[]>(`/api/admin/users/search?q=${encodeURIComponent(q)}`);
}

export function setUserAmbassador(id: string, isAmbassador: boolean) {
  return request<{ ok: true }>(`/api/admin/users/${id}/ambassador`, {
    method: "PATCH",
    body: JSON.stringify({ isAmbassador }),
  });
}

export interface AmbassadorLevelStats {
  level: number;
  referred_count: number;
  total_deposited: number;
}

export interface AmbassadorStats {
  id: string;
  telegram_id: number;
  username: string | null;
  first_name: string | null;
  levels: AmbassadorLevelStats[];
}

export function fetchAmbassadorStats() {
  return request<AmbassadorStats[]>("/api/admin/ambassadors/stats");
}

export interface BroadcastResult {
  sent: number;
  failed: number;
  total: number;
}

export interface AdminDailyComboSlot {
  tier: number;
  name: string;
}

export interface AdminDailyCombo {
  id: string;
  combo_date: string;
  reward_amount: number;
  tiers: AdminDailyComboSlot[];
  all_tiers: AdminDailyComboSlot[];
}

export function fetchAdminDailyCombo() {
  return request<AdminDailyCombo>("/api/admin/daily-combo");
}

export function regenerateAdminDailyCombo() {
  return request<AdminDailyCombo>("/api/admin/daily-combo/regenerate", { method: "POST" });
}

export function setAdminDailyComboTiers(tiers: number[]) {
  return request<AdminDailyCombo>("/api/admin/daily-combo", {
    method: "PATCH",
    body: JSON.stringify({ tiers }),
  });
}

export async function sendBroadcast(form: FormData) {
  const res = await fetch("/api/admin/broadcast", {
    method: "POST",
    credentials: "include",
    // No Content-Type here on purpose — the browser sets
    // multipart/form-data with the correct boundary itself.
    body: form,
  });

  if (!res.ok) {
    const body = await res.json().catch(() => null);
    throw new ApiError(body?.error ?? `http_${res.status}`);
  }

  return res.json() as Promise<BroadcastResult>;
}

export interface AdminWithdrawalRequest {
  id: string;
  amount: number;
  fee: number;
  net_amount: number;
  status: "pending" | "approved" | "rejected";
  created_at: string;
  resolved_at: string | null;
  admin_note: string | null;
  user: {
    telegram_id: number;
    username: string | null;
    first_name: string | null;
  } | null;
}

export function fetchAdminWithdrawals(status: "pending" | "approved" | "rejected" = "pending") {
  return request<AdminWithdrawalRequest[]>(`/api/admin/withdrawals?status=${status}`);
}

export function resolveAdminWithdrawal(id: string, approve: boolean, note?: string) {
  return request<AdminWithdrawalRequest>(`/api/admin/withdrawals/${id}`, {
    method: "PATCH",
    body: JSON.stringify({ approve, note }),
  });
}
