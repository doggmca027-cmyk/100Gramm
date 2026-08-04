-- 100ГРАМ: core schema. Season-agnostic — Season 2+ is new rows, not new tables.
-- All access is server-side via the service role key; RLS is enabled with no
-- policies as defense-in-depth (deny-by-default for anon/authenticated).

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- seasons
-- ---------------------------------------------------------------------------
create table seasons (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title text not null,
  story_theme text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  is_active boolean not null default false,
  -- base_slots, cycles_per_slot, max_slots (nullable = uncapped), features: {clans, map, bank, black_market}
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Only one active season at a time.
create unique index seasons_single_active on seasons ((is_active)) where is_active;

-- ---------------------------------------------------------------------------
-- product_templates — the 8 tiers, priced/timed per season
-- ---------------------------------------------------------------------------
create table product_templates (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references seasons(id) on delete cascade,
  tier smallint not null check (tier > 0),
  name text not null,
  price numeric(12, 2) not null check (price > 0),
  payout_percent numeric(5, 2) not null check (payout_percent >= 0),
  cycle_hours numeric(6, 2) not null check (cycle_hours > 0),
  unlock_required_cycles integer not null default 0,
  unlock_min_hours numeric(8, 2) not null default 0,
  sort_order integer not null,
  unique (season_id, tier)
);

-- ---------------------------------------------------------------------------
-- ranks — story rank ladder (🥴 Бомж -> 👑 Император)
-- ---------------------------------------------------------------------------
create table ranks (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references seasons(id) on delete cascade,
  min_earned numeric(14, 2) not null default 0,
  name text not null,
  icon text,
  slot_bonus integer not null default 0,
  sort_order integer not null,
  unique (season_id, sort_order)
);

-- ---------------------------------------------------------------------------
-- quest_templates — daily "срочные заказы"
-- ---------------------------------------------------------------------------
create table quest_templates (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references seasons(id) on delete cascade,
  code text not null,
  title text not null,
  description text,
  target_count integer not null check (target_count > 0),
  reward_amount numeric(12, 2) not null default 0,
  is_daily boolean not null default true,
  unique (season_id, code)
);

-- ---------------------------------------------------------------------------
-- container_templates — 🗑 Мусорный / 📦 Старый / 🔒 Закрытый / 💎 Золотой
-- ---------------------------------------------------------------------------
create table container_templates (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references seasons(id) on delete cascade,
  code text not null,
  name text not null,
  open_duration_minutes integer not null default 60,
  reward_min numeric(12, 2) not null,
  reward_max numeric(12, 2) not null check (reward_max >= reward_min),
  drop_weight integer not null default 1,
  unique (season_id, code)
);

-- ---------------------------------------------------------------------------
-- users
-- ---------------------------------------------------------------------------
create table users (
  id uuid primary key default gen_random_uuid(),
  telegram_id bigint not null unique,
  username text,
  first_name text,
  referred_by uuid references users(id),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- user_seasons — one row per (player, season): wallet + slots + intro flag
-- ---------------------------------------------------------------------------
create table user_seasons (
  user_id uuid not null references users(id) on delete cascade,
  season_id uuid not null references seasons(id) on delete cascade,
  slots_count integer not null default 3,
  completed_cycles_total integer not null default 0,
  balance numeric(14, 2) not null default 0,
  -- lifetime GRAM earned (cycles + referrals + containers + quests); never decreases, drives rank
  total_earned numeric(14, 2) not null default 0,
  has_seen_intro boolean not null default false,
  rank_id uuid references ranks(id),
  joined_at timestamptz not null default now(),
  primary key (user_id, season_id)
);

-- ---------------------------------------------------------------------------
-- user_tier_progress — source of truth for tier-unlock gating
-- ---------------------------------------------------------------------------
create table user_tier_progress (
  user_id uuid not null references users(id) on delete cascade,
  season_id uuid not null references seasons(id) on delete cascade,
  tier smallint not null,
  completed_cycles integer not null default 0,
  unlocked_at timestamptz not null default now(),
  primary key (user_id, season_id, tier)
);

-- ---------------------------------------------------------------------------
-- cycles — active + historical, one row per run
-- ---------------------------------------------------------------------------
create table cycles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  season_id uuid not null references seasons(id) on delete cascade,
  tier smallint not null,
  status text not null default 'running' check (status in ('running', 'claimed')),
  started_at timestamptz not null default now(),
  ends_at timestamptz not null,
  amount_in numeric(12, 2) not null,
  amount_out numeric(12, 2),
  claimed_at timestamptz
);

create index cycles_due_idx on cycles (user_id, season_id, status, ends_at);

-- ---------------------------------------------------------------------------
-- referral_earnings — log of the 3-level virality-loop bonuses
-- ---------------------------------------------------------------------------
create table referral_earnings (
  id uuid primary key default gen_random_uuid(),
  beneficiary_id uuid not null references users(id) on delete cascade,
  source_user_id uuid not null references users(id) on delete cascade,
  level smallint not null check (level in (1, 2, 3)),
  cycle_id uuid references cycles(id) on delete set null,
  amount numeric(12, 2) not null,
  created_at timestamptz not null default now()
);

create index referral_earnings_beneficiary_idx on referral_earnings (beneficiary_id);

-- ---------------------------------------------------------------------------
-- user_quest_progress — daily quest progress, reset by quest_date
-- ---------------------------------------------------------------------------
create table user_quest_progress (
  user_id uuid not null references users(id) on delete cascade,
  quest_id uuid not null references quest_templates(id) on delete cascade,
  season_id uuid not null references seasons(id) on delete cascade,
  quest_date date not null default current_date,
  progress_count integer not null default 0,
  completed_at timestamptz,
  claimed_at timestamptz,
  primary key (user_id, quest_id, quest_date)
);

-- ---------------------------------------------------------------------------
-- user_containers
-- ---------------------------------------------------------------------------
create table user_containers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  season_id uuid not null references seasons(id) on delete cascade,
  container_template_id uuid not null references container_templates(id),
  obtained_at timestamptz not null default now(),
  opens_at timestamptz not null,
  opened_at timestamptz,
  reward_amount numeric(12, 2)
);

create index user_containers_user_idx on user_containers (user_id, season_id, opened_at);

-- ---------------------------------------------------------------------------
-- RLS: enabled everywhere, no policies -> only the service role (which
-- bypasses RLS) can read/write. The browser never holds Supabase credentials.
-- ---------------------------------------------------------------------------
alter table seasons enable row level security;
alter table product_templates enable row level security;
alter table ranks enable row level security;
alter table quest_templates enable row level security;
alter table container_templates enable row level security;
alter table users enable row level security;
alter table user_seasons enable row level security;
alter table user_tier_progress enable row level security;
alter table cycles enable row level security;
alter table referral_earnings enable row level security;
alter table user_quest_progress enable row level security;
alter table user_containers enable row level security;
