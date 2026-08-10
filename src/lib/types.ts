import type { Localized } from "./i18n/types";

export interface PlayerState {
  season: {
    id: string;
    slug: string;
    title: string;
    story_theme: string | null;
    title_i18n: Localized;
    story_theme_i18n: Localized;
    starts_at: string;
    ends_at: string;
    config: {
      base_slots: number;
      cycles_per_slot: number;
      max_slots: number | null;
      features?: Record<string, boolean>;
      wallet?: WalletConfig;
    };
  };
  profile: {
    username: string | null;
    first_name: string | null;
    photo_url: string | null;
    /** Self-toggled in the admin panel — excludes this profile from get_leaderboard entirely. */
    hide_from_leaderboard: boolean;
  };
  wallet: {
    balance: number;
    total_earned: number;
    completed_cycles_total: number;
    has_seen_intro: boolean;
    /** Sum of slots_open across unlocked tiers — a display aggregate, not a shared pool. */
    total_slots_open: number;
    total_slots_used: number;
    /** The player's own open withdrawal request, awaiting admin approve/reject — null if none. */
    pending_withdrawal: PendingWithdrawal | null;
    /** Auto-collect passes keep cycles claiming + relaunching on their own until this moment — null if never activated. */
    auto_collect_until: string | null;
    /** "Authority" — earned from system tasks only, no gameplay effect yet. */
    xp: number;
  };
  stats: {
    profit_24h: number;
  };
  rank: {
    name: string;
    name_i18n: Localized;
    icon: string | null;
    level: number;
    min_earned: number;
    next_min_earned: number | null;
  } | null;
  tiers: TierState[];
  active_cycles: ActiveCycle[];
  quests: Quest[];
  containers: Container[];
  partner_tasks: PartnerTask[];
  system_tasks: SystemTask[];
  squad: {
    invite_code: string;
    referred_count: number;
    earned_total: number;
    /** Ambassador status is visible in the Squad screen; deposit referral payouts are fixed at 10/5/2%. */
    is_ambassador: boolean;
  };
  daily_combo: DailyCombo | null;
  boosts: Boost[];
  inventory: InventoryItem[];
  /** GRAM/USDT — GRAM *is* TON, so this is really just live TON/USDT, cached ≤60s server-side. */
  exchange_rate: { pair: string; rate: number; updated_at: string } | null;
  /** Own deposits, active ones first — see BankDeposit. */
  bank_deposits: BankDeposit[];
  /** Whether ANY currently-active deposit is granting each buff right now — same two flags start_cycle itself checks server-side. */
  bank_buffs: {
    speed_boost: boolean;
    slot_boost: boolean;
  };
  /** The caller's own gang, with its full member roster — null when they're not in one. See PlayerGang. */
  gang: PlayerGang | null;
}

export type GangAvatarId =
  | "default_gang"
  | "skull"
  | "crown"
  | "flame"
  | "shield"
  | "swords"
  | "ghost"
  | "anchor";

export type GangRole = "leader" | "co_leader" | "member";

export interface GangMember {
  user_id: string;
  display_name: string;
  photo_url: string | null;
  role: GangRole;
  joined_at: string;
}

export interface GangBankDonor {
  user_id: string;
  display_name: string;
  photo_url: string | null;
  amount: number;
}

export interface GangBankTransaction {
  id: string;
  from_user_id: string;
  display_name: string;
  photo_url: string | null;
  amount_gram: number;
  created_at: string;
}

/** state.gang — the caller's own gang, full roster included (capped at max_members = 20, cheap to inline). */
export interface PlayerGang {
  id: string;
  name: string;
  avatar_id: GangAvatarId;
  level: number;
  experience: number;
  /** experience % exp_per_level — how far into the current level, for the EXP bar. */
  exp_into_level: number;
  exp_per_level: number;
  max_members: number;
  leader_name: string;
  my_role: GangRole;
  members: GangMember[];
  bank_balance_gram: number;
  bank_balance_ton: number;
  bank_top_donors: GangBankDonor[];
  bank_transactions: GangBankTransaction[];
}

