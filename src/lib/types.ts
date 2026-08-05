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
  squad: {
    invite_code: string;
    referred_count: number;
    earned_total: number;
    /** Boosted referral rates (15/9/5% vs standard 10/5/2%) apply when this is true. */
    is_ambassador: boolean;
  };
  daily_combo: DailyCombo | null;
  boosts: Boost[];
  inventory: InventoryItem[];
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

export interface PartnerTask {
  id: string;
  title: string;
  description: string | null;
  reward_amount: number;
  channel_username: string;
  icon_url: string | null;
  completed: boolean;
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
