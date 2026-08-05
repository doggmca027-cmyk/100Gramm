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
    slots_count: number;
    completed_cycles_total: number;
    has_seen_intro: boolean;
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
  };
  daily_combo: DailyCombo | null;
}

export interface DailyComboSlot {
  found: boolean;
  tier?: number;
  name?: string;
  name_i18n?: Localized;
}

export interface DailyCombo {
  reward_amount: number;
  is_completed: boolean;
  found_count: number;
  total_count: number;
  resets_at: string;
  slots: DailyComboSlot[];
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
  type: "cycle" | "referral";
  tier: number;
  amount: number;
  created_at: string;
}