/** One row of /api/gangs — the browse-to-join list and the "Топ Банд Района" ranking table, same shape either way. */
export interface GangListEntry {
  id: string;
  name: string;
  avatar_id: GangAvatarId;
  level: number;
  experience: number;
  max_members: number;
  member_count: number;
  leader_name: string;
  /** True when this is the caller's own gang — for highlighting it in the ranking table. */
  is_mine: boolean;
}

export type BankPlanDays = 7 | 14 | 30;
export type BankDepositStatus = "active" | "claimed" | "early_closed";

export interface BankDeposit {
  id: string;
  amount: number;
  plan_days: BankPlanDays;
  yield_percent: number;
  /** amount * yield_percent / 100 — the full-term reward; paid out gradually as reward_paid, see below. */
  expected_reward: number;
  /** Whether THIS deposit is granting the +10% cycle-speed buff while active — decided once at creation (see the 14-day plan). */
  bonus_speed: boolean;
  /** Whether THIS deposit is granting the +1-slot buff while active — decided once at creation (see the 14-day plan). */
  bonus_slot: boolean;
  status: BankDepositStatus;
  starts_at: string;
  ends_at: string;
  /** How many daily installments have been credited so far — reaches plan_days exactly when status flips to 'claimed' on its own. */
  days_paid: number;
  /** Cumulative principal credited so far (of `amount`) — grows by ~amount/plan_days each server day. */
  principal_paid: number;
  /** Cumulative reward credited so far (of `expected_reward`) — grows by ~expected_reward/plan_days each server day. */
  reward_paid: number;
}

export type BoostStatus = "PENDING" | "ACTIVE" | "USED" | "EXPIRED";

export interface Boost {
  id: string;
  status: BoostStatus;
  source: string;
  target_tier: number | null;
  created_at: string;
  expires_at: string;
  activated_at: string | null;
}

export interface ComboCard {
  tier: number;
  name: string;
  name_i18n: Localized;
}

export interface ComboGuessCard extends ComboCard {
  correct: boolean;
}

export type ComboItemCategory = "time_skip" | "auto_collect";

/** Shared shape for a combo-drop item's rules — no quantity/expiry, that's InventoryItem's job. */
export interface ComboItemTemplate {
  item_type: string;
  category: ComboItemCategory;
  /** time_skip only — % of the tier's full cycle_hours shaved off on use. */
  effect_percent: number | null;
  /** auto_collect only — hours added to wallet.auto_collect_until on use. */
  effect_hours: number | null;
}

export interface ComboDropOdds extends ComboItemTemplate {
  drop_weight: number;
}

export interface InventoryItem extends ComboItemTemplate {
  quantity: number;
  /** Of the owned units, when the soonest one burns — burning drops quantity by exactly 1. */
  expires_at: string;
}

export interface DailyCombo {
  is_completed: boolean;
  attempts_used: number;
  attempts_max: number;
  slot_count: number;
  resets_at: string;
  /** Always-visible candidate list — a free minigame, not gated by unlocks. */
  pool: ComboCard[];
  /** Last submitted guess with per-position correctness, or null before any attempt. */
  last_guess: ComboGuessCard[] | null;
  /** The secret combo, only ever populated once is_completed is true. */
  revealed_tiers: ComboCard[] | null;
  /** The full drop table, for showing odds before playing. */
  possible_drops: ComboDropOdds[];
  /** What today's win actually granted — null until won. */
  reward_item: ComboItemTemplate | null;
}

export interface TierState {
  tier: number;
  name: string;
  description: string | null;
  name_i18n: Localized;
  description_i18n: Localized;
  price: number;
  payout_percent: number;
  cycle_hours: number;
  unlocked: boolean;
  completed_cycles: number;
  unlock_required_cycles: number;
  unlock_min_hours: number;
  unlocked_at: string | null;
  /** Per-item slot progression: min(slots_max, 3 + floor(completed_cycles / 5)), isolated per tier. */
  slots_open: number;
  slots_used: number;
  slots_max: number;
  cycles_to_next_slot: number | null;
  can_buy_max: boolean;
  /** Extra capacity from ACTIVE boosts on this tier, on top of (not capped by) slots_max. */
  slots_boost: number;
  /** Extra capacity from an active Bank deposit's +1-slot buff — flat across every tier, see bank_buffs.slot_boost. */
  slots_bank_bonus: number;
  slots_total: number;
}

