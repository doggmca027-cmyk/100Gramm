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

export function withdrawGram(amount: number) {
  return request<{ result: WalletTxResult; state: PlayerState }>("/api/wallet/withdraw", {
    method: "POST",
    body: JSON.stringify({ amount }),
  });
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
