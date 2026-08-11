import type {
  BankPlanDays,
  District,
  DistrictBoostType,
  GangAvatarId,
  GangCosmetic,
  GangListEntry,
  HistoryEntry,
  PartnerTaskKind,
  PartnerTaskVerificationMethod,
  PlayerState,
  SquadLevel,
  SyndicateLeaderboard,
} from "./types";

export class ApiError extends Error {
  constructor(
    public code: string,
    public details?: Record<string, unknown>,
  ) {
    super(code);
  }
}

/**
 * Reads the double-submit CSRF cookie (set alongside the session cookie by
 * /api/auth/telegram, deliberately not httpOnly) and echoes it back as a
 * header — see assertCsrfToken in src/lib/session.ts for why this exists.
 * Safe to call during SSR/module-eval: returns null when there's no
 * document.
 */
function readCsrfToken(): string | null {
  if (typeof document === "undefined") return null;
  const match = document.cookie.match(/(?:^|; )csrf_token=([^;]+)/);
  return match ? decodeURIComponent(match[1]) : null;
}

async function request<T>(input: string, init?: RequestInit): Promise<T> {
  const csrfToken = readCsrfToken();
  const res = await fetch(input, {
    ...init,
    credentials: "include",
    headers: {
      "Content-Type": "application/json",
      ...(csrfToken ? { "X-CSRF-Token": csrfToken } : {}),
      ...init?.headers,
    },
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
  /** All-time count of cycles ever started (any status, any season) — not scoped to the active season like completed_cycles_total. */
  cycles_launched_total: number;
}

export type LeaderboardMetric = "total_earned" | "completed_cycles_total" | "cycles_launched_total";

export function fetchLeaderboard(metric: LeaderboardMetric = "total_earned") {
  return request<LeaderboardEntry[]>(`/api/leaderboard?metric=${metric}`);
}

/** The Leaderboard screen's "Синдикаты" tab — weekly top-15 gangs by Influence Points, the reset countdown, and the caller's own gang's row. */
export function fetchSyndicateLeaderboard() {
  return request<SyndicateLeaderboard>("/api/leaderboard/syndicates");
}

export function fetchHistory() {
  return request<HistoryEntry[]>("/api/history");
}

/** The 3 referral lines (participants, deposits, earnings, member list), fetched on demand by the Squad screen. */
export function fetchSquadLevels() {
  return request<SquadLevel[]>("/api/squad/levels");
}

export type PartnerTaskCheckResult =
  | { status: "pending"; available_at: string; state: PlayerState }
  | { status: "claimed"; reward: number; state: PlayerState };

/**
 * First successful call after a task's channel link is opened only
 * records that the subscription check passed (status "pending") — the
 * reward isn't paid until a second call, no earlier than available_at,
 * re-confirms the user is still subscribed (status "claimed"). See
 * 0044_partner_task_delayed_reward.sql.
 */
export function checkPartnerTaskSubscription(taskId: string) {
  return request<PartnerTaskCheckResult>("/api/tasks/check-sub", {
    method: "POST",
    body: JSON.stringify({ taskId }),
  });
}

/**
 * Mints (or reuses) the one-time click token for an external_api partner
 * task and returns where "Выполнить" should open — the token's already
 * appended to target_url. There's no player-triggered "check" step for
 * these (unlike telegram_channel tasks): completion is entirely driven by
 * the partner's own postback to /api/partner/callback/[slug], which the
 * next state refresh picks up as `completed`.
 */
export function createExternalTaskClick(taskId: string) {
  return request<{ token: string; target_url: string }>("/api/tasks/external-click", {
    method: "POST",
    body: JSON.stringify({ taskId }),
  });
}

export interface SystemTaskClaimResult {
  task_slug: string;
  reward_xp: number;
  rewards: { item_type: string; quantity: number }[];
}

export type SystemTaskCheckResult =
  | { status: "pending"; available_at: string; state: PlayerState }
  | { status: "claimed"; reward: SystemTaskClaimResult; state: PlayerState };

/**
 * For channel_sub/chat_join tasks, the first successful call only records
 * that the subscription check passed (status "pending") — the reward
 * isn't paid until a second call, no earlier than available_at, re-confirms
 * the user is still subscribed (status "claimed"). Every other task
 * category claims instantly on the first call (always "claimed"). See
 * 0045_system_task_delayed_reward.sql.
 */
export function claimSystemTask(slug: string) {
  return request<SystemTaskCheckResult>("/api/system-tasks/claim", {
    method: "POST",
    body: JSON.stringify({ slug }),
  });
}

export interface AdminPartnerTask {
  id: string;
  title: string;
  description: string | null;
  reward_amount: number;
  /** Set when the task pays out a boost item instead of GRAM — reward_amount is 0 in that case. */
  reward_item_type: string | null;
  reward_item_qty: number;
  channel_username: string | null;
  is_active: boolean;
  sort_order: number;
  kind: PartnerTaskKind;
  verification_method: PartnerTaskVerificationMethod;
  partner_app_id: string | null;
  target_url: string | null;
}

export function fetchAdminPartnerTasks() {
  return request<AdminPartnerTask[]>("/api/admin/partner-tasks");
}

export function createAdminPartnerTask(
  input: {
    title: string;
    kind: PartnerTaskKind;
  } & (
    | { rewardType: "gram"; reward: number }
    | { rewardType: "item"; rewardItemType: string; rewardItemQty: number }
  ) &
    (
      | { verificationMethod: "telegram_channel"; channelLink: string }
      | { verificationMethod: "external_api"; partnerAppId: string; targetUrl: string }
    ),
) {
  return request<AdminPartnerTask>("/api/admin/partner-tasks", {
    method: "POST",
    body: JSON.stringify(input),
  });
}

export function deactivateAdminPartnerTask(id: string) {
  return request<{ ok: true }>(`/api/admin/partner-tasks/${id}`, { method: "PATCH" });
}

export interface AdminPartnerApp {
  id: string;
  slug: string;
  name: string;
  secret: string;
  outgoing_callback_url: string | null;
  is_active: boolean;
  created_at: string;
}

export function fetchAdminPartnerApps() {
  return request<AdminPartnerApp[]>("/api/admin/partner-apps");
}

export function createAdminPartnerApp(input: { slug: string; name: string; outgoingCallbackUrl?: string }) {
  return request<AdminPartnerApp>("/api/admin/partner-apps", {
    method: "POST",
    body: JSON.stringify(input),
  });
}

export function updateAdminPartnerApp(
  id: string,
  input: { isActive?: boolean; outgoingCallbackUrl?: string; rotateSecret?: boolean },
) {
  return request<AdminPartnerApp>(`/api/admin/partner-apps/${id}`, {
    method: "PATCH",
    body: JSON.stringify(input),
  });
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

export interface BroadcastBatchResult {
  sent: number;
  failed: number;
  total: number;
  /** Offset to pass as the next batch's `offset` — >= total once done. */
  nextOffset: number;
  /** Telegram file_id of the uploaded photo, once known — reuse it on every later batch instead of re-uploading the file. */
  fileId: string | null;
  done: boolean;
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
  /** Only set by the regenerate endpoint — result of re-DMing ambassadors the new answer. */
  notify?: {
    sent: number;
    failed: number;
    total: number;
    failedTelegramIds: number[];
    skipped?: "server_misconfigured" | "no_active_season";
  };
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

/**
 * Sends one batch of the broadcast — see 0-arg `offset`/`fileId` in
 * api/admin/broadcast/route.ts for why this is batched at all (the full
 * recipient list is 1000+ and won't fit in one serverless invocation).
 * Caller loops this until `done`, passing the returned `nextOffset`/`fileId`
 * back in on each subsequent call (and omitting the photo file after the
 * first, since fileId lets the server reuse Telegram's copy of it).
 */
export async function sendBroadcastBatch(form: FormData) {
  const csrfToken = readCsrfToken();
  const res = await fetch("/api/admin/broadcast", {
    method: "POST",
    credentials: "include",
    // No Content-Type here on purpose — the browser sets
    // multipart/form-data with the correct boundary itself.
    headers: csrfToken ? { "X-CSRF-Token": csrfToken } : undefined,
    body: form,
  });

  if (!res.ok) {
    const body = await res.json().catch(() => null);
    throw new ApiError(body?.error ?? `http_${res.status}`);
  }

  return res.json() as Promise<BroadcastBatchResult>;
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

export interface BankDepositResult {
  deposit_id: string;
  balance: number;
  ends_at: string;
  expected_reward: number;
  bonus_speed: boolean;
  bonus_slot: boolean;
}

/** Opens a deposit — the plan's minimum is re-validated server-side regardless of what the UI already checked. */
export function createBankDeposit(planDays: BankPlanDays, amount: number) {
  return request<{ result: BankDepositResult; state: PlayerState }>("/api/bank/deposits", {
    method: "POST",
    body: JSON.stringify({ planDays, amount }),
  });
}

/** Browse-to-join list AND the "Топ Банд Района" ranking table — same endpoint, `search` just narrows it by name. */
export function fetchGangs(search?: string) {
  const qs = search?.trim() ? `?q=${encodeURIComponent(search.trim())}` : "";
  return request<GangListEntry[]>(`/api/gangs${qs}`);
}

/** Founds a gang for 5 GRAM ("5 TON") — name/charset/profanity/balance are all re-validated server-side regardless. */
export function createGang(name: string, avatarId: GangAvatarId) {
  return request<{ result: { gang_id: string; name: string; balance: number }; state: PlayerState }>(
    "/api/gangs",
    { method: "POST", body: JSON.stringify({ name, avatarId }) },
  );
}

export function joinGang(gangId: string) {
  return request<{ state: PlayerState }>(`/api/gangs/${gangId}/join`, { method: "POST" });
}

/** Rejects with 'leader_cannot_leave' for the gang's leader — they use leaveGang's disband counterpart instead. */
export function leaveGang() {
  return request<{ state: PlayerState }>("/api/gangs/leave", { method: "POST" });
}

/** The leader's only way out of their own gang — deletes it outright, every member (including the leader) is removed. */
export function disbandGang() {
  return request<{ state: PlayerState }>("/api/gangs/disband", { method: "POST" });
}

/** Tops up the caller's own gang bank from their own GRAM balance — shows up alongside the automatic 10%-of-cycle cut in the same donor/transaction lists. */
export function donateToGangBank(amount: number) {
  return request<{ result: { gang_id: string; amount: number; balance: number }; state: PlayerState }>(
    "/api/gangs/donate",
    { method: "POST", body: JSON.stringify({ amount }) },
  );
}

/** Leader-only promote/demote between 'member' and 'co_leader'. */
export function setGangMemberRole(userId: string, role: "co_leader" | "member") {
  return request<{ result: { user_id: string; role: string }; state: PlayerState }>(
    `/api/gangs/members/${userId}/role`,
    { method: "POST", body: JSON.stringify({ role }) },
  );
}

/** Leader-only removal of any non-leader member. */
export function kickGangMember(userId: string) {
  return request<{ state: PlayerState }>(`/api/gangs/members/${userId}/kick`, { method: "POST" });
}

/** Leader-only: +5 member slots for 1 GRAM, paid from the gang's own bank (not the leader's personal balance). */
export function upgradeGangCapacity() {
  return request<{ result: { gang_id: string; max_members: number; bank_balance_gram: number }; state: PlayerState }>(
    "/api/gangs/upgrade-capacity",
    { method: "POST" },
  );
}

/** Leader-only: splits `amount` GRAM from the gang bank evenly across every current member. */
export function distributeDividends(amount: number) {
  return request<{ result: { gang_id: string; amount: number; member_count: number; bank_balance_gram: number }; state: PlayerState }>(
    "/api/gangs/dividends",
    { method: "POST", body: JSON.stringify({ amount }) },
  );
}

/** Public read — the "Карта Районов" screen, District Wars MVP. */
export function fetchDistricts() {
  return request<District[]>("/api/districts");
}

/** Leader-or-co_leader-only: registers the gang's attack claim on today's-or-tomorrow's battle window and sets it as their target. */
export function attackDistrict(districtId: string) {
  return request<{ result: { gang_id: string; target_district_id: string; battle_date: string }; state: PlayerState }>(
    `/api/districts/${districtId}/attack`,
    { method: "POST" },
  );
}

/** Leader-or-co_leader-only: buys a battle boost, only while the district's window is active. */
export function activateDistrictBoost(districtId: string, boostType: DistrictBoostType, payFromBank: boolean) {
  return request<{ result: { expires_at: string }; state: PlayerState }>(
    `/api/districts/${districtId}/boost`,
    { method: "POST", body: JSON.stringify({ boostType, payFromBank }) },
  );
}

/** Leader-or-co_leader-only: hires the mercenary bot (+50 influence/hour, automatic, for the rest of today's window). */
export function activateMercenaryBot(districtId: string, payFromBank: boolean) {
  return request<{ result: { expires_at: string }; state: PlayerState }>(
    `/api/districts/${districtId}/mercenary`,
    { method: "POST", body: JSON.stringify({ payFromBank }) },
  );
}

/** Public read — the "Кастомизация" shop catalog. */
export function fetchGangCosmetics() {
  return request<GangCosmetic[]>("/api/gangs/cosmetics");
}

/** Leader-only: buys a premium avatar or frame from their own balance. */
export function purchaseGangCosmetic(cosmeticCode: string) {
  return request<{ result: { cosmetic_code: string; cosmetic_type: string }; state: PlayerState }>(
    "/api/gangs/cosmetics/purchase",
    { method: "POST", body: JSON.stringify({ cosmeticCode }) },
  );
}

/** Leader-only: buys +1 co_leader slot for 3 GRAM from their own balance. */
export function purchaseCoLeaderSlot() {
  return request<{ result: { co_leader_slots: number }; state: PlayerState }>(
    "/api/gangs/co-leader-slot",
    { method: "POST" },
  );
}

/** Leader-only: one-time 10 GRAM upgrade to 30% APY gang bank interest. */
export function purchaseVipTreasury() {
  return request<{ result: { vip_treasury: boolean }; state: PlayerState }>(
    "/api/gangs/vip-treasury",
    { method: "POST" },
  );
}

/** Leader-or-co_leader-only: instantly buys `tonAmount * 200` weekly Influence Points (min 1 TON) — see buy_direct_influence (0070_syndicate_weekly_leaderboard.sql). */
export function buyDirectInfluence(tonAmount: number, payFromBank: boolean) {
  return request<{ result: { points_added: number; weekly_influence_points: number }; state: PlayerState }>(
    "/api/gangs/buy-influence",
    { method: "POST", body: JSON.stringify({ tonAmount, payFromBank }) },
  );
}
