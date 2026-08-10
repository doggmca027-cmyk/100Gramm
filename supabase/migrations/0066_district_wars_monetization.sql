-- District Wars monetization: Battle Boosts, gang customization, paid
-- co-leader slots + mercenary bot, VIP treasury staking.
--
-- Deviations from the literal spec, same reasoning as every earlier
-- migration this feature has needed:
--   * "TON" throughout the spec means the same thing it's meant in every
--     other gang cost this session ("5 TON" for create_gang, "1 GRAM per
--     +5 slots" for upgrade_gang_capacity, etc.) -- GRAM *is* TON in this
--     game's economy, there's no second currency or real on-chain
--     payment here. Every "N TON" price below is N deducted from
--     user_seasons.balance or gangs.bank_balance_gram, same as always.
--   * activate_district_boost's spec signature omits a caller identity
--     parameter. Every RPC in this schema takes an explicit p_user_id,
--     trusted only because the calling Next.js route already ran
--     requireUserId() server-side -- this app has no Supabase Auth
--     session for a policy to key off instead (see 0058_gangs.sql's
--     header for the long version). Added here too, first positional
--     param, matching every other privileged RPC.
--   * Several prices the spec leaves unstated (mercenary bot cost, the
--     specific cosmetics on offer) are my own calls, documented at each
--     one below rather than silently invented.
--
-- Design decisions not spelled out in the spec:
--   * Boosts are scoped per (district, gang) -- activate_district_boost's
--     own signature takes p_district_id, so even airstrike (which reads
--     as gang-wide in the spec's prose) only multiplies that gang's
--     points toward that one district. A gang can only ever fight one
--     district at a time anyway (target_district_id), so this is rarely
--     a practical difference.
--   * Only the district's current defender may buy engineer_shield --
--     buying a freeze on "the opponent" only makes sense from the
--     defender's chair; an attacker has no opponent-side points of their
--     own to freeze.
--   * airstrike boosts a gang's OWN scoring (attack or defense, whichever
--     role they're currently in for that district) by their multiplier;
--     shield only blocks attacker-side accrual for that district,
--     regardless of who bought it -- the two never conflict, a gang can
--     hold one of each at once, but only one active boost per (district,
--     gang, family) at a time (spec: "не допускать активирование щита,
--     если щит уже активен" -- applied to both families, not just shield).
--   * Boosts and the mercenary bot can only be activated while the
--     district's battle window is currently active -- buying a
--     time-limited effect during peace time would just burn part or all
--     of its duration before it could ever matter, which is bad for
--     player trust (and this feature exists to build trust in spending
--     real money here, not erode it).
--   * The mercenary bot's target district doesn't have to match the
--     gang's existing target_district_id -- activating it registers the
--     gang for that district's battle itself (same upsert
--     request_district_attack already does), so it works as a
--     stand-alone "enter and auto-fight" purchase.
--   * VIP treasury interest is a daily lazy catch-up computed off the
--     bank's *current* balance each time (elapsed whole UTC days since
--     last accrual x apy/365), same "resolve on read/write, not on a
--     schedule" posture as everything else here -- not day-by-day
--     compounding, a deliberately simple approximation documented on
--     resolve_due_gang_bank_interest below.

alter table gangs
  add column co_leader_slots integer not null default 1,
  add column premium_avatar_id text,
  add column frame_id text,
  add column vip_treasury boolean not null default false,
  add column bank_interest_accrued_date date not null default current_date;

-- ---------------------------------------------------------------------------
-- gang_cosmetics_catalog — the customization shop's fixed catalog.
-- `glow` is a client-side rendering hint only (which box-shadow/gradient
-- to use), not interpreted by any RPC.
-- ---------------------------------------------------------------------------
create table gang_cosmetics_catalog (
  code text primary key,
  cosmetic_type text not null check (cosmetic_type in ('avatar', 'frame')),
  name text not null,
  price numeric(10, 2) not null,
  glow text not null,
  created_at timestamptz not null default now()
);

alter table gangs
  add constraint gangs_premium_avatar_id_fkey foreign key (premium_avatar_id) references gang_cosmetics_catalog(code),
  add constraint gangs_frame_id_fkey foreign key (frame_id) references gang_cosmetics_catalog(code);

insert into gang_cosmetics_catalog (code, cosmetic_type, name, price, glow) values
  ('golden_crown', 'avatar', 'Золотая корона', 10, 'gold'),
  ('diamond_skull', 'avatar', 'Алмазный череп', 8, 'diamond'),
  ('phoenix', 'avatar', 'Феникс', 6, 'fire'),
  ('neon_gold', 'frame', 'Золотая неоновая рамка', 5, 'gold'),
  ('neon_purple', 'frame', 'Фиолетовая неоновая рамка', 3, 'neon_purple'),
  ('neon_red', 'frame', 'Красная неоновая рамка', 2, 'neon_red');

-- ---------------------------------------------------------------------------
-- district_battle_boosts — one row per activation; multiple historical
-- rows accumulate per (district, gang, family), only the latest
-- unexpired one is ever "active" (checked by expires_at > now(), not a
-- status flag -- same "derive it, don't store a copy" call as
-- district_battle_status()).
-- ---------------------------------------------------------------------------
create table district_battle_boosts (
  id uuid primary key default gen_random_uuid(),
  district_id uuid not null references districts(id) on delete cascade,
  gang_id uuid not null references gangs(id) on delete cascade,
  boost_family text not null check (boost_family in ('airstrike', 'shield')),
  boost_type text not null check (boost_type in ('airstrike_2x', 'airstrike_3x', 'engineer_shield')),
  multiplier numeric(3, 1),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index district_battle_boosts_lookup_idx on district_battle_boosts (district_id, gang_id, boost_family, expires_at);
alter table district_battle_boosts enable row level security;

-- ---------------------------------------------------------------------------
-- district_mercenary_bots — one row per (district, gang, battle_date),
-- ticked hourly by resolve_due_mercenary_bots.
-- ---------------------------------------------------------------------------
create table district_mercenary_bots (
  id uuid primary key default gen_random_uuid(),
  district_id uuid not null references districts(id) on delete cascade,
  gang_id uuid not null references gangs(id) on delete cascade,
  battle_date date not null,
  hourly_points integer not null default 50,
  last_tick_at timestamptz not null default now(),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (district_id, gang_id, battle_date)
);

create index district_mercenary_bots_due_idx on district_mercenary_bots (expires_at) where last_tick_at < expires_at;
alter table district_mercenary_bots enable row level security;

-- ---------------------------------------------------------------------------
-- resolve_due_gang_bank_interest — daily lazy catch-up on the gang bank's
-- own passive yield (10% APY base, 30% after purchase_vip_treasury).
-- Simple, non-compounding-within-the-call approximation: interest for
-- the whole elapsed-days gap is computed once off today's balance, not
-- accrued day-by-day -- deliberately simple, documented in this
-- migration's header. Called before every bank-balance check elsewhere
-- (donate/dividends/capacity-upgrade/disband) so spending always sees an
-- up-to-date balance, and from get_player_state for the caller's own gang.
-- ---------------------------------------------------------------------------
create or replace function resolve_due_gang_bank_interest(p_gang_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance numeric(14, 2);
  v_vip boolean;
  v_accrued_date date;
  v_elapsed_days integer;
  v_apy numeric(5, 2);
  v_interest numeric(14, 2);
begin
  select bank_balance_gram, vip_treasury, bank_interest_accrued_date
  into v_balance, v_vip, v_accrued_date
  from gangs where id = p_gang_id for update;

  if not found then
    return;
  end if;

  v_elapsed_days := ((now() at time zone 'utc')::date - v_accrued_date);
  if v_elapsed_days <= 0 or v_balance <= 0 then
    update gangs set bank_interest_accrued_date = (now() at time zone 'utc')::date where id = p_gang_id;
    return;
  end if;

  v_apy := case when v_vip then 30 else 10 end;
  v_interest := round(v_balance * (v_apy / 100) * (v_elapsed_days::numeric / 365), 2);

  update gangs
  set bank_balance_gram = bank_balance_gram + v_interest,
      bank_balance_ton = bank_balance_ton + v_interest,
      bank_interest_accrued_date = (now() at time zone 'utc')::date
  where id = p_gang_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- purchase_vip_treasury — leader-only, one-time, 10 TON from the
-- leader's own personal balance (this is the leader personally investing
-- in the syndicate's infrastructure, same posture as
-- purchase_co_leader_slot below).
-- ---------------------------------------------------------------------------
create or replace function purchase_vip_treasury(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cost constant numeric := 10;
  v_gang_id uuid;
  v_role text;
  v_season_id uuid;
  v_balance numeric(14, 2);
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  if (select vip_treasury from gangs where id = v_gang_id) then
    raise exception 'already_vip';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select balance into v_balance from user_seasons
  where user_id = p_user_id and season_id = v_season_id for update;
  if v_balance is null then
    raise exception 'no_active_season';
  end if;
  if v_balance < v_cost then
    raise exception 'insufficient_balance';
  end if;

  update user_seasons set balance = balance - v_cost
  where user_id = p_user_id and season_id = v_season_id;

  perform resolve_due_gang_bank_interest(v_gang_id);
  update gangs set vip_treasury = true where id = v_gang_id;

  return jsonb_build_object('gang_id', v_gang_id, 'vip_treasury', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- purchase_co_leader_slot — leader-only, 3 TON from the leader's own
-- balance, no cap on repeat purchases (same "no upper bound" posture as
-- upgrade_gang_capacity).
-- ---------------------------------------------------------------------------
create or replace function purchase_co_leader_slot(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cost constant numeric := 3;
  v_gang_id uuid;
  v_role text;
  v_season_id uuid;
  v_balance numeric(14, 2);
  v_new_slots integer;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select balance into v_balance from user_seasons
  where user_id = p_user_id and season_id = v_season_id for update;
  if v_balance is null then
    raise exception 'no_active_season';
  end if;
  if v_balance < v_cost then
    raise exception 'insufficient_balance';
  end if;

  update user_seasons set balance = balance - v_cost
  where user_id = p_user_id and season_id = v_season_id;

  update gangs set co_leader_slots = co_leader_slots + 1
  where id = v_gang_id
  returning co_leader_slots into v_new_slots;

  return jsonb_build_object('gang_id', v_gang_id, 'co_leader_slots', v_new_slots);
end;
$$;

-- ---------------------------------------------------------------------------
-- purchase_gang_cosmetic — leader-only, personal balance. Sets
-- premium_avatar_id or frame_id depending on the catalog entry's type;
-- buying a new one of the same type simply replaces the old one (no
-- refund, no inventory of owned-but-unequipped cosmetics in this MVP).
-- ---------------------------------------------------------------------------
create or replace function purchase_gang_cosmetic(p_user_id uuid, p_cosmetic_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gang_id uuid;
  v_role text;
  v_season_id uuid;
  v_balance numeric(14, 2);
  v_cosmetic gang_cosmetics_catalog%rowtype;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  select * into v_cosmetic from gang_cosmetics_catalog where code = p_cosmetic_code;
  if not found then
    raise exception 'cosmetic_not_found';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select balance into v_balance from user_seasons
  where user_id = p_user_id and season_id = v_season_id for update;
  if v_balance is null then
    raise exception 'no_active_season';
  end if;
  if v_balance < v_cosmetic.price then
    raise exception 'insufficient_balance';
  end if;

  update user_seasons set balance = balance - v_cosmetic.price
  where user_id = p_user_id and season_id = v_season_id;

  if v_cosmetic.cosmetic_type = 'avatar' then
    update gangs set premium_avatar_id = p_cosmetic_code where id = v_gang_id;
  else
    update gangs set frame_id = p_cosmetic_code where id = v_gang_id;
  end if;

  return jsonb_build_object('gang_id', v_gang_id, 'cosmetic_code', p_cosmetic_code, 'cosmetic_type', v_cosmetic.cosmetic_type);
end;
$$;

-- ---------------------------------------------------------------------------
-- activate_district_boost — leader-or-co_leader-only. p_pay_from_bank
-- picks the funding source (own balance vs the gang's bank, which gets
-- its own interest resolved first so the check sees an up-to-date
-- number). Only while the district's battle window is active (see
-- header); rejects a second activation of the same family while one's
-- still running; engineer_shield additionally requires the caller's gang
-- to currently be that district's defender.
-- ---------------------------------------------------------------------------
create or replace function activate_district_boost(
  p_user_id uuid,
  p_district_id uuid,
  p_boost_type text,
  p_pay_from_bank boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gang_id uuid;
  v_role text;
  v_district districts%rowtype;
  v_cost numeric(10, 2);
  v_family text;
  v_multiplier numeric(3, 1);
  v_duration interval;
  v_season_id uuid;
  v_balance numeric(14, 2);
  v_expires_at timestamptz;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_role not in ('leader', 'co_leader') then
    raise exception 'not_gang_officer';
  end if;

  -- A second lock keyed on (district, gang) rather than the caller: the
  -- leader and a co_leader are two different p_user_id values, so the
  -- lock above alone doesn't stop them from both passing the
  -- "not already active" check below in the same instant and both
  -- getting charged for what only ends up looking like one active boost
  -- (district_battle_boosts has no unique constraint to catch this at
  -- the database level either -- it's an append-only history table by
  -- design). This closes that window regardless of which two officers
  -- are racing.
  perform pg_advisory_xact_lock(hashtext(p_district_id::text || ':' || v_gang_id::text));

  select * into v_district from districts where id = p_district_id;
  if not found then
    raise exception 'district_not_found';
  end if;

  if district_battle_status(v_district.window_start_time, v_district.window_end_time) <> 'active' then
    raise exception 'battle_not_active';
  end if;

  case p_boost_type
    when 'airstrike_2x' then
      v_family := 'airstrike'; v_cost := 2; v_multiplier := 2.0; v_duration := interval '2 hours';
    when 'airstrike_3x' then
      v_family := 'airstrike'; v_cost := 5; v_multiplier := 3.0; v_duration := interval '2 hours';
    when 'engineer_shield' then
      v_family := 'shield'; v_cost := 3; v_multiplier := null; v_duration := interval '20 minutes';
      if v_district.controlling_gang_id is distinct from v_gang_id then
        raise exception 'not_district_defender';
      end if;
    else
      raise exception 'invalid_boost_type';
  end case;

  if exists (
    select 1 from district_battle_boosts
    where district_id = p_district_id and gang_id = v_gang_id and boost_family = v_family and expires_at > now()
  ) then
    raise exception 'boost_already_active';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  if p_pay_from_bank then
    perform resolve_due_gang_bank_interest(v_gang_id);
    select bank_balance_gram into v_balance from gangs where id = v_gang_id for update;
    if v_balance < v_cost then
      raise exception 'insufficient_gang_bank';
    end if;
    update gangs set bank_balance_gram = bank_balance_gram - v_cost, bank_balance_ton = bank_balance_ton - v_cost
    where id = v_gang_id;
  else
    select balance into v_balance from user_seasons
    where user_id = p_user_id and season_id = v_season_id for update;
    if v_balance is null then
      raise exception 'no_active_season';
    end if;
    if v_balance < v_cost then
      raise exception 'insufficient_balance';
    end if;
    update user_seasons set balance = balance - v_cost
    where user_id = p_user_id and season_id = v_season_id;
  end if;

  v_expires_at := now() + v_duration;

  insert into district_battle_boosts (district_id, gang_id, boost_family, boost_type, multiplier, expires_at)
  values (p_district_id, v_gang_id, v_family, p_boost_type, v_multiplier, v_expires_at);

  return jsonb_build_object(
    'gang_id', v_gang_id, 'district_id', p_district_id, 'boost_type', p_boost_type, 'expires_at', v_expires_at
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- activate_mercenary_bot — leader-or-co_leader-only, 8 TON (this
-- migration's own call -- the spec left the price unstated; priced above
-- engineer_shield/most airstrikes since it's pure guaranteed points with
-- zero further effort, up to 12h x 50/h = 600 points at the extreme).
-- Only while the window is active, one per (district, gang, battle_date)
-- -- a second purchase the same day is rejected outright rather than
-- stacking or refunding, simplest safe behavior. Registers the gang for
-- this district's battle the same way request_district_attack does, so
-- it works standalone even if they never applied manually.
-- ---------------------------------------------------------------------------
create or replace function activate_mercenary_bot(p_user_id uuid, p_district_id uuid, p_pay_from_bank boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cost constant numeric := 8;
  v_gang_id uuid;
  v_role text;
  v_district districts%rowtype;
  v_battle_date date;
  v_season_id uuid;
  v_balance numeric(14, 2);
  v_expires_at timestamptz;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_role not in ('leader', 'co_leader') then
    raise exception 'not_gang_officer';
  end if;

  -- Same (district, gang) lock as activate_district_boost, same reason:
  -- the leader and a co_leader are different p_user_id values and would
  -- otherwise both pass the "not already hired today" check below at
  -- once. district_mercenary_bots' unique(district_id, gang_id,
  -- battle_date) constraint would catch the resulting double-insert, but
  -- only as a raw constraint-violation error after the balance was
  -- already checked -- this lock makes the race resolve to the clean
  -- 'mercenary_already_active' rejection instead.
  perform pg_advisory_xact_lock(hashtext(p_district_id::text || ':' || v_gang_id::text));

  select * into v_district from districts where id = p_district_id;
  if not found then
    raise exception 'district_not_found';
  end if;

  if district_battle_status(v_district.window_start_time, v_district.window_end_time) <> 'active' then
    raise exception 'battle_not_active';
  end if;

  v_battle_date := district_battle_date(v_district.window_end_time);

  if exists (
    select 1 from district_mercenary_bots
    where district_id = p_district_id and gang_id = v_gang_id and battle_date = v_battle_date
  ) then
    raise exception 'mercenary_already_active';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  if p_pay_from_bank then
    perform resolve_due_gang_bank_interest(v_gang_id);
    select bank_balance_gram into v_balance from gangs where id = v_gang_id for update;
    if v_balance < v_cost then
      raise exception 'insufficient_gang_bank';
    end if;
    update gangs set bank_balance_gram = bank_balance_gram - v_cost, bank_balance_ton = bank_balance_ton - v_cost
    where id = v_gang_id;
  else
    select balance into v_balance from user_seasons
    where user_id = p_user_id and season_id = v_season_id for update;
    if v_balance is null then
      raise exception 'no_active_season';
    end if;
    if v_balance < v_cost then
      raise exception 'insufficient_balance';
    end if;
    update user_seasons set balance = balance - v_cost
    where user_id = p_user_id and season_id = v_season_id;
  end if;

  -- Same registration upsert request_district_attack does, so this works
  -- standalone even without a prior manual application.
  insert into district_battles (district_id, battle_date, defender_gang_id, defense_points)
  values (p_district_id, v_battle_date, v_district.controlling_gang_id, 0)
  on conflict (district_id, battle_date) do nothing;
  if v_district.controlling_gang_id is distinct from v_gang_id then
    insert into district_challenges (district_id, battle_date, gang_id, points)
    values (p_district_id, v_battle_date, v_gang_id, 0)
    on conflict (district_id, battle_date, gang_id) do nothing;
  end if;
  update gangs set target_district_id = p_district_id where id = v_gang_id;

  v_expires_at := (v_battle_date::timestamp + v_district.window_end_time) at time zone 'utc';

  insert into district_mercenary_bots (district_id, gang_id, battle_date, expires_at)
  values (p_district_id, v_gang_id, v_battle_date, v_expires_at);

  return jsonb_build_object('gang_id', v_gang_id, 'district_id', p_district_id, 'expires_at', v_expires_at);
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_due_mercenary_bots — global lazy catch-up, called from
-- get_player_state alongside resolve_due_district_battles. Credits
-- hourly_points per whole hour elapsed since the last tick (capped at
-- expires_at), routing to defense or attack the same way resolve_due_
-- cycles does -- including airstrike multipliers and the shield freeze,
-- via the shared helper below.
-- ---------------------------------------------------------------------------
create or replace function district_credit_battle_points(
  p_district_id uuid,
  p_gang_id uuid,
  p_battle_date date,
  p_base_points bigint
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_controller uuid;
  v_points bigint;
  v_multiplier numeric(3, 1);
begin
  select controlling_gang_id into v_controller from districts where id = p_district_id;

  select multiplier into v_multiplier
  from district_battle_boosts
  where district_id = p_district_id and gang_id = p_gang_id and boost_family = 'airstrike' and expires_at > now()
  order by expires_at desc limit 1;

  v_points := round(p_base_points * coalesce(v_multiplier, 1));

  if v_controller = p_gang_id then
    insert into district_battles (district_id, battle_date, defender_gang_id, defense_points)
    values (p_district_id, p_battle_date, p_gang_id, v_points)
    on conflict (district_id, battle_date) do update
      set defense_points = district_battles.defense_points + v_points;
  else
    if exists (
      select 1 from district_battle_boosts
      where district_id = p_district_id and boost_family = 'shield' and expires_at > now()
    ) then
      return; -- frozen -- attacker's points don't count while the shield holds
    end if;
    update district_challenges set points = points + v_points
    where district_id = p_district_id and battle_date = p_battle_date and gang_id = p_gang_id;
  end if;
end;
$$;

create or replace function resolve_due_mercenary_bots()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bot record;
  v_now timestamptz := now();
  v_tick_until timestamptz;
  v_elapsed_hours integer;
begin
  for v_bot in
    select * from district_mercenary_bots
    where last_tick_at < expires_at and last_tick_at < v_now
    for update skip locked
  loop
    v_tick_until := least(v_now, v_bot.expires_at);
    v_elapsed_hours := floor(extract(epoch from (v_tick_until - v_bot.last_tick_at)) / 3600);

    if v_elapsed_hours > 0 then
      perform district_credit_battle_points(
        v_bot.district_id, v_bot.gang_id, v_bot.battle_date, v_elapsed_hours::bigint * v_bot.hourly_points
      );
      update district_mercenary_bots
      set last_tick_at = v_bot.last_tick_at + (v_elapsed_hours || ' hours')::interval
      where id = v_bot.id;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- set_gang_member_role — one change from 0061_gang_donate_roles_kick.sql:
-- promoting to co_leader now checks gangs.co_leader_slots (1 free, more
-- via purchase_co_leader_slot). Demoting back to 'member' is unaffected.
-- Everything else byte-for-byte unchanged.
-- ---------------------------------------------------------------------------
create or replace function set_gang_member_role(p_user_id uuid, p_target_user_id uuid, p_role text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_gang_id uuid;
  v_caller_role text;
  v_target_gang_id uuid;
  v_target_role text;
  v_co_leader_slots integer;
  v_current_co_leaders integer;
begin
  if p_role not in ('co_leader', 'member') then
    raise exception 'invalid_role';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_caller_gang_id, v_caller_role
  from gang_members where user_id = p_user_id;
  if v_caller_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_caller_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  select gang_id, role into v_target_gang_id, v_target_role
  from gang_members where user_id = p_target_user_id for update;
  if v_target_gang_id is null or v_target_gang_id <> v_caller_gang_id then
    raise exception 'not_gang_member';
  end if;
  if v_target_role = 'leader' then
    raise exception 'cannot_change_leader_role';
  end if;

  if p_role = 'co_leader' and v_target_role <> 'co_leader' then
    select co_leader_slots into v_co_leader_slots from gangs where id = v_caller_gang_id;
    select count(*) into v_current_co_leaders from gang_members
    where gang_id = v_caller_gang_id and role = 'co_leader';
    if v_current_co_leaders >= v_co_leader_slots then
      raise exception 'co_leader_slots_full';
    end if;
  end if;

  update gang_members set role = p_role where user_id = p_target_user_id;

  return jsonb_build_object('user_id', p_target_user_id, 'role', p_role);
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_due_cycles — one change from 0065_district_wars_daily_battles.sql:
-- the district-points block now goes through district_credit_battle_points
-- instead of inlining the defense/attack insert-or-update, so airstrike
-- multipliers and the engineer_shield freeze apply to organic cycle
-- claims exactly the same way they apply to mercenary-bot ticks.
-- Everything else byte-for-byte unchanged.
-- ---------------------------------------------------------------------------
create or replace function resolve_due_cycles(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_cycle record;
  v_amount_out numeric(12, 2);
  v_payout_percent numeric(5, 2);
  v_containers_enabled boolean;
  v_max_tier smallint;
  v_tier_progress record;
  v_next_required_cycles integer;
  v_next_min_hours numeric(8, 2);
  v_claimed_count integer := 0;
  v_quest record;
  v_container_template_id uuid;
  v_open_minutes integer;
  v_updated_rows integer;
  v_gang_id uuid;
  v_target_district_id uuid;
  v_district_window_start time;
  v_district_window_end time;
  v_battle_date date;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    return;
  end if;

  select coalesce((config->'features'->>'containers')::boolean, false)
  into v_containers_enabled
  from seasons where id = v_season_id;

  select gm.gang_id, g.target_district_id into v_gang_id, v_target_district_id
  from gang_members gm
  join gangs g on g.id = gm.gang_id
  where gm.user_id = p_user_id;

  if v_target_district_id is not null then
    select window_start_time, window_end_time
    into v_district_window_start, v_district_window_end
    from districts where id = v_target_district_id;
  end if;

  for v_cycle in
    select c.* from cycles c
    where c.user_id = p_user_id
      and c.season_id = v_season_id
      and c.status = 'running'
      and c.ends_at <= now()
    order by c.ends_at asc
    for update of c skip locked
  loop
    select payout_percent into v_payout_percent
    from product_templates
    where season_id = v_season_id and tier = v_cycle.tier;

    v_amount_out := round(v_cycle.amount_in * (1 + v_payout_percent / 100), 2);

    update cycles
    set status = 'claimed', claimed_at = now(), amount_out = v_amount_out
    where id = v_cycle.id and status = 'running';

    get diagnostics v_updated_rows = row_count;
    if v_updated_rows = 0 then
      continue;
    end if;

    if v_cycle.boost_id is not null then
      update user_boosts set status = 'USED'
      where id = v_cycle.boost_id and status = 'ACTIVE';
    end if;

    update user_seasons
    set balance = balance + v_amount_out,
        total_earned = total_earned + v_amount_out,
        completed_cycles_total = completed_cycles_total + 1
    where user_id = p_user_id and season_id = v_season_id;

    update user_tier_progress
    set completed_cycles = completed_cycles + 1
    where user_id = p_user_id and season_id = v_season_id and tier = v_cycle.tier;

    v_claimed_count := v_claimed_count + 1;

    if v_gang_id is not null then
      update gangs
      set experience = experience + 1,
          level = greatest(1, ((experience + 1) / 100)::int + 1)
      where id = v_gang_id;

      update gangs
      set bank_balance_gram = bank_balance_gram + round(v_amount_out * 0.10, 2),
          bank_balance_ton = bank_balance_ton + round(v_amount_out * 0.10, 2)
      where id = v_gang_id;

      insert into gang_bank_transactions (gang_id, from_user_id, cycle_id, amount_gram, amount_ton)
      values (v_gang_id, p_user_id, v_cycle.id, round(v_amount_out * 0.10, 2), round(v_amount_out * 0.10, 2));

      if v_target_district_id is not null
         and district_battle_status(v_district_window_start, v_district_window_end) = 'active' then
        v_battle_date := district_battle_date(v_district_window_end);
        perform district_credit_battle_points(v_target_district_id, v_gang_id, v_battle_date, 10);
      end if;
    end if;

    if v_containers_enabled then
      select ct.id, ct.open_duration_minutes
      into v_container_template_id, v_open_minutes
      from container_templates ct
      where ct.season_id = v_season_id
      order by -ln(random()) / ct.drop_weight
      limit 1;

      if v_container_template_id is not null then
        insert into user_containers (user_id, season_id, container_template_id, obtained_at, opens_at)
        values (
          p_user_id, v_season_id, v_container_template_id, now(),
          now() + (v_open_minutes::text || ' minutes')::interval
        );
      end if;
    end if;
  end loop;

  loop
    select tier into v_max_tier
    from user_tier_progress
    where user_id = p_user_id and season_id = v_season_id
    order by tier desc limit 1;

    select * into v_tier_progress
    from user_tier_progress
    where user_id = p_user_id and season_id = v_season_id and tier = v_max_tier;

    select pt.unlock_required_cycles, pt.unlock_min_hours
    into v_next_required_cycles, v_next_min_hours
    from product_templates pt
    where pt.season_id = v_season_id and pt.tier = v_max_tier;

    exit when v_next_required_cycles is null
      or v_tier_progress.completed_cycles < v_next_required_cycles
      or now() < v_tier_progress.unlocked_at + (v_next_min_hours::text || ' hours')::interval
      or not exists (select 1 from product_templates where season_id = v_season_id and tier = v_max_tier + 1);

    insert into user_tier_progress (user_id, season_id, tier, completed_cycles, unlocked_at)
    values (p_user_id, v_season_id, v_max_tier + 1, 0, now())
    on conflict (user_id, season_id, tier) do nothing;
  end loop;

  if v_claimed_count > 0 then
    for v_quest in
      select * from quest_templates where season_id = v_season_id and is_daily
    loop
      insert into user_quest_progress (user_id, quest_id, season_id, quest_date, progress_count)
      values (p_user_id, v_quest.id, v_season_id, current_date, v_claimed_count)
      on conflict (user_id, quest_id, quest_date) do update
        set progress_count = user_quest_progress.progress_count + v_claimed_count;

      update user_quest_progress
      set completed_at = now()
      where user_id = p_user_id and quest_id = v_quest.id and quest_date = current_date
        and progress_count >= v_quest.target_count and completed_at is null;
    end loop;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- donate_to_gang_bank / distribute_bank_dividends / upgrade_gang_capacity /
-- disband_gang — each gets one added line: perform resolve_due_gang_bank_
-- interest(v_gang_id) right before the first read of bank_balance_gram,
-- so accrued VIP-treasury interest is always folded in before anyone
-- checks or spends the bank. Everything else byte-for-byte unchanged from
-- 0064_gang_audit_fixes.sql.
-- ---------------------------------------------------------------------------
create or replace function donate_to_gang_bank(p_user_id uuid, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_gang_id uuid;
  v_balance numeric(14, 2);
  v_updated_rows integer;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount_too_low';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id into v_gang_id from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select balance into v_balance
  from user_seasons
  where user_id = p_user_id and season_id = v_season_id
  for update;

  if v_balance is null then
    raise exception 'no_active_season';
  end if;
  if v_balance < p_amount then
    raise exception 'insufficient_balance';
  end if;

  update user_seasons set balance = balance - p_amount
  where user_id = p_user_id and season_id = v_season_id;

  perform resolve_due_gang_bank_interest(v_gang_id);

  update gangs
  set bank_balance_gram = bank_balance_gram + p_amount,
      bank_balance_ton = bank_balance_ton + p_amount
  where id = v_gang_id;
  get diagnostics v_updated_rows = row_count;
  if v_updated_rows = 0 then
    raise exception 'gang_not_found';
  end if;

  insert into gang_bank_transactions (gang_id, from_user_id, amount_gram, amount_ton)
  values (v_gang_id, p_user_id, p_amount, p_amount);

  return jsonb_build_object('gang_id', v_gang_id, 'amount', p_amount, 'balance', v_balance - p_amount);
end;
$$;

create or replace function distribute_bank_dividends(p_user_id uuid, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gang_id uuid;
  v_role text;
  v_bank_balance numeric(14, 2);
  v_season_id uuid;
  v_season_starting_balance numeric(14, 2);
  v_member_ids uuid[];
  v_member_count integer;
  v_idx integer;
  v_running_target numeric(14, 2) := 0;
  v_running_paid numeric(14, 2) := 0;
  v_share numeric(14, 2);
  v_updated_rows integer;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount_too_low';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  perform resolve_due_gang_bank_interest(v_gang_id);

  select bank_balance_gram into v_bank_balance from gangs where id = v_gang_id for update;
  if v_bank_balance < p_amount then
    raise exception 'insufficient_gang_bank';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select array_agg(user_id order by joined_at) into v_member_ids
  from (select user_id, joined_at from gang_members where gang_id = v_gang_id for update) locked_members;
  v_member_count := coalesce(array_length(v_member_ids, 1), 0);

  select coalesce((config->>'starting_balance')::numeric, 0)
  into v_season_starting_balance
  from seasons where id = v_season_id;

  for v_idx in 1..v_member_count loop
    v_running_target := round(p_amount * v_idx / v_member_count, 2);
    v_share := v_running_target - v_running_paid;
    v_running_paid := v_running_target;

    insert into user_seasons (user_id, season_id, balance, total_earned)
    values (v_member_ids[v_idx], v_season_id, v_season_starting_balance, v_season_starting_balance)
    on conflict (user_id, season_id) do nothing;

    update user_seasons set balance = balance + v_share
    where user_id = v_member_ids[v_idx] and season_id = v_season_id;
  end loop;

  update gangs
  set bank_balance_gram = bank_balance_gram - p_amount,
      bank_balance_ton = bank_balance_ton - p_amount
  where id = v_gang_id;
  get diagnostics v_updated_rows = row_count;
  if v_updated_rows = 0 then
    raise exception 'gang_not_found';
  end if;

  return jsonb_build_object(
    'gang_id', v_gang_id,
    'amount', p_amount,
    'member_count', v_member_count,
    'bank_balance_gram', v_bank_balance - p_amount
  );
end;
$$;

create or replace function upgrade_gang_capacity(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cost constant numeric := 1;
  v_slots_per_purchase constant integer := 5;
  v_gang_id uuid;
  v_role text;
  v_bank_balance numeric(14, 2);
  v_new_max integer;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  perform resolve_due_gang_bank_interest(v_gang_id);

  select bank_balance_gram into v_bank_balance
  from gangs where id = v_gang_id for update;

  if v_bank_balance < v_cost then
    raise exception 'insufficient_gang_bank';
  end if;

  update gangs
  set bank_balance_gram = bank_balance_gram - v_cost,
      bank_balance_ton = bank_balance_ton - v_cost,
      max_members = max_members + v_slots_per_purchase
  where id = v_gang_id
  returning max_members into v_new_max;

  return jsonb_build_object(
    'gang_id', v_gang_id,
    'max_members', v_new_max,
    'bank_balance_gram', v_bank_balance - v_cost
  );
end;
$$;

create or replace function disband_gang(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gang_id uuid;
  v_role text;
  v_bank_balance numeric(14, 2);
  v_season_id uuid;
  v_season_starting_balance numeric(14, 2);
  v_member_ids uuid[];
  v_member_count integer;
  v_idx integer;
  v_running_target numeric(14, 2) := 0;
  v_running_paid numeric(14, 2) := 0;
  v_share numeric(14, 2);
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id for update;
  if not found then
    raise exception 'not_in_gang';
  end if;
  if v_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  perform resolve_due_gang_bank_interest(v_gang_id);

  select bank_balance_gram into v_bank_balance from gangs where id = v_gang_id for update;

  if v_bank_balance > 0 then
    v_season_id := active_season_id();
    if v_season_id is null then
      raise exception 'no_active_season';
    end if;

    select array_agg(user_id order by joined_at) into v_member_ids
    from (select user_id, joined_at from gang_members where gang_id = v_gang_id for update) locked_members;
    v_member_count := coalesce(array_length(v_member_ids, 1), 0);

    select coalesce((config->>'starting_balance')::numeric, 0)
    into v_season_starting_balance
    from seasons where id = v_season_id;

    for v_idx in 1..v_member_count loop
      v_running_target := round(v_bank_balance * v_idx / v_member_count, 2);
      v_share := v_running_target - v_running_paid;
      v_running_paid := v_running_target;

      insert into user_seasons (user_id, season_id, balance, total_earned)
      values (v_member_ids[v_idx], v_season_id, v_season_starting_balance, v_season_starting_balance)
      on conflict (user_id, season_id) do nothing;

      update user_seasons set balance = balance + v_share
      where user_id = v_member_ids[v_idx] and season_id = v_season_id;
    end loop;
  end if;

  delete from gangs where id = v_gang_id;

  return jsonb_build_object('disbanded', true, 'bank_distributed', coalesce(v_bank_balance, 0));
end;
$$;

-- ---------------------------------------------------------------------------
-- get_gangs — one change from 0058_gangs.sql: each entry gains
-- premium_avatar_id/frame_id so the "Топ Банд" ranking can render the
-- gold/neon glow customization buys. Everything else unchanged.
-- ---------------------------------------------------------------------------
create or replace function get_gangs(p_user_id uuid, p_search text default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', g.id,
    'name', g.name,
    'avatar_id', g.avatar_id,
    'premium_avatar_id', g.premium_avatar_id,
    'frame_id', g.frame_id,
    'level', g.level,
    'experience', g.experience,
    'max_members', g.max_members,
    'member_count', coalesce(mc.member_count, 0),
    'leader_name', coalesce(u.username, u.first_name, 'Игрок'),
    'is_mine', exists (select 1 from gang_members where user_id = p_user_id and gang_id = g.id)
  ) order by g.level desc, g.experience desc, g.name asc), '[]'::jsonb)
  from gangs g
  join users u on u.id = g.leader_id
  left join (
    select gang_id, count(*) as member_count from gang_members group by gang_id
  ) mc on mc.gang_id = g.id
  where p_search is null or p_search = '' or g.name ilike '%' || p_search || '%'
  limit 100;
$$;

-- ---------------------------------------------------------------------------
-- get_districts — adds premium_avatar_id/frame_id to controlling_gang/
-- defender/top_challenger, plus active_boosts and mercenary_bots arrays
-- per district so the battle UI can render "🚀 АВИАУДАР 3X АКТИВЕН" /
-- "🛡 ЩИТ РАЙОНА АКТИВЕН" indicators with live expiry timestamps.
-- ---------------------------------------------------------------------------
create or replace function get_districts(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_my_gang_id uuid;
  v_result jsonb;
begin
  select gang_id into v_my_gang_id from gang_members where user_id = p_user_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id,
    'name', d.name,
    'slug', d.slug,
    'bonus_type', d.bonus_type,
    'bonus_value', d.bonus_value,
    'controlling_gang', case when cg.id is not null then jsonb_build_object(
      'id', cg.id, 'name', cg.name, 'avatar_id', cg.avatar_id,
      'premium_avatar_id', cg.premium_avatar_id, 'frame_id', cg.frame_id
    ) else null end,
    'battle_status', bstate.battle_status,
    'next_transition_at', bstate.next_transition_at,
    'defender', case when cg.id is not null then jsonb_build_object(
      'gang_id', cg.id, 'name', cg.name, 'avatar_id', cg.avatar_id,
      'premium_avatar_id', cg.premium_avatar_id, 'frame_id', cg.frame_id,
      'points', coalesce(db.defense_points, 0)
    ) else null end,
    'top_challenger', (
      select jsonb_build_object(
        'gang_id', chg.id, 'name', chg.name, 'avatar_id', chg.avatar_id,
        'premium_avatar_id', chg.premium_avatar_id, 'frame_id', chg.frame_id, 'points', ch.points
      )
      from district_challenges ch
      join gangs chg on chg.id = ch.gang_id
      where ch.district_id = d.id and ch.battle_date = bstate.battle_date
      order by ch.points desc
      limit 1
    ),
    'my_gang_role', case
      when v_my_gang_id is null then null
      when v_my_gang_id = d.controlling_gang_id then 'defender'
      when exists (
        select 1 from district_challenges
        where district_id = d.id and battle_date = bstate.battle_date and gang_id = v_my_gang_id
      ) then 'attacker'
      else null
    end,
    'my_gang_points', case
      when v_my_gang_id is null then null
      when v_my_gang_id = d.controlling_gang_id then coalesce(db.defense_points, 0)
      else (
        select points from district_challenges
        where district_id = d.id and battle_date = bstate.battle_date and gang_id = v_my_gang_id
      )
    end,
    'active_boosts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'gang_id', bg.id, 'gang_name', bg.name, 'boost_type', bb.boost_type, 'expires_at', bb.expires_at
      ) order by bb.expires_at), '[]'::jsonb)
      from district_battle_boosts bb
      join gangs bg on bg.id = bb.gang_id
      where bb.district_id = d.id and bb.expires_at > now()
    ),
    'mercenary_bots', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'gang_id', mg.id, 'gang_name', mg.name, 'expires_at', mb.expires_at
      ) order by mb.expires_at), '[]'::jsonb)
      from district_mercenary_bots mb
      join gangs mg on mg.id = mb.gang_id
      where mb.district_id = d.id and mb.battle_date = bstate.battle_date and mb.expires_at > now()
    )
  ) order by d.name), '[]'::jsonb)
  into v_result
  from districts d
  left join gangs cg on cg.id = d.controlling_gang_id
  left join lateral (
    select
      district_battle_status(d.window_start_time, d.window_end_time) as battle_status,
      district_battle_date(d.window_end_time) as battle_date,
      district_next_transition_at(d.window_start_time, d.window_end_time) as next_transition_at
  ) bstate on true
  left join district_battles db on db.district_id = d.id and db.battle_date = bstate.battle_date;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_player_state — changes from 0065_district_wars_daily_battles.sql:
--   1. perform resolve_due_gang_bank_interest for the caller's own gang
--      (if any), so their bank_balance_gram already reflects today's VIP-
--      treasury interest by the time it's read below.
--   2. perform resolve_due_mercenary_bots() alongside resolve_due_
--      district_battles, the other global (not per-user) daily catch-up.
--   3. 'gang' gains co_leader_slots, premium_avatar_id, frame_id,
--      vip_treasury. Everything else byte-for-byte unchanged from
--      0065_district_wars_daily_battles.sql.
-- ---------------------------------------------------------------------------
create or replace function get_player_state(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_result jsonb;
  v_bank_slot_bonus integer;
  v_my_gang_id uuid;
begin
  perform resolve_due_cycles(p_user_id);
  perform expire_due_boosts(p_user_id);
  perform resolve_due_bank_payouts(p_user_id);

  select gang_id into v_my_gang_id from gang_members where user_id = p_user_id;
  if v_my_gang_id is not null then
    perform resolve_due_gang_bank_interest(v_my_gang_id);
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  perform ensure_daily_combo(v_season_id);
  perform resolve_due_district_battles();
  perform resolve_due_mercenary_bots();
  perform process_auto_collect_cycles();

  select case when exists (
    select 1 from bank_deposits
    where user_id = p_user_id and season_id = v_season_id
      and status = 'active' and ends_at > now() and bonus_slot
  ) then 1 else 0 end into v_bank_slot_bonus;

  select jsonb_build_object(
    'season', (
      select jsonb_build_object(
        'id', s.id, 'slug', s.slug, 'title', s.title, 'story_theme', s.story_theme,
        'title_i18n', jsonb_build_object('ru', s.title, 'en', s.title_i18n->>'en', 'tr', s.title_i18n->>'tr', 'id', s.title_i18n->>'id'),
        'story_theme_i18n', jsonb_build_object('ru', s.story_theme, 'en', s.story_theme_i18n->>'en', 'tr', s.story_theme_i18n->>'tr', 'id', s.story_theme_i18n->>'id'),
        'starts_at', s.starts_at, 'ends_at', s.ends_at, 'config', s.config
      ) from seasons s where s.id = v_season_id
    ),
    'profile', (
      select jsonb_build_object(
        'username', u.username, 'first_name', u.first_name, 'photo_url', u.photo_url, 'hide_from_leaderboard', u.hide_from_leaderboard
      )
      from users u where u.id = p_user_id
    ),
    'wallet', (
      select jsonb_build_object(
        'balance', us.balance,
        'total_earned', us.total_earned,
        'completed_cycles_total', us.completed_cycles_total,
        'has_seen_intro', us.has_seen_intro,
        'xp', us.xp,
        'total_slots_open', (
          select coalesce(sum(tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level)), 0)
          from user_tier_progress utp
          join product_templates pt on pt.season_id = utp.season_id and pt.tier = utp.tier
          where utp.user_id = p_user_id and utp.season_id = v_season_id
        ),
        'total_slots_used', (
          select coalesce(sum(slot_quantity), 0) from cycles
          where user_id = p_user_id and season_id = v_season_id and status = 'running'
        ),
        'pending_withdrawal', (
          select jsonb_build_object(
            'id', wr.id, 'amount', wr.amount, 'fee', wr.fee, 'net_amount', wr.net_amount,
            'created_at', wr.created_at
          )
          from withdrawal_requests wr
          where wr.user_id = p_user_id and wr.season_id = v_season_id and wr.status = 'pending'
          order by wr.created_at desc
          limit 1
        ),
        'auto_collect_until', (
          select us2.auto_collect_until from user_seasons us2
          where us2.user_id = p_user_id and us2.season_id = v_season_id
        )
      ) from user_seasons us where us.user_id = p_user_id and us.season_id = v_season_id
    ),
    'stats', jsonb_build_object(
      'profit_24h', (
        coalesce((
          select sum(amount_out) from cycles
          where user_id = p_user_id and season_id = v_season_id
            and status = 'claimed' and claimed_at >= now() - interval '24 hours'
        ), 0)
        + coalesce((
          select sum(amount) from referral_earnings
          where beneficiary_id = p_user_id and created_at >= now() - interval '24 hours'
        ), 0)
      )
    ),
    'rank', (
      select jsonb_build_object(
        'name', r.name, 'icon', r.icon, 'level', r.sort_order,
        'name_i18n', jsonb_build_object('ru', r.name, 'en', r.name_i18n->>'en', 'tr', r.name_i18n->>'tr', 'id', r.name_i18n->>'id'),
        'min_earned', r.min_earned,
        'next_min_earned', (
          select r2.min_earned from ranks r2
          where r2.season_id = v_season_id and r2.sort_order = r.sort_order + 1
        )
      )
      from ranks r
      where r.season_id = v_season_id
        and r.min_earned <= (
          select total_earned from user_seasons
          where user_id = p_user_id and season_id = v_season_id
        )
      order by r.min_earned desc limit 1
    ),
    'tiers', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'tier', pt.tier,
        'name', pt.name,
        'description', pt.description,
        'name_i18n', jsonb_build_object('ru', pt.name, 'en', pt.name_i18n->>'en', 'tr', pt.name_i18n->>'tr', 'id', pt.name_i18n->>'id'),
        'description_i18n', jsonb_build_object('ru', pt.description, 'en', pt.description_i18n->>'en', 'tr', pt.description_i18n->>'tr', 'id', pt.description_i18n->>'id'),
        'price', pt.price,
        'payout_percent', pt.payout_percent,
        'cycle_hours', pt.cycle_hours,
        'unlocked', (utp.tier is not null),
        'completed_cycles', coalesce(utp.completed_cycles, 0),
        'unlock_required_cycles', pt.unlock_required_cycles,
        'unlock_min_hours', pt.unlock_min_hours,
        'unlocked_at', utp.unlocked_at,
        'slots_open', case when utp.tier is not null
          then tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level)
          else pt.slot_base_count end,
        'slots_boost', coalesce(bc.boost_count, 0),
        'slots_bank_bonus', case when utp.tier is not null then v_bank_slot_bonus else 0 end,
        'slots_total', case when utp.tier is not null
          then tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level)
            + coalesce(bc.boost_count, 0) + v_bank_slot_bonus
          else pt.slot_base_count end,
        'slots_used', coalesce(cyc.used_slots, 0),
        'slots_max', pt.slot_max_count,
        'cycles_to_next_slot', case
          when utp.tier is null then pt.slot_cycles_per_level
          when tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level) >= pt.slot_max_count then null
          else pt.slot_cycles_per_level - (utp.completed_cycles % pt.slot_cycles_per_level)
        end,
        'can_buy_max', (
          utp.tier is not null
          and tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level) >= pt.slot_max_count
        )
      ) order by pt.tier), '[]'::jsonb)
      from product_templates pt
      left join user_tier_progress utp
        on utp.season_id = v_season_id and utp.tier = pt.tier and utp.user_id = p_user_id
      left join (
        select tier, sum(slot_quantity) as used_slots
        from cycles
        where user_id = p_user_id and season_id = v_season_id and status = 'running'
        group by tier
      ) cyc on cyc.tier = pt.tier
      left join (
        select target_tier, count(*) as boost_count
        from user_boosts
        where user_id = p_user_id and season_id = v_season_id and status = 'ACTIVE'
        group by target_tier
      ) bc on bc.target_tier = pt.tier
      where pt.season_id = v_season_id
    ),
    'active_cycles', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'tier', c.tier, 'started_at', c.started_at, 'ends_at', c.ends_at,
        'amount_in', c.amount_in, 'slot_quantity', c.slot_quantity,
        'seconds_remaining', greatest(0, extract(epoch from (c.ends_at - now())))
      ) order by c.ends_at), '[]'::jsonb)
      from cycles c
      where c.user_id = p_user_id and c.season_id = v_season_id and c.status = 'running'
    ),
    'quests', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', qt.id, 'title', qt.title, 'description', qt.description,
        'title_i18n', jsonb_build_object('ru', qt.title, 'en', qt.title_i18n->>'en', 'tr', qt.title_i18n->>'tr', 'id', qt.title_i18n->>'id'),
        'description_i18n', jsonb_build_object('ru', qt.description, 'en', qt.description_i18n->>'en', 'tr', qt.description_i18n->>'tr', 'id', qt.description_i18n->>'id'),
        'target_count', qt.target_count,
        'progress_count', coalesce(uqp.progress_count, 0),
        'reward_amount', qt.reward_amount,
        'grants_boost', qt.grants_boost,
        'completed_at', uqp.completed_at,
        'claimed_at', uqp.claimed_at
      )), '[]'::jsonb)
      from quest_templates qt
      left join user_quest_progress uqp
        on uqp.quest_id = qt.id and uqp.user_id = p_user_id and uqp.quest_date = current_date
      where qt.season_id = v_season_id and qt.is_daily
    ),
    'containers', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', uc.id, 'code', ct.code, 'name', ct.name,
        'obtained_at', uc.obtained_at, 'opens_at', uc.opens_at,
        'opened_at', uc.opened_at, 'reward_amount', uc.reward_amount
      ) order by uc.obtained_at), '[]'::jsonb)
      from user_containers uc
      join container_templates ct on ct.id = uc.container_template_id
      where uc.user_id = p_user_id and uc.season_id = v_season_id and uc.opened_at is null
    ),
    'partner_tasks', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pt.id, 'title', pt.title, 'description', pt.description,
        'reward_amount', pt.reward_amount,
        'reward_item_type', pt.reward_item_type,
        'reward_item_qty', pt.reward_item_qty,
        'channel_username', pt.channel_username,
        'icon_url', pt.icon_url,
        'kind', pt.kind,
        'verification_method', pt.verification_method,
        'completed', (upt.completed_at is not null),
        'verified_at', upt.verified_at,
        'available_at', case when upt.verified_at is not null and upt.completed_at is null
          then upt.verified_at + interval '24 hours' else null end
      ) order by pt.sort_order), '[]'::jsonb)
      from partner_tasks pt
      left join user_partner_tasks upt
        on upt.task_id = pt.id and upt.user_id = p_user_id
      where pt.season_id = v_season_id and pt.is_active
    ),
    'system_tasks', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', st.id, 'slug', st.slug, 'title', st.title, 'description', st.description,
        'category', st.category, 'target_type', st.target_type, 'target_value', st.target_value,
        'required_count', st.required_count,
        'progress', case st.target_type
          when 'referrals_level_1' then (select count(*) from users where referred_by = p_user_id)
          when 'cycles_completed' then (
            select coalesce(completed_cycles_total, 0) from user_seasons
            where user_id = p_user_id and season_id = v_season_id
          )
          when 'tier_reached' then case when exists (
            select 1 from user_tier_progress
            where user_id = p_user_id and season_id = v_season_id and tier = st.target_value::smallint
          ) then st.required_count else 0 end
          else 0
        end,
        'reward_xp', st.reward_xp,
        'rewards', (
          select coalesce(jsonb_agg(jsonb_build_object('item_type', str.item_type, 'quantity', str.quantity)), '[]'::jsonb)
          from system_task_rewards str where str.task_id = st.id
        ),
        'completed', (uct.completed_at is not null),
        'verified_at', uct.verified_at,
        'available_at', case when uct.verified_at is not null and uct.completed_at is null
          then uct.verified_at + interval '24 hours' else null end
      ) order by st.sort_order), '[]'::jsonb)
      from system_tasks st
      left join user_completed_tasks uct
        on uct.task_id = st.id and uct.user_id = p_user_id and uct.season_id = v_season_id
      where st.is_active
    ),
    'squad', jsonb_build_object(
      'invite_code', (select telegram_id::text from users where id = p_user_id),
      'referred_count', (select count(*) from users where referred_by = p_user_id),
      'earned_total', (select coalesce(sum(amount), 0) from referral_earnings where beneficiary_id = p_user_id and season_id = v_season_id),
      'is_ambassador', (select coalesce(is_ambassador, false) from users where id = p_user_id)
    ),
    'daily_combo', (
      select jsonb_build_object(
        'attempts_used', coalesce(ucp.attempts_used, 0),
        'attempts_max', dc.max_attempts,
        'is_completed', coalesce(ucp.is_completed, false),
        'resets_at', ((dc.combo_date + 1)::timestamp at time zone 'utc'),
        'slot_count', array_length(dc.tiers, 1),
        'pool', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'tier', pt.tier, 'name', pt.name,
            'name_i18n', jsonb_build_object('ru', pt.name, 'en', pt.name_i18n->>'en', 'tr', pt.name_i18n->>'tr', 'id', pt.name_i18n->>'id')
          ) order by pt.tier), '[]'::jsonb)
          from product_templates pt where pt.season_id = v_season_id
        ),
        'last_guess', case when ucp.last_guess_tiers is not null then (
          select coalesce(jsonb_agg(jsonb_build_object(
            'tier', g.tier, 'correct', g.correct, 'name', pt.name,
            'name_i18n', jsonb_build_object('ru', pt.name, 'en', pt.name_i18n->>'en', 'tr', pt.name_i18n->>'tr', 'id', pt.name_i18n->>'id')
          ) order by g.ord), '[]'::jsonb)
          from unnest(ucp.last_guess_tiers, ucp.last_guess_correct) with ordinality as g(tier, correct, ord)
          join product_templates pt on pt.season_id = v_season_id and pt.tier = g.tier
        ) else null end,
        'revealed_tiers', case when coalesce(ucp.is_completed, false) then (
          select coalesce(jsonb_agg(jsonb_build_object(
            'tier', u.t, 'name', pt.name,
            'name_i18n', jsonb_build_object('ru', pt.name, 'en', pt.name_i18n->>'en', 'tr', pt.name_i18n->>'tr', 'id', pt.name_i18n->>'id')
          ) order by u.ord), '[]'::jsonb)
          from unnest(dc.tiers) with ordinality as u(t, ord)
          join product_templates pt on pt.season_id = v_season_id and pt.tier = u.t
        ) else null end,
        'possible_drops', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'item_type', item_type, 'category', category, 'drop_weight', drop_weight,
            'effect_percent', effect_percent, 'effect_hours', effect_hours
          ) order by sort_order), '[]'::jsonb)
          from combo_item_templates
        ),
        'reward_item', case when ucp.reward_item_type is not null then (
          select jsonb_build_object(
            'item_type', item_type, 'category', category,
            'effect_percent', effect_percent, 'effect_hours', effect_hours
          )
          from combo_item_templates where item_type = ucp.reward_item_type
        ) else null end
      )
      from daily_combo dc
      left join user_combo_progress ucp
        on ucp.user_id = p_user_id and ucp.season_id = v_season_id and ucp.combo_date = dc.combo_date
      where dc.season_id = v_season_id and dc.combo_date = (now() at time zone 'utc')::date
    ),
    'boosts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ub.id,
        'status', ub.status,
        'source', ub.source,
        'target_tier', ub.target_tier,
        'created_at', ub.created_at,
        'expires_at', ub.expires_at,
        'activated_at', ub.activated_at
      ) order by ub.created_at), '[]'::jsonb)
      from user_boosts ub
      where ub.user_id = p_user_id and ub.season_id = v_season_id
        and ub.status in ('PENDING', 'ACTIVE')
    ),
    'inventory', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'item_type', inv.item_type,
        'category', cit.category,
        'quantity', inv.quantity,
        'expires_at', inv.nearest_expiry,
        'effect_percent', cit.effect_percent,
        'effect_hours', cit.effect_hours
      ) order by cit.sort_order), '[]'::jsonb)
      from (
        select item_type, count(*) as quantity, min(expires_at) as nearest_expiry
        from user_inventory
        where user_id = p_user_id and season_id = v_season_id
          and status = 'active' and expires_at > now()
        group by item_type
      ) inv
      join combo_item_templates cit on cit.item_type = inv.item_type
    ),
    'exchange_rate', (
      select jsonb_build_object('pair', pair, 'rate', rate, 'updated_at', updated_at)
      from exchange_rates where pair = 'GRAM_USDT'
    ),
    'bank_deposits', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', bd.id,
        'amount', bd.amount,
        'plan_days', bd.plan_days,
        'yield_percent', bd.yield_percent,
        'expected_reward', bd.expected_reward,
        'bonus_speed', bd.bonus_speed,
        'bonus_slot', bd.bonus_slot,
        'status', bd.status,
        'starts_at', bd.starts_at,
        'ends_at', bd.ends_at,
        'days_paid', bd.days_paid,
        'principal_paid', bd.principal_paid,
        'reward_paid', bd.reward_paid
      ) order by (bd.status = 'active') desc, bd.ends_at), '[]'::jsonb)
      from bank_deposits bd
      where bd.user_id = p_user_id and bd.season_id = v_season_id
    ),
    'bank_buffs', jsonb_build_object(
      'speed_boost', exists (
        select 1 from bank_deposits
        where user_id = p_user_id and season_id = v_season_id
          and status = 'active' and ends_at > now() and bonus_speed
      ),
      'slot_boost', v_bank_slot_bonus > 0
    ),
    'gang', (
      select jsonb_build_object(
        'id', g.id,
        'name', g.name,
        'avatar_id', g.avatar_id,
        'premium_avatar_id', g.premium_avatar_id,
        'frame_id', g.frame_id,
        'level', g.level,
        'experience', g.experience,
        'exp_into_level', g.experience % 100,
        'exp_per_level', 100,
        'max_members', g.max_members,
        'co_leader_slots', g.co_leader_slots,
        'vip_treasury', g.vip_treasury,
        'leader_name', coalesce(lu.username, lu.first_name, 'Игрок'),
        'my_role', gm_self.role,
        'target_district_id', g.target_district_id,
        'target_district_name', td.name,
        'members', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'user_id', gm.user_id,
            'display_name', coalesce(mu.username, mu.first_name, 'Игрок'),
            'photo_url', mu.photo_url,
            'role', gm.role,
            'joined_at', gm.joined_at
          ) order by
            case gm.role when 'leader' then 0 when 'co_leader' then 1 else 2 end,
            gm.joined_at
          ), '[]'::jsonb)
          from gang_members gm
          join users mu on mu.id = gm.user_id
          where gm.gang_id = g.id
        ),
      'bank_balance_gram', g.bank_balance_gram,
      'bank_balance_ton', g.bank_balance_ton,
      'bank_top_donors', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'user_id', donors.from_user_id,
          'display_name', coalesce(du.username, du.first_name, 'Игрок'),
          'photo_url', du.photo_url,
          'amount', donors.total_amount
        ) order by donors.total_amount desc, donors.from_user_id), '[]'::jsonb)
        from (
          select gb.from_user_id, sum(gb.amount_gram) as total_amount
          from gang_bank_transactions gb
          where gb.gang_id = g.id
          group by gb.from_user_id
          order by total_amount desc
          limit 5
        ) donors
        join users du on du.id = donors.from_user_id
      ),
      'bank_transactions', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', gb.id,
          'from_user_id', gb.from_user_id,
          'display_name', coalesce(du.username, du.first_name, 'Игрок'),
          'photo_url', du.photo_url,
          'amount_gram', gb.amount_gram,
          'created_at', gb.created_at
        ) order by gb.created_at desc), '[]'::jsonb)
        from (
          select * from gang_bank_transactions
          where gang_id = g.id
          order by created_at desc
          limit 10
        ) gb
        join users du on du.id = gb.from_user_id
      )
      )
      from gang_members gm_self
      join gangs g on g.id = gm_self.gang_id
      join users lu on lu.id = g.leader_id
      left join districts td on td.id = g.target_district_id
      where gm_self.user_id = p_user_id
    )
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_gang_cosmetics_catalog — public read powering the "Кастомизация"
-- shop screen (name/price/glow for every purchasable avatar/frame).
-- ---------------------------------------------------------------------------
create or replace function get_gang_cosmetics_catalog()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'code', code, 'cosmetic_type', cosmetic_type, 'name', name, 'price', price, 'glow', glow
  ) order by cosmetic_type, price), '[]'::jsonb)
  from gang_cosmetics_catalog;
$$;
