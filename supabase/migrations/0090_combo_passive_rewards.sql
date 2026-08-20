-- Requested 2026-08-20: Daily Combo's reward is replaced with a random
-- PASSIVE trait instead of a consumable item — individual per player,
-- one of two categories per win (never both), category picked 50/50:
--   * income_bonus: +1/2/3/4% added on top of the tier's own payout_percent
--     for every cycle that player ever claims, on every tier.
--   * time_reduction: -1/2/3/4/5% off cycle_hours for every cycle that
--     player starts, on every tier.
-- Within a category the *value* is weighted so a bigger number is much
-- rarer than a small one (same cumulative-weight-walk idiom the old
-- item-drop system used) — see the two inline weight tables below.
--
-- A later win overwrites the passive for whichever category it rolled
-- (not additive across wins) — the value itself is what's capped at
-- 4%/5%, not some separate running total, so this can never exceed that
-- ceiling regardless of how many times a player wins over the season.
-- The daily combo now only allows 1 attempt/day (was 3) — set as
-- daily_combo's new column default and backfilled onto every existing row.
--
-- Fully replaces the old time_skip/auto_collect item-drop reward — that
-- machinery (combo_item_templates, user_inventory, apply_time_skip_item,
-- apply_auto_collect_item) is untouched and kept alive for system/partner
-- task rewards, which still grant those same items independently of
-- Daily Combo.
--
-- The late-claim penalty (0088_late_claim_penalty.sql) now halves the
-- *combined* percent (tier payout_percent + player's income_bonus),
-- per explicit instruction — "штраф ... изымается со всех % потенциального
-- дохода".

-- ---------------------------------------------------------------------------
-- Passive trait storage — one value per player per season, 0 = none yet.
-- ---------------------------------------------------------------------------
alter table user_seasons
  add column combo_income_bonus_percent smallint not null default 0
    check (combo_income_bonus_percent between 0 and 4),
  add column combo_time_reduction_percent smallint not null default 0
    check (combo_time_reduction_percent between 0 and 5);

-- Remembers what today's win actually rolled, same reason 0027 added
-- reward_item_type — a reload should show the same result, not "you won
-- something". Old reward_item_type column is left in place (system/partner
-- task item drops don't use user_combo_progress at all, so nothing else
-- ever wrote to it besides the daily combo win path this replaces) but is
-- no longer written to going forward.
alter table user_combo_progress
  add column reward_type text check (reward_type in ('income_bonus', 'time_reduction')),
  add column reward_value smallint;

alter table daily_combo alter column max_attempts set default 1;
update daily_combo set max_attempts = 1 where max_attempts <> 1;

