import type { HistoryEntry, PlayerState } from "./types";

export class ApiError extends Error {
  constructor(
    public code: string,
    public details?: Record<string, unknown>,
  ) {
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
    const { error: code, ...details } = body ?? {};
    throw new ApiError(code ?? `http_${res.status}`, details);
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

export interface WithdrawalRequestResult extends WalletTxResult {
  status: "pending";
}

/**
 * Doesn't pay out on its own — files a pending request an admin has to
 * approve/reject (approval sends the real TON automatically).
 * payoutAddress is the player's own connected TON Connect wallet — where
 * the payout will actually go once approved.
 */
export function withdrawGram(amount: number, payoutAddress: string) {
  return request<{ result: WithdrawalRequestResult; state: PlayerState }>("/api/wallet/withdraw", {
    method: "POST",
    body: JSON.stringify({ amount, payoutAddress }),
  });
}

export interface PreparedTonDeposit {
  /** Nanotons, decimal string — pass straight through as the TON Connect message's `amount`. */
  amountNano: string;
  /** Exact text to attach as the transfer comment — binds the payment to this user. */
  comment: string;
  /** Unix seconds — use as the TON Connect message's `validUntil`. */
  validUntil: number;
}

/** GRAM is this game's branded name for TON itself — deposits credit 1:1, no packs/pricing involved. */
export function prepareTonDeposit(amountTon: number) {
  return request<PreparedTonDeposit>("/api/wallet/ton-deposit/prepare", {
    method: "POST",
    body: JSON.stringify({ amountTon }),
  });
}

export interface TonDepositResult {
  id: string;
  gram_amount: number;
  amount_ton: number;
  tx_hash: string;
}

/**
 * Confirms a TON Connect payment already broadcast by the wallet. The
 * on-chain transfer can take a few seconds to confirm and get indexed by
 * TonAPI, so the server may reply `payment_not_found` while it's still
 * pending — this polls verify itself for a while before giving up, on top
 * of the short poll the server already does per call.
 */
export async function verifyTonDeposit(
  input: { amountTon: number; boc: string },
  { attempts = 6, delayMs = 3000 }: { attempts?: number; delayMs?: number } = {},
): Promise<{ result: TonDepositResult; state: PlayerState }> {
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      return await request<{ result: TonDepositResult; state: PlayerState }>(
        "/api/wallet/ton-deposit/verify",
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

export interface ExchangeRate {
  rate: number;
  updatedAt: string;
  source: string;
  stale: boolean;
}

/** Live GRAM/USDT readout — the same value carried on state.exchange_rate, fetched on its own when a full state refetch isn't wanted. */
export function fetchExchangeRate() {
  return request<ExchangeRate>("/api/exchange-rate");
}

export interface PreparedUsdtPayment {
  /** Identifies the locked quote (gram/usdt amount + rate) verifyUsdtPayment checks against — see 0032_usdt_manual_deposits.sql. */
  quoteId: string;
  /** `to:` for the TON Connect message — the buyer's own USDT Jetton wallet contract. */
  jettonWalletAddress: string;
  /** `destination:` inside the transfer body — the treasury owner address the jettons end up at. */
  destinationAddress: string;
  /** `response_destination:` inside the transfer body — refunds leftover TON here. */
  responseDestination: string;
  /** Base USDT units (6 decimals), decimal string — pass straight into buildJettonTransferBody. */
  usdtAmountUnits: string;
  /** Nanoton, decimal string. */
  forwardTonAmountNano: string;
  /** Exact text to attach as the forward_payload comment — binds the payment to this user. */
  comment: string;
  gramAmount: number;
  usdtAmount: number;
  rate: number;
  validUntil: number;
}

/**
 * Quotes a direct USDT payment: pass `tier` to price a specific cycle
 * (spec's "прямая оплата циклов"), or `gramAmount` for an arbitrary top-up
 * (spec's "пополнение"). Either way the amount only ever lands as a GRAM
 * balance credit once verifyUsdtPayment confirms it — starting a cycle
 * afterwards is a separate, explicit startCycle() call.
 */
export function prepareUsdtPayment(input: { buyerAddress: string; tier?: number; gramAmount?: number }) {
  return request<PreparedUsdtPayment>("/api/wallet/usdt-payment/prepare", {
    method: "POST",
    body: JSON.stringify(input),
  });
}

export interface UsdtPaymentResult {
  id: string;
  gram_amount: number;
  usdt_amount: number;
  tx_hash: string;
}

/**
 * Confirms a USDT Jetton transfer already broadcast by the wallet, checked
 * against the locked quote from prepareUsdtPayment (quoteId — never a
 * resubmitted amount, see 0032_usdt_manual_deposits.sql). Same
 * retry-on-payment_not_found contract as verifyTonDeposit — the on-chain
 * transfer (plus TonAPI's own indexing) can take a few seconds, so the
 * server may need a few tries before it shows up.
 */
export async function verifyUsdtPayment(
  quoteId: string,
  { attempts = 6, delayMs = 3000 }: { attempts?: number; delayMs?: number } = {},
): Promise<{ result: UsdtPaymentResult; state: PlayerState }> {
  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      return await request<{ result: UsdtPaymentResult; state: PlayerState }>(
        "/api/wallet/usdt-payment/verify",
        { method: "POST", body: JSON.stringify({ quoteId }) },
      );
    } catch (err) {
      const isLastAttempt = attempt === attempts - 1;
      if (isLastAttempt || !(err instanceof ApiError) || err.code !== "payment_not_found") {
        throw err;
      }
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }

  throw new ApiError("payment_not_found");
}

export function applyBoost(boostId: string, tier: number) {
  return request<{ state: PlayerState }>(`/api/boosts/${boostId}/apply`, {
    method: "POST",
    body: JSON.stringify({ tier }),
  });
}

/** Shaves effect_percent% off the target cycle's remaining time, consuming one unit of itemType. */
export function applyTimeSkipItem(itemType: string, cycleId: string) {
  return request<{ state: PlayerState }>("/api/inventory/apply-time-skip", {
    method: "POST",
    body: JSON.stringify({ itemType, cycleId }),
  });
}

/** Extends wallet.auto_collect_until by effect_hours, consuming one unit of itemType. */
export function applyAutoCollectItem(itemType: string) {
  return request<{ state: PlayerState }>("/api/inventory/apply-auto-collect", {
    method: "POST",
    body: JSON.stringify({ itemType }),
  });
}

export interface ComboGuessResult {
  is_win: boolean;
  correct: boolean[];
  attempts_used: number;
  attempts_max: number;
  /** Which item was actually dropped — null on a losing guess. */
  reward_item_type: string | null;
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
  photo_url: string | null;
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

export interface SystemTaskClaimResult {
  task_slug: string;
  reward_xp: number;
  rewards: { item_type: string; quantity: number }[];
}

export function claimSystemTask(slug: string) {
  return request<{ reward: SystemTaskClaimResult; state: PlayerState }>("/api/system-tasks/claim", {
    method: "POST",
    body: JSON.stringify({ slug }),
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

/** Hides/unhides the *caller's own* profile from the leaderboard — admin panel only. */
export function setLeaderboardVisibility(hidden: boolean) {
  return request<{ state: PlayerState }>("/api/admin/leaderboard-visibility", {
    method: "PATCH",
    body: JSON.stringify({ hidden }),
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
  status: "pending" | "processing" | "approved" | "rejected";
  created_at: string;
  resolved_at: string | null;
  admin_note: string | null;
  payout_address: string | null;
  payout_tx_hash: string | null;
  user: {
    telegram_id: number;
    username: string | null;
    first_name: string | null;
  } | null;
}

export function fetchAdminWithdrawals(
  status: "pending" | "processing" | "approved" | "rejected" = "pending",
) {
  return request<AdminWithdrawalRequest[]>(`/api/admin/withdrawals?status=${status}`);
}

export function resolveAdminWithdrawal(id: string, approve: boolean, note?: string) {
  return request<AdminWithdrawalRequest>(`/api/admin/withdrawals/${id}`, {
    method: "PATCH",
    body: JSON.stringify({ approve, note }),
  });
}
