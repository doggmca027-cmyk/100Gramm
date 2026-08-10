-- 100ГРАМ: "Банк 100GRAM" — GRAM staking with 3 fixed-term plans and
-- temporary economy-wide buffs while a deposit is active.
--
-- Deviations from a literal auth.uid()/user_balance spec, kept consistent
-- with every other table/RPC in this schema (see e.g. request_withdrawal,
-- start_cycle):
--   * No Supabase Auth here at all — this app authenticates via a custom
--     Telegram-initData session (see lib/telegram-auth.ts, lib/session.ts),
--     not auth.uid(). Every RPC takes an explicit p_user_id, trusted only
--     because the calling Next.js route has already verified the session
--     server-side (requireUserId) before ever reaching this function —
--     same trust boundary as claim_partner_task, request_withdrawal, etc.
--   * Balance lives on user_seasons.balance (season-scoped), not a
--     standalone user_balance column — there isn't one in this schema.
--     Deposits are scoped to the season they were opened in for the same
--     reason every money-moving table here is (cycles, wallet_transactions,
--     withdrawal_requests, ...).
--
-- Plan table (business rules, enforced ONLY server-side — see
-- create_bank_deposit; the client-side src/lib/bank-plans.ts copy is
-- strictly a UX convenience for disabling the button early, never trusted):
--   7d  -> +5%,  min 3 GRAM,  always grants the +10% cycle-speed buff
--   14d -> +12%, min 10 GRAM, grants +1 slot if the player already has at
--          least one open slot at deposit time, otherwise +10% speed —
--          decided once, at deposit creation, and stored on the row (not
--          re-evaluated later, so a deposit's granted buff can't flip
--          mid-term as the player's own slot progress changes)
--   30d -> +30%, min 15 GRAM, always grants BOTH +1 slot and +10% speed
--
-- Buff mechanics (see start_cycle/get_player_state below for the actual
-- wiring):
--   * Speed: applied ONCE, at the moment a cycle is *started*, by dividing
--     that cycle's duration by 1.10 if the player has any qualifying
--     active deposit right then. Deliberately not a live, continuously-
--     recomputed discount on already-running cycles — cycles.ends_at is
--     already fixed at start time everywhere else in this schema
--     (resolve_due_cycles just reads it), and retroactively rewriting a
--     running cycle's timer whenever a deposit starts/matures/is broken
--     early would be a whole new class of bug for a "temporary discount on
--     new expeditions" feature. A cycle keeps whatever speed it was
--     started with for its whole run, same as every other per-cycle
--     modifier (boosts, time-skip items) in this game.
--   * Slot: applied as a flat +1 to *every* unlocked tier's available slot
--     count while active, not tied to one specific tier — the deposit flow
--     has no tier parameter to tie it to, unlike the existing per-tier
--     user_boosts mechanism (target_tier), which this is deliberately
--     separate from.
--   * Early withdrawal costs nothing to implement specially for "burning"
--     the buff: buffs are computed live from
--     `status = 'active' and ends_at > now()`, so flipping status to
--     'early_closed' removes the buff on the very next read, with no
--     separate bookkeeping needed.

create table bank_deposits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  season_id uuid not null references seasons(id) on delete cascade,
  amount numeric(14, 2) not null check (amount > 0),
  plan_days integer not null check (plan_days in (7, 14, 30)),
  yield_percent numeric(5, 2) not null check (yield_percent in (5, 12, 30)),
  expected_reward numeric(14, 2) not null check (expected_reward >= 0),
  -- Which buff(s) this specific deposit actually grants while active —
  -- decided once at creation time, see the 14-day plan note above.
  bonus_speed boolean not null default false,
  bonus_slot boolean not null default false,
  status text not null default 'active' check (status in ('active', 'claimed', 'early_closed')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create index bank_deposits_user_idx on bank_deposits (user_id, season_id, status);
-- Powers both start_cycle's and get_player_state's "does this user have
-- an active speed/slot buff right now" checks — a plain user_id lookup
-- filtered by status/ends_at/bonus_* at query time, no separate flag table
-- to keep in sync.
create index bank_deposits_active_buffs_idx on bank_deposits (user_id) where status = 'active';

alter table bank_deposits enable row level security;

-- ---------------------------------------------------------------------------
-- create_bank_deposit — opens a deposit. Validates the plan's minimum
-- STRICTLY server-side (never trusts the client past disabling a button
-- early) and locks the balance row with `for update` before checking/
-- deducting, same race-condition guard request_withdrawal already uses —
-- two concurrent deposit attempts can't both read the same pre-deduction
-- balance and overdraw it.
-- ---------------------------------------------------------------------------
create or replace function create_bank_deposit(p_user_id uuid, p_plan_days integer, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_yield_percent numeric(5, 2);
  v_min_amount numeric;
  v_bonus_speed boolean := false;
  v_bonus_slot boolean := false;
  v_open_slots integer;
  v_balance numeric(14, 2);
  v_expected_reward numeric(14, 2);
  v_ends_at timestamptz;
  v_deposit_id uuid;
begin
  if p_plan_days = 7 then
    v_yield_percent := 5;
    v_min_amount := 3;
    v_bonus_speed := true;
  elsif p_plan_days = 14 then
    v_yield_percent := 12;
    v_min_amount := 10;
    -- bonus_speed/bonus_slot decided below, once we can see the player's
    -- current slot state.
  elsif p_plan_days = 30 then
    v_yield_percent := 30;
    v_min_amount := 15;
    v_bonus_speed := true;
    v_bonus_slot := true;
  else
    raise exception 'invalid_plan';
  end if;

  if p_amount is null or p_amount < v_min_amount then
    raise exception 'amount_too_low';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  if p_plan_days = 14 then
    select coalesce(sum(tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level)), 0)
    into v_open_slots
    from user_tier_progress utp
    join product_templates pt on pt.season_id = utp.season_id and pt.tier = utp.tier
    where utp.user_id = p_user_id and utp.season_id = v_season_id;

    if coalesce(v_open_slots, 0) >= 1 then
      v_bonus_slot := true;
    else
      v_bonus_speed := true;
    end if;
  end if;

  -- Lock first, check second — the same order every other balance-
  -- deducting RPC in this schema uses (request_withdrawal, start_cycle).
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

  v_expected_reward := round(p_amount * v_yield_percent / 100, 2);
  v_ends_at := now() + (p_plan_days::text || ' days')::interval;

  insert into bank_deposits (
    user_id, season_id, amount, plan_days, yield_percent, expected_reward,
    bonus_speed, bonus_slot, ends_at
  )
  values (
    p_user_id, v_season_id, p_amount, p_plan_days, v_yield_percent, v_expected_reward,
    v_bonus_speed, v_bonus_slot, v_ends_at
  )
  returning id into v_deposit_id;

  return jsonb_build_object(
    'deposit_id', v_deposit_id,
    'balance', v_balance - p_amount,
    'ends_at', v_ends_at,
    'expected_reward', v_expected_reward,
    'bonus_speed', v_bonus_speed,
    'bonus_slot', v_bonus_slot
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- claim_bank_deposit — pays out principal + reward once matured. `for
-- update` on the deposit row itself is what makes a doubled/retried claim
-- request a no-op instead of a double payout: the `status <> 'active'`
-- check after the lock catches a concurrent second call every time,
-- exactly like claim_partner_task's already-completed guard.
-- ---------------------------------------------------------------------------
create or replace function claim_bank_deposit(p_user_id uuid, p_deposit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deposit bank_deposits%rowtype;
  v_payout numeric(14, 2);
begin
  select * into v_deposit from bank_deposits
  where id = p_deposit_id and user_id = p_user_id
  for update;

  if not found then
    raise exception 'unknown_deposit';
  end if;

  if v_deposit.status <> 'active' then
    raise exception 'deposit_not_active';
  end if;

  if now() < v_deposit.ends_at then
    raise exception 'deposit_not_matured';
  end if;

  v_payout := v_deposit.amount + v_deposit.expected_reward;

  update bank_deposits set status = 'claimed', resolved_at = now()
  where id = p_deposit_id;

  -- total_earned tracks profit only (matches cycles/referrals/quests
  -- elsewhere) — the returned principal isn't "earned", the reward is.
  update user_seasons
  set balance = balance + v_payout, total_earned = total_earned + v_deposit.expected_reward
  where user_id = p_user_id and season_id = v_deposit.season_id;

  return jsonb_build_object('status', 'claimed', 'payout', v_payout, 'reward', v_deposit.expected_reward);
end;
$$;

-- ---------------------------------------------------------------------------
-- early_withdraw_bank_deposit — returns principal only (0% yield), before
-- maturity. Flipping status here is also what instantly revokes any
-- speed/slot buff this deposit was granting — see the migration header.
--
-- If the deposit has ALREADY matured (ends_at has passed) by the time this
-- is called, this is no longer actually "early" — pay it out exactly like
-- claim_bank_deposit would (principal + reward, status 'claimed') instead
-- of applying the 0%-yield penalty. Without this, a stale countdown on the
-- client (clock skew, a throttled background tab, or just a slow re-render
-- after ends_at passes) could route a fully-matured deposit through this
-- endpoint instead of /claim and permanently forfeit an already-earned
-- reward — a real loss of funds for a UI timing accident, not anything the
-- player actually chose.
-- ---------------------------------------------------------------------------
create or replace function early_withdraw_bank_deposit(p_user_id uuid, p_deposit_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deposit bank_deposits%rowtype;
  v_payout numeric(14, 2);
begin
  select * into v_deposit from bank_deposits
  where id = p_deposit_id and user_id = p_user_id
  for update;

  if not found then
    raise exception 'unknown_deposit';
  end if;

  if v_deposit.status <> 'active' then
    raise exception 'deposit_not_active';
  end if;

  if now() >= v_deposit.ends_at then
    -- Already matured -- this is a claim in every way that matters, not an
    -- early exit. Same payout/status/total_earned handling as
    -- claim_bank_deposit.
    v_payout := v_deposit.amount + v_deposit.expected_reward;

    update bank_deposits set status = 'claimed', resolved_at = now()
    where id = p_deposit_id;

    update user_seasons
    set balance = balance + v_payout, total_earned = total_earned + v_deposit.expected_reward
    where user_id = p_user_id and season_id = v_deposit.season_id;

    return jsonb_build_object('status', 'claimed', 'payout', v_payout, 'reward', v_deposit.expected_reward);
  end if;

  update bank_deposits set status = 'early_closed', resolved_at = now()
  where id = p_deposit_id;

  update user_seasons set balance = balance + v_deposit.amount
  where user_id = p_user_id and season_id = v_deposit.season_id;

  return jsonb_build_object('status', 'early_closed', 'returned', v_deposit.amount);
end;
$$;

-- ---------------------------------------------------------------------------
-- get_user_bank_buffs — the "getUserActiveBankBuffs" helper. Standalone
-- and reusable, but start_cycle/get_player_state below inline the same two
-- EXISTS checks directly rather than calling this from inside an already
-- hot path — same reasoning tier_slots_open is both a standalone function
-- and inlined at call sites.
--
-- Scoped to the CURRENT season (active_season_id()), same as every other
-- money/buff-relevant lookup in this schema — an unmatured deposit opened
-- in a season that has since ended must not keep buffing whatever season
-- is active now. Same cross-season leak class 0037_referral_earnings_season_scope.sql
-- closed for referral_earnings; deliberately closed here from the start
-- rather than left for a follow-up migration once season 2 exists.
-- ---------------------------------------------------------------------------
create or replace function get_user_bank_buffs(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'speed_boost', exists (
      select 1 from bank_deposits
      where user_id = p_user_id and season_id = active_season_id()
        and status = 'active' and ends_at > now() and bonus_speed
    ),
    'slot_boost', exists (
      select 1 from bank_deposits
      where user_id = p_user_id and season_id = active_season_id()
        and status = 'active' and ends_at > now() and bonus_slot
    )
  );
$$;

-- ---------------------------------------------------------------------------
-- start_cycle — adds the bank speed/slot buffs on top of the
-- 0034_referral_rate_update.sql version. Two changes only:
--   1. v_total_slots gains + v_bank_slot_bonus (flat +1 across every tier
--      while a qualifying deposit is active, see migration header).
--   2. The new cycle's duration is divided by 1.10 when a qualifying
--      deposit is active at the moment it's started.
-- Everything else — pricing, referral payouts, boost consumption — is
-- byte-for-byte unchanged.
-- ---------------------------------------------------------------------------
create or replace function start_cycle(p_user_id uuid, p_tier smallint)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_price numeric(12, 2);
  v_cycle_hours numeric(6, 2);
  v_slot_base smallint;
  v_slot_max smallint;
  v_slot_per_level smallint;
  v_tier_completed_cycles integer;
  v_tier_slots integer;
  v_boost_count integer;
  v_bank_slot_active boolean;
  v_bank_slot_bonus integer;
  v_bank_speed_active boolean;
  v_total_slots integer;
  v_boost_id uuid;
  v_used_slots integer;
  v_free_slots integer;
  v_balance numeric(14, 2);
  v_total_price numeric(12, 2);
  v_cycle_id uuid;
  v_referrer1 uuid;
  v_referrer2 uuid;
  v_referrer3 uuid;
  v_is_ambassador boolean;
  v_bonus numeric(12, 2);
begin
  perform resolve_due_cycles(p_user_id);
  perform expire_due_boosts(p_user_id);

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select completed_cycles into v_tier_completed_cycles
  from user_tier_progress
  where user_id = p_user_id and season_id = v_season_id and tier = p_tier;

  if not found then
    raise exception 'tier_locked';
  end if;

  select price, cycle_hours, slot_base_count, slot_max_count, slot_cycles_per_level
  into v_price, v_cycle_hours, v_slot_base, v_slot_max, v_slot_per_level
  from product_templates
  where season_id = v_season_id and tier = p_tier;

  if v_price is null then
    raise exception 'unknown_tier';
  end if;

  select balance into v_balance
  from user_seasons
  where user_id = p_user_id and season_id = v_season_id
  for update;

  v_tier_slots := tier_slots_open(v_tier_completed_cycles, v_slot_base, v_slot_max, v_slot_per_level);

  select count(*) into v_boost_count
  from user_boosts
  where user_id = p_user_id and season_id = v_season_id and target_tier = p_tier and status = 'ACTIVE';

  select exists (
    select 1 from bank_deposits
    where user_id = p_user_id and season_id = v_season_id
      and status = 'active' and ends_at > now() and bonus_slot
  ) into v_bank_slot_active;
  -- No implicit (or even explicit, without a helper) boolean->integer cast
  -- in Postgres -- resolve to 1/0 through a case expression instead of
  -- trying to cast the boolean straight into an integer variable.
  v_bank_slot_bonus := case when v_bank_slot_active then 1 else 0 end;

  v_total_slots := v_tier_slots + v_boost_count + v_bank_slot_bonus;

  select coalesce(sum(slot_quantity), 0) into v_used_slots
  from cycles
  where user_id = p_user_id and season_id = v_season_id and tier = p_tier and status = 'running';

  v_free_slots := v_total_slots - v_used_slots;
  if v_free_slots <= 0 then
    raise exception 'no_free_slots';
  end if;

  if v_balance < v_price then
    raise exception 'insufficient_balance';
  end if;
  v_free_slots := least(v_free_slots, floor(v_balance / v_price)::integer);
  v_total_price := v_price * v_free_slots;

  -- does this launch's batch reach into the boosted (beyond-progression) capacity?
  if v_boost_count > 0 and (v_used_slots + v_free_slots) > v_tier_slots then
    select id into v_boost_id
    from user_boosts
    where user_id = p_user_id and season_id = v_season_id and target_tier = p_tier and status = 'ACTIVE'
    order by activated_at asc
    limit 1;
  end if;

  update user_seasons set balance = balance - v_total_price
  where user_id = p_user_id and season_id = v_season_id;

  select exists (
    select 1 from bank_deposits
    where user_id = p_user_id and season_id = v_season_id
      and status = 'active' and ends_at > now() and bonus_speed
  ) into v_bank_speed_active;

  insert into cycles (user_id, season_id, tier, status, started_at, ends_at, amount_in, slot_quantity, boost_id)
  values (
    p_user_id, v_season_id, p_tier, 'running', now(),
    now() + (
      (case when v_bank_speed_active then v_cycle_hours / 1.10 else v_cycle_hours end)::text || ' hours'
    )::interval,
    v_total_price, v_free_slots, v_boost_id
  )
  returning id into v_cycle_id;

  -- 3-level referral bonus, paid now, off the deposit (v_total_price), to
  -- seasoned referrers (must already have a user_seasons row this season)
  select referred_by into v_referrer1 from users where id = p_user_id;
  if v_referrer1 is not null then
    select is_ambassador into v_is_ambassador from users where id = v_referrer1;
    v_bonus := round(v_total_price * (case when v_is_ambassador then 0.08 else 0.05 end), 2);
    update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
    where user_id = v_referrer1 and season_id = v_season_id;
    if found then
      insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount, season_id)
      values (v_referrer1, p_user_id, 1, v_cycle_id, v_bonus, v_season_id);
    end if;

    select referred_by into v_referrer2 from users where id = v_referrer1;
    if v_referrer2 is not null then
      select is_ambassador into v_is_ambassador from users where id = v_referrer2;
      v_bonus := round(v_total_price * (case when v_is_ambassador then 0.05 else 0.03 end), 2);
      update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
      where user_id = v_referrer2 and season_id = v_season_id;
      if found then
        insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount, season_id)
        values (v_referrer2, p_user_id, 2, v_cycle_id, v_bonus, v_season_id);
      end if;

      select referred_by into v_referrer3 from users where id = v_referrer2;
      if v_referrer3 is not null then
        select is_ambassador into v_is_ambassador from users where id = v_referrer3;
        v_bonus := round(v_total_price * (case when v_is_ambassador then 0.03 else 0.01 end), 2);
        update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
        where user_id = v_referrer3 and season_id = v_season_id;
        if found then
          insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount, season_id)
          values (v_referrer3, p_user_id, 3, v_cycle_id, v_bonus, v_season_id);
        end if;
      end if;
    end if;
  end if;

  return v_cycle_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_player_state — adds 'bank_deposits' (the player's own deposits,
-- active first) and 'bank_buffs' (the same two live flags start_cycle
-- checks, exposed for the UI to show active-buff badges), and folds the
-- bank slot bonus into every unlocked tier's slots_total the same way
-- slots_boost (user_boosts) already is. Otherwise identical to the
-- 0055_partner_cross_app_tasks.sql version.
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
begin
  perform resolve_due_cycles(p_user_id);
  perform expire_due_boosts(p_user_id);

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  perform ensure_daily_combo(v_season_id);
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
        'ends_at', bd.ends_at
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
    )
  ) into v_result;

  return v_result;
end;
$$;
