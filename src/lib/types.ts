export interface PlayerState {
  season: {
    id: string;
    slug: string;
    title: string;
    story_theme: string | null;
    starts_at: string;
    ends_at: string;
    config: {
      base_slots: number;
      cycles_per_slot: number;
      max_slots: number | null;
      features?: Record<string, boolean>;
    };
  };
  wallet: {
    balance: number;
    total_earned: number;
    slots_count: number;
    completed_cycles_total: number;
    has_seen_intro: boolean;
  };
  rank: { name: string; icon: string | null } | null;
  tiers: TierState[];
  active_cycles: ActiveCycle[];
  quests: Quest[];
  containers: Container[];
  squad: {
    invite_code: string;
    referred_count: number;
    earned_total: number;
  };
}

export interface TierState {
  tier: number;
  name: string;
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
  seconds_remaining: number;
}

export interface Quest {
  id: string;
  title: string;
  description: string | null;
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
