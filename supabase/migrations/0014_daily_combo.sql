-- 100ГРАМ: Daily Combo (🎮 Игры tab) — a Hamster-Kombat-style daily guessing
-- game reusing our existing 8 product tiers as "cards" (no separate cards
-- table — the tiers already are the game's ownable/purchasable items).
--
-- Each UTC day, 4 of the season's tiers are secretly picked as "today's
-- combo" (same for every player). Starting a cycle on a tier that happens
-- to be in today's combo reveals that slot; once all 4 are found, a fixed
-- reward is paid automatically. Generation is lazy (ensure_daily_combo,
-- called from get_player_state and the admin routes) so it's correct even
-- if the optional pg_cron job below never runs — that's just a convenience
-- so the combo exists right at 00:00 UTC without waiting on a request.

create table daily_combo (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references seasons(id) on delete cascade,
  combo_date date not null,
  tiers smallint[] not null,
  reward_amount numeric(12, 2) not null default 5,
  created_at timestamptz not null default now(),
  unique (season_id, combo_date)
);

create table user_combo_progress (
  user_id uuid not null references users(id) on delete cascade,
  season_id uuid not null references seasons(id) on delete cascade,
  combo_date date not null,
  found_tiers smallint[] not null default '{}',
  is_completed boolean not null default false,
  completed_at timestamptz,
  primary key (user_id, season_id, combo_date)
);

alter table daily_combo enable row level security;
alter table user_combo_progress enable row level security;

-- ---------------------------------------------------------------------------
-- ensure_daily_combo — returns today's combo row, creating it (4 random
-- distinct tiers) if it doesn't exist yet. Race-safe via ON CONFLICT.
-- ---------------------------------------------------------------------------
create or replace function ensure_daily_combo(p_season_id uuid)
returns daily_combo
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row daily_combo;
  v_today date := (now() at time zone 'utc')::date;
begin
  select * into v_row from daily_combo where season_id = p_season_id and combo_date = v_today;
  if found then
    return v_row;
  end if;

  insert into daily_combo (season_id, combo_date, tiers)
  select p_season_id, v_today,
    (select array_agg(tier) from (
      select tier from product_templates
      where season_id = p_season_id
      order by random()
      limit 4
    ) t)
  on conflict (season_id, combo_date) do nothing;

  select * into v_row from daily_combo where season_id = p_season_id and combo_date = v_today;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- regenerate_daily_combo — admin action: fresh random 4, wipes today's
-- player progress (it was progress against the old combo)
-- ---------------------------------------------------------------------------
create or replace function regenerate_daily_combo(p_season_id uuid)
returns daily_combo
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_row daily_combo;
begin
  delete from user_combo_progress where season_id = p_season_id and combo_date = v_today;

  update daily_combo
  set tiers = (
    select array_agg(tier) from (
      select tier from product_templates
      where season_id = p_season_id
      order by random()
      limit 4
    ) t
  )
  where season_id = p_season_id and combo_date = v_today
  returning * into v_row;

  if v_row.id is null then
    v_row := ensure_daily_combo(p_season_id);
  end if;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- set_daily_combo_tiers — admin action: manually pick today's 4 tiers
-- ---------------------------------------------------------------------------
create or replace function set_daily_combo_tiers(p_season_id uuid, p_tiers smallint[])
returns daily_combo
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_row daily_combo;
  v_valid_count integer;
begin
  if array_length(p_tiers, 1) is distinct from 4 or
     (select count(distinct t) from unnest(p_tiers) t) <> 4 then
    raise exception 'invalid_combo_tiers';
  end if;

  select count(*) into v_valid_count
  from product_templates
  where season_id = p_season_id and tier = any(p_tiers);
  if v_valid_count <> 4 then
    raise exception 'invalid_combo_tiers';
  end if;

  perform ensure_daily_combo(p_season_id);
  delete from user_combo_progress where season_id = p_season_id and combo_date = v_today;

  update daily_combo set tiers = p_tiers
  where season_id = p_season_id and combo_date = v_today
  returning * into v_row;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- Optional: proactively generate right at 00:00 UTC for the active season.
-- Not required for correctness (ensure_daily_combo is called lazily by
-- get_player_state/admin routes too) — just means the admin doesn't have to
-- wait for the first player request before seeing the new combo to shill.
-- ---------------------------------------------------------------------------
do $$
begin
  create extension if not exists pg_cron;

  perform cron.schedule(
    'daily-combo-midnight-utc',
    '1 0 * * *',
    $cron$select ensure_daily_combo(id) from seasons where is_active$cron$
  );
exception when others then
  raise notice 'pg_cron not available on this project — relying on lazy generation only: %', sqlerrm;
end $$;