export interface ActiveCycle {
  id: string;
  tier: number;
  started_at: string;
  ends_at: string;
  amount_in: number;
  slot_quantity: number;
  seconds_remaining: number;
}

export interface Quest {
  id: string;
  title: string;
  description: string | null;
  title_i18n: Localized;
  description_i18n: Localized;
  target_count: number;
  progress_count: number;
  reward_amount: number;
  grants_boost: boolean;
  completed_at: string | null;
  claimed_at: string | null;
}

export interface Container {
  id: string;
  code: string;
  name: string;
  obtained_at: string;
  opens_at: string;
  opened_at: string | null;
  reward_amount: number | null;
}

export type PartnerTaskKind = "partner" | "ambassador";
/** 'telegram_channel' = the classic subscribe-and-check flow; 'external_api' = another app's task, verified via a signed postback instead — see partner-webhook.ts. */
export type PartnerTaskVerificationMethod = "telegram_channel" | "external_api";

export interface PartnerTask {
  id: string;
  title: string;
  description: string | null;
  reward_amount: number;
  /** Set when the task pays out a boost item instead of GRAM — reward_amount is 0 in that case. */
  reward_item_type: string | null;
  reward_item_qty: number;
  channel_username: string | null;
  icon_url: string | null;
  /** 'ambassador' = channel run by one of our ambassadors ("Смотрящие" tab); 'partner' = everyone else ("Связи на районе"). */
  kind: PartnerTaskKind;
  verification_method: PartnerTaskVerificationMethod;
  /** Reward actually paid — not just subscription-verified, see verified_at/available_at. */
  completed: boolean;
  /** When the subscription check first passed, if it has. */
  verified_at: string | null;
  /** verified_at + 24h — the "Проверить" button stays disabled until this passes. Null once not yet verified, or once completed. */
  available_at: string | null;
}

export type SystemTaskCategory = "social" | "referral" | "gameplay";
export type SystemTaskTargetType =
  | "referrals_level_1"
  | "cycles_completed"
  | "tier_reached"
  | "channel_sub"
  | "chat_join"
  | "post_view";

export interface SystemTaskReward {
  item_type: string;
  quantity: number;
}

export interface SystemTask {
  id: string;
  slug: string;
  title: string;
  description: string | null;
  category: SystemTaskCategory;
  target_type: SystemTaskTargetType;
  /** Channel/chat username for the two verified social types; the tier number (as text) for tier_reached. */
  target_value: string | null;
  /** The referral/cycle count target — 1 for social tasks (nothing to count, just done/not-done). */
  required_count: number;
  /** Live-computed current progress toward required_count. */
  progress: number;
  reward_xp: number;
  rewards: SystemTaskReward[];
  /** Reward actually paid — for channel_sub/chat_join this is 24h after verified_at, not immediate. */
  completed: boolean;
  /** When a channel_sub/chat_join check first passed, if it has. Null for every other target_type. */
  verified_at: string | null;
  /** verified_at + 24h — the check button stays disabled until this passes. Null once not yet verified, or once completed. */
  available_at: string | null;
}

export interface HistoryEntry {
  type: "cycle" | "referral" | "deposit" | "withdraw";
  tier: number | null;
  amount: number;
  fee: number | null;
  net_amount: number | null;
  created_at: string;
}

export interface WalletConfig {
  deposit_min: number;
  withdraw_min: number;
  withdraw_fee_percent: number;
}

export interface PendingWithdrawal {
  id: string;
  amount: number;
  fee: number;
  net_amount: number;
  created_at: string;
}

export interface SquadReferralMember {
  user_id: string;
  display_name: string;
  photo_url: string | null;
  joined_at: string;
  /** Sum of amount_in across all their cycles this season — the base their referral bonus was paid on. */
  total_deposited: number;
  /** GRAM this specific referral has paid *you* at this level, this season. */
  earned_from: number;
}

/** One of the 3 referral lines (get_squad_levels) — fetched on demand by the Squad screen, not part of PlayerState. */
export interface SquadLevel {
  level: number;
  /** This level's payout percent — already ambassador-adjusted. */
  percent: number;
  referred_count: number;
  total_deposits: number;
  earned_total: number;
  referrals: SquadReferralMember[];
  /** True if referred_count exceeds referrals.length — the list was capped, the count wasn't. */
  truncated: boolean;
}