-- ---------------------------------------------------------------------------
-- submit_daily_combo_guess — win/loss logic unchanged from
-- 0027_combo_item_drops.sql; only the win branch's reward changes (weighted
-- passive roll instead of a weighted item drop).
-- ---------------------------------------------------------------------------
create or replace function submit_daily_combo_guess(p_user_id uuid, p_tiers smallint[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_combo daily_combo;
  v_progress user_combo_progress;
  v_valid_count integer;
  v_correct boolean[];
  v_is_win boolean;
  v_category_roll numeric;
  v_value_roll numeric;
  v_reward_type text;
  v_reward_value smallint;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  if array_length(p_tiers, 1) is distinct from 4
     or (select count(distinct t) from unnest(p_tiers) t) <> 4 then
    raise exception 'invalid_combo_tiers';
  end if;

  select count(*) into v_valid_count
  from product_templates
  where season_id = v_season_id and tier = any(p_tiers);
  if v_valid_count <> 4 then
    raise exception 'invalid_combo_tiers';
  end if;

  v_combo := ensure_daily_combo(v_season_id);

  insert into user_combo_progress (user_id, season_id, combo_date)
  values (p_user_id, v_season_id, v_combo.combo_date)
  on conflict (user_id, season_id, combo_date) do nothing;

  select * into v_progress
  from user_combo_progress
  where user_id = p_user_id and season_id = v_season_id and combo_date = v_combo.combo_date
  for update;

  if v_progress.is_completed then
    raise exception 'already_completed';
  end if;

  if v_progress.attempts_used >= v_combo.max_attempts then
    raise exception 'no_attempts_left';
  end if;

  select array_agg(p_tiers[i] = v_combo.tiers[i] order by i)
  into v_correct
  from generate_subscripts(p_tiers, 1) i;

  select bool_and(c) into v_is_win from unnest(v_correct) c;

  if v_is_win then
    -- Category: 50/50. Value within category: weighted low-to-high, walked
    -- the same way the old combo_item_templates drop table was.
    v_category_roll := random();

    if v_category_roll < 0.5 then
      v_reward_type := 'income_bonus';
      v_value_roll := 1 + floor(random() * 100);
      select value into v_reward_value
      from (
        select value, sum(weight) over (order by value) as cum_weight
        from (values (1, 50), (2, 30), (3, 15), (4, 5)) as w(value, weight)
      ) weighted
      where cum_weight >= v_value_roll
      order by value
      limit 1;

      update user_seasons
      set combo_income_bonus_percent = v_reward_value
      where user_id = p_user_id and season_id = v_season_id;
    else
      v_reward_type := 'time_reduction';
      v_value_roll := 1 + floor(random() * 100);
      select value into v_reward_value
      from (
        select value, sum(weight) over (order by value) as cum_weight
        from (values (1, 45), (2, 25), (3, 15), (4, 10), (5, 5)) as w(value, weight)
      ) weighted
      where cum_weight >= v_value_roll
      order by value
      limit 1;

      update user_seasons
      set combo_time_reduction_percent = v_reward_value
      where user_id = p_user_id and season_id = v_season_id;
    end if;
  end if;

  update user_combo_progress
  set attempts_used = attempts_used + 1,
      last_guess_tiers = p_tiers,
      last_guess_correct = v_correct,
      is_completed = coalesce(v_is_win, false),
      completed_at = case when v_is_win then now() else completed_at end,
      reward_type = case when v_is_win then v_reward_type else reward_type end,
      reward_value = case when v_is_win then v_reward_value else reward_value end
  where user_id = p_user_id and season_id = v_season_id and combo_date = v_combo.combo_date;

  return jsonb_build_object(
    'is_win', coalesce(v_is_win, false),
    'correct', v_correct,
    'attempts_used', v_progress.attempts_used + 1,
    'attempts_max', v_combo.max_attempts,
    'reward_type', v_reward_type,
    'reward_value', v_reward_value
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- start_cycle — one addition to 0058_gangs.sql's version: the player's
-- combo_time_reduction_percent shaves that % off cycle_hours before the
-- existing bank speed-boost division, on every tier alike (it's a flat
-- percentage of whatever that tier's own cycle_hours already is, so it
-- applies uniformly regardless of tier). Everything else byte-for-byte
-- identical.
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
  v_time_reduction_percent smallint;
  v_effective_cycle_hours numeric(10, 4);
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

  select combo_time_reduction_percent into v_time_reduction_percent
  from user_seasons
  where user_id = p_user_id and season_id = v_season_id;

  v_effective_cycle_hours := v_cycle_hours * (1 - coalesce(v_time_reduction_percent, 0) / 100.0);
  if v_bank_speed_active then
    v_effective_cycle_hours := v_effective_cycle_hours / 1.10;
  end if;

  insert into cycles (user_id, season_id, tier, status, started_at, ends_at, amount_in, slot_quantity, boost_id)
  values (
    p_user_id, v_season_id, p_tier, 'running', now(),
    now() + (v_effective_cycle_hours::text || ' hours')::interval,
    v_total_price, v_free_slots, v_boost_id
  )
  returning id into v_cycle_id;

  return v_cycle_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_due_cycles — one change from 0088_late_claim_penalty.sql: the
-- player's combo_income_bonus_percent is added to the tier's payout_percent
-- *before* the late-claim halving, so a late claim halves the combined
-- total, not just the base tier rate. Everything else byte-for-byte
-- identical to 0088's version.
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
  v_income_bonus_percent smallint;
  v_effective_payout_percent numeric(6, 2);
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

  select combo_income_bonus_percent into v_income_bonus_percent
  from user_seasons
  where user_id = p_user_id and season_id = v_season_id;

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

    -- Daily-combo income-bonus passive stacks on top of the tier's own
    -- rate before anything else touches it.
    v_effective_payout_percent := v_payout_percent + coalesce(v_income_bonus_percent, 0);

    -- Late-claim penalty: only half the *combined* percent (base + bonus)
    -- once more than 4h have passed since the cycle actually finished.
    -- Body (amount_in) is never touched — this only halves the percentage
    -- applied on top of it.
    if now() - v_cycle.ends_at > interval '4 hours' then
      v_effective_payout_percent := v_effective_payout_percent / 2;
    end if;

    v_amount_out := round(v_cycle.amount_in * (1 + v_effective_payout_percent / 100), 2);

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
-- get_player_state — three changes from 0078_gang_closed_paid_description.sql:
--   1. wallet.combo_income_bonus_percent / wallet.combo_time_reduction_percent
--      — the raw passive values, for verification/future UI.
--   2. tiers[].effective_payout_percent / tiers[].effective_cycle_hours —
--      what start_cycle/resolve_due_cycles actually use once the player's
--      passives are folded in, shown per tier so the mechanic can be
--      checked on every tier at a glance. (effective_cycle_hours does NOT
--      include the dynamic bank speed-boost division — that's already
--      surfaced separately via bank_buffs.speed_boost.)
--   3. daily_combo.possible_drops / daily_combo.reward_item (old item-drop
--      fields) replaced with daily_combo.reward_type / reward_value (what
--      today's win, if any, actually rolled).
-- Everything else byte-for-byte identical.
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
  v_income_bonus_percent smallint;
  v_time_reduction_percent smallint;
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
  perform finalize_weekly_leaderboard_season();
  perform process_auto_collect_cycles();

  select case when exists (
    select 1 from bank_deposits
    where user_id = p_user_id and season_id = v_season_id
      and status = 'active' and ends_at > now() and bonus_slot
  ) then 1 else 0 end into v_bank_slot_bonus;

  select combo_income_bonus_percent, combo_time_reduction_percent
  into v_income_bonus_percent, v_time_reduction_percent
  from user_seasons
  where user_id = p_user_id and season_id = v_season_id;

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
        'combo_income_bonus_percent', us.combo_income_bonus_percent,
        'combo_time_reduction_percent', us.combo_time_reduction_percent,
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
        'effective_payout_percent', pt.payout_percent + coalesce(v_income_bonus_percent, 0),
        'effective_cycle_hours', round(pt.cycle_hours * (1 - coalesce(v_time_reduction_percent, 0) / 100.0), 2),
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
        'reward_type', ucp.reward_type,
        'reward_value', ucp.reward_value
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
        'weekly_influence_points', g.weekly_influence_points,
        'leader_name', coalesce(lu.username, lu.first_name, 'Игрок'),
        'my_role', gm_self.role,
        'target_district_id', g.target_district_id,
        'target_district_name', td.name,
        'is_closed', g.is_closed,
        'entry_price_gram', g.entry_price_gram,
        'description', g.description,
        'members', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'user_id', gm.user_id,
            'display_name', coalesce(mu.username, mu.first_name, 'Игрок'),
            'photo_url', mu.photo_url,
            'role', gm.role,
            'joined_at', gm.joined_at,
            'completed_cycles', coalesce(mus.completed_cycles_total, 0),
            'donated_gram', coalesce(donated.total_amount, 0),
            'last_active_at', greatest(last_cycle.last_started_at, donated.last_donated_at)
          ) order by
            case gm.role when 'leader' then 0 when 'co_leader' then 1 else 2 end,
            gm.joined_at
          ), '[]'::jsonb)
          from gang_members gm
          join users mu on mu.id = gm.user_id
          left join user_seasons mus on mus.user_id = gm.user_id and mus.season_id = v_season_id
          left join lateral (
            select sum(gb.amount_gram) as total_amount, max(gb.created_at) as last_donated_at
            from gang_bank_transactions gb
            where gb.gang_id = g.id and gb.from_user_id = gm.user_id
          ) donated on true
          left join lateral (
            select max(c.started_at) as last_started_at
            from cycles c
            where c.user_id = gm.user_id and c.season_id = v_season_id
          ) last_cycle on true
          where gm.gang_id = g.id
        ),
      'join_requests', case when gm_self.role = 'leader' then (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', jr.id,
          'user_id', jr.user_id,
          'display_name', coalesce(ju.username, ju.first_name, 'Игрок'),
          'photo_url', ju.photo_url,
          'created_at', jr.created_at
        ) order by jr.created_at), '[]'::jsonb)
        from gang_join_requests jr
        join users ju on ju.id = jr.user_id
        where jr.gang_id = g.id and jr.status = 'pending'
      ) else '[]'::jsonb end,
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
          limit 20
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
          limit 20
        ) gb
        join users du on du.id = gb.from_user_id
      ),
      'activity_feed', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', al.id, 'message', al.message, 'created_at', al.created_at
        ) order by al.created_at desc), '[]'::jsonb)
        from (
          select * from gang_activity_log
          where gang_id = g.id
          order by created_at desc
          limit 10
        ) al
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
