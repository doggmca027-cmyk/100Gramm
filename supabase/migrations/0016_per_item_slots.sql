-- 100ГРАМ: per-item slot progression, replacing the global shared slot pool.
--
-- Before: user_seasons.slots_count was ONE number shared across all 8
-- tiers — completing a cycle on ANY tier grew a pool everyone drew from.
-- After: each tier gets its own independent 3→5 slot pool, driven by that
-- tier's own completed_cycles (already tracked in user_tier_progress for
-- tier-unlock gating — reused here instead of a new parallel counter, so
-- there's exactly one source of truth per (user, tier)).
--
-- Formula per tier: min(slot_max_count, slot_base_count + floor(completed_cycles / slot_cycles_per_level))
-- Season-1 defaults (3 base, 5 max, 5 cycles/level) match what's already in
-- seasons.config, just capped at 5 instead of growing unbounded — this was
-- an explicitly open question in docs/GDD.md §slots, now resolved.

alter table product_templates add column if not exists slot_base_count smallint not null default 3;
alter table product_templates add column if not exists slot_max_count smallint not null default 5;
alter table product_templates add column if not exists slot_cycles_per_level smallint not null default 5;

-- user_seasons.slots_count is obsolete — capacity is now computed per tier,
-- on read, from user_tier_progress.completed_cycles. Nothing else in the
-- app reads this column after this migration (grepped clean).
alter table user_seasons drop column if exists slots_count;

-- ---------------------------------------------------------------------------
-- tier_slots_open — pure formula, no table access, reused by start_cycle,
-- get_player_state, get_item_slot_info and buy_max_slots so there's exactly
-- one implementation of the cap.
-- ---------------------------------------------------------------------------
create or replace function tier_slots_open(
  p_completed_cycles integer,
  p_base smallint,
  p_max smallint,
  p_per_level smallint
) returns smallint
language sql
immutable
as $$
  select least(
    p_max,
    (p_base + floor(p_completed_cycles::numeric / greatest(p_per_level, 1)::numeric))::smallint
  )
$$;

-- ---------------------------------------------------------------------------
-- bootstrap_user — no longer seeds user_seasons.slots_count (column gone)
-- ---------------------------------------------------------------------------
create or replace function bootstrap_user(
  p_telegram_id bigint,
  p_username text,
  p_first_name text,
  p_ref_code text default null,
  p_photo_url text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_season_id uuid;
  v_referrer_id uuid;
  v_starting_balance numeric(14, 2);
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  insert into users (telegram_id, username, first_name, photo_url)
  values (p_telegram_id, p_username, p_first_name, p_photo_url)
  on conflict (telegram_id) do update
    set username = excluded.username,
        first_name = excluded.first_name,
        photo_url = excluded.photo_url
  returning id into v_user_id;

  if p_ref_code is not null and p_ref_code ~ '^[0-9]+$' then
    select id into v_referrer_id from users where telegram_id = p_ref_code::bigint;
    if v_referrer_id is not null and v_referrer_id <> v_user_id then
      update users set referred_by = v_referrer_id
      where id = v_user_id and referred_by is null;
    end if;
  end if;

  select coalesce((config->>'starting_balance')::numeric, 0)
  into v_starting_balance
  from seasons where id = v_season_id;

  insert into user_seasons (user_id, season_id, balance, total_earned)
  values (v_user_id, v_season_id, v_starting_balance, v_starting_balance)
  on conflict (user_id, season_id) do nothing;

  insert into user_tier_progress (user_id, season_id, tier, completed_cycles, unlocked_at)
  values (v_user_id, v_season_id, 1, 0, now())
  on conflict (user_id, season_id, tier) do nothing;

  return v_user_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_due_cycles — dropped the global "grow user_seasons.slots_count"
-- block entirely. Slot capacity is now a pure read-time formula off
-- user_tier_progress.completed_cycles (already incremented below), so there
-- is nothing left to materialize.
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
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    return;
  end if;

  select coalesce((config->'features'->>'containers')::boolean, false)
  into v_containers_enabled
  from seasons where id = v_season_id;

  for v_cycle in
    select c.* from cycles c
    where c.user_id = p_user_id
      and c.season_id = v_season_id
      and c.status = 'running'
      and c.ends_at <= now()
    order by c.ends_at asc
  loop
    select payout_percent into v_payout_percent
    from product_templates
    where season_id = v_season_id and tier = v_cycle.tier;

    v_amount_out := round(v_cycle.amount_in * (1 + v_payout_percent / 100), 2);

    update cycles
    set status = 'claimed', claimed_at = now(), amount_out = v_amount_out
    where id = v_cycle.id;

    update user_seasons
    set balance = balance + v_amount_out,
        total_earned = total_earned + v_amount_out,
        completed_cycles_total = completed_cycles_total + 1
    where user_id = p_user_id and season_id = v_season_id;

    update user_tier_progress
    set completed_cycles = completed_cycles + 1
    where user_id = p_user_id and season_id = v_season_id and tier = v_cycle.tier;

    v_claimed_count := v_claimed_count + 1;

    -- containers: season-1 has them turned off (coming in a later season)
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

    -- tier unlock: needs BOTH enough completed cycles AND minimum elapsed time,
    -- so stacking slots can't rush progression (only wall-clock time can).
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

    if v_next_required_cycles is not null
       and v_tier_progress.completed_cycles >= v_next_required_cycles
       and now() >= v_tier_progress.unlocked_at + (v_next_min_hours::text || ' hours')::interval
       and exists (select 1 from product_templates where season_id = v_season_id and tier = v_max_tier + 1)
    then
      insert into user_tier_progress (user_id, season_id, tier, completed_cycles, unlocked_at)
      values (p_user_id, v_season_id, v_max_tier + 1, 0, now())
      on conflict (user_id, season_id, tier) do nothing;
    end if;
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
-- start_cycle — free-slot check is now scoped to p_tier only (was: shared
-- pool across all tiers). Same batching behaviour (one launch fills every
-- affordable idle slot of THIS tier into one row) — when the tier is
-- already maxed at 5/5 and all 5 are free, this alone already fills all 5,
-- which is the "wholesale" case; buy_max_slots below just adds an explicit,
-- validated entry point for it.
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
  v_combo daily_combo;
  v_found_tiers smallint[];
  v_combo_already_done boolean;
begin
  perform resolve_due_cycles(p_user_id);

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

  select coalesce(sum(slot_quantity), 0) into v_used_slots
  from cycles
  where user_id = p_user_id and season_id = v_season_id and tier = p_tier and status = 'running';

  v_free_slots := v_tier_slots - v_used_slots;
  if v_free_slots <= 0 then
    raise exception 'no_free_slots';
  end if;

  if v_balance < v_price then
    raise exception 'insufficient_balance';
  end if;
  v_free_slots := least(v_free_slots, floor(v_balance / v_price)::integer);
  v_total_price := v_price * v_free_slots;

  update user_seasons set balance = balance - v_total_price
  where user_id = p_user_id and season_id = v_season_id;

  insert into cycles (user_id, season_id, tier, status, started_at, ends_at, amount_in, slot_quantity)
  values (
    p_user_id, v_season_id, p_tier, 'running', now(),
    now() + (v_cycle_hours::text || ' hours')::interval, v_total_price, v_free_slots
  )
  returning id into v_cycle_id;

  -- 3-level referral bonus, paid now, off the deposit (v_total_price), to
  -- seasoned referrers (must already have a user_seasons row this season)
  select referred_by into v_referrer1 from users where id = p_user_id;
  if v_referrer1 is not null then
    select is_ambassador into v_is_ambassador from users where id = v_referrer1;
    v_bonus := round(v_total_price * (case when v_is_ambassador then 0.15 else 0.10 end), 2);
    update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
    where user_id = v_referrer1 and season_id = v_season_id;
    if found then
      insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount)
      values (v_referrer1, p_user_id, 1, v_cycle_id, v_bonus);
    end if;

    select referred_by into v_referrer2 from users where id = v_referrer1;
    if v_referrer2 is not null then
      select is_ambassador into v_is_ambassador from users where id = v_referrer2;
      v_bonus := round(v_total_price * (case when v_is_ambassador then 0.09 else 0.05 end), 2);
      update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
      where user_id = v_referrer2 and season_id = v_season_id;
      if found then
        insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount)
        values (v_referrer2, p_user_id, 2, v_cycle_id, v_bonus);
      end if;

      select referred_by into v_referrer3 from users where id = v_referrer2;
      if v_referrer3 is not null then
        select is_ambassador into v_is_ambassador from users where id = v_referrer3;
        v_bonus := round(v_total_price * (case when v_is_ambassador then 0.05 else 0.02 end), 2);
        update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
        where user_id = v_referrer3 and season_id = v_season_id;
        if found then
          insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount)
          values (v_referrer3, p_user_id, 3, v_cycle_id, v_bonus);
        end if;
      end if;
    end if;
  end if;

  -- Daily Combo — server-side only reveal + reward (see 0014/0015).
  v_combo := ensure_daily_combo(v_season_id);
  if v_combo.id is not null and p_tier = any(v_combo.tiers) then
    insert into user_combo_progress (user_id, season_id, combo_date, found_tiers)
    values (p_user_id, v_season_id, v_combo.combo_date, array[p_tier])
    on conflict (user_id, season_id, combo_date) do update
      set found_tiers = case
        when p_tier = any(user_combo_progress.found_tiers) then user_combo_progress.found_tiers
        else array_append(user_combo_progress.found_tiers, p_tier)
      end;

    select is_completed, found_tiers into v_combo_already_done, v_found_tiers
    from user_combo_progress
    where user_id = p_user_id and season_id = v_season_id and combo_date = v_combo.combo_date;

    if not v_combo_already_done and array_length(v_found_tiers, 1) >= array_length(v_combo.tiers, 1) then
      update user_combo_progress set is_completed = true, completed_at = now()
      where user_id = p_user_id and season_id = v_season_id and combo_date = v_combo.combo_date;

      update user_seasons
      set balance = balance + v_combo.reward_amount, total_earned = total_earned + v_combo.reward_amount
      where user_id = p_user_id and season_id = v_season_id;
    end if;
  end if;

  return v_cycle_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_item_slot_info — standalone per-tier read, independent of a full
-- get_player_state fetch (e.g. for a detail-screen refresh after a purchase).
-- ---------------------------------------------------------------------------
create or replace function get_item_slot_info(p_user_id uuid, p_tier smallint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_completed_cycles integer;
  v_base smallint;
  v_max smallint;
  v_per_level smallint;
  v_slots_open smallint;
  v_slots_used integer;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select completed_cycles into v_completed_cycles
  from user_tier_progress
  where user_id = p_user_id and season_id = v_season_id and tier = p_tier;

  if not found then
    raise exception 'tier_locked';
  end if;

  select slot_base_count, slot_max_count, slot_cycles_per_level
  into v_base, v_max, v_per_level
  from product_templates
  where season_id = v_season_id and tier = p_tier;

  v_slots_open := tier_slots_open(v_completed_cycles, v_base, v_max, v_per_level);

  select coalesce(sum(slot_quantity), 0) into v_slots_used
  from cycles
  where user_id = p_user_id and season_id = v_season_id and tier = p_tier and status = 'running';

  return jsonb_build_object(
    'tier', p_tier,
    'completed_cycles', v_completed_cycles,
    'slots_open', v_slots_open,
    'slots_max', v_max,
    'slots_used', v_slots_used,
    'slots_free', greatest(0, v_slots_open - v_slots_used),
    'cycles_to_next_slot', case when v_slots_open >= v_max then null
      else v_per_level - (v_completed_cycles % v_per_level) end,
    'can_buy_max', v_slots_open >= v_max
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- buy_max_slots — explicit "wholesale" entry point: validates the tier is
-- actually fully upgraded (5/5) server-side, then delegates to start_cycle
-- for the real purchase (same trusted insert path, zero duplicated logic).
-- ---------------------------------------------------------------------------
create or replace function buy_max_slots(p_user_id uuid, p_tier smallint)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_completed_cycles integer;
  v_base smallint;
  v_max smallint;
  v_per_level smallint;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select completed_cycles into v_completed_cycles
  from user_tier_progress
  where user_id = p_user_id and season_id = v_season_id and tier = p_tier;
  if not found then
    raise exception 'tier_locked';
  end if;

  select slot_base_count, slot_max_count, slot_cycles_per_level
  into v_base, v_max, v_per_level
  from product_templates
  where season_id = v_season_id and tier = p_tier;

  if tier_slots_open(v_completed_cycles, v_base, v_max, v_per_level) < v_max then
    raise exception 'slots_not_maxed';
  end if;

  return start_cycle(p_user_id, p_tier);
end;
$$;

-- ---------------------------------------------------------------------------
-- get_player_state — tiers now carry per-tier slot info; wallet.slots_count
-- (global, obsolete) is replaced with total_slots_open/total_slots_used
-- (sum across unlocked tiers — a display aggregate only, not a shared pool).
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
begin
  perform resolve_due_cycles(p_user_id);

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  perform ensure_daily_combo(v_season_id);

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
        'username', u.username, 'first_name', u.first_name, 'photo_url', u.photo_url
      )
      from users u where u.id = p_user_id
    ),
    'wallet', (
      select jsonb_build_object(
        'balance', us.balance,
        'total_earned', us.total_earned,
        'completed_cycles_total', us.completed_cycles_total,
        'has_seen_intro', us.has_seen_intro,
        'total_slots_open', (
          select coalesce(sum(tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level)), 0)
          from user_tier_progress utp
          join product_templates pt on pt.season_id = utp.season_id and pt.tier = utp.tier
          where utp.user_id = p_user_id and utp.season_id = v_season_id
        ),
        'total_slots_used', (
          select coalesce(sum(slot_quantity), 0) from cycles
          where user_id = p_user_id and season_id = v_season_id and status = 'running'
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
        'channel_username', pt.channel_username,
        'icon_url', pt.icon_url,
        'completed', (upt.task_id is not null)
      ) order by pt.sort_order), '[]'::jsonb)
      from partner_tasks pt
      left join user_partner_tasks upt
        on upt.task_id = pt.id and upt.user_id = p_user_id
      where pt.season_id = v_season_id and pt.is_active
    ),
    'squad', jsonb_build_object(
      'invite_code', (select telegram_id::text from users where id = p_user_id),
      'referred_count', (select count(*) from users where referred_by = p_user_id),
      'earned_total', (select coalesce(sum(amount), 0) from referral_earnings where beneficiary_id = p_user_id)
    ),
    'daily_combo', (
      select jsonb_build_object(
        'reward_amount', dc.reward_amount,
        'is_completed', coalesce(ucp.is_completed, false),
        'found_count', coalesce(array_length(ucp.found_tiers, 1), 0),
        'total_count', array_length(dc.tiers, 1),
        'resets_at', ((dc.combo_date + 1)::timestamp at time zone 'utc'),
        'slots', (
          select coalesce(jsonb_agg(
            case when t = any(coalesce(ucp.found_tiers, '{}'::smallint[]))
              then (
                select jsonb_build_object(
                  'found', true, 'tier', pt.tier, 'name', pt.name,
                  'name_i18n', jsonb_build_object('ru', pt.name, 'en', pt.name_i18n->>'en', 'tr', pt.name_i18n->>'tr', 'id', pt.name_i18n->>'id')
                )
                from product_templates pt where pt.season_id = v_season_id and pt.tier = t
              )
              else jsonb_build_object('found', false)
            end
          ), '[]'::jsonb)
          from unnest(dc.tiers) as t
        )
      )
      from daily_combo dc
      left join user_combo_progress ucp
        on ucp.user_id = p_user_id and ucp.season_id = v_season_id and ucp.combo_date = dc.combo_date
      where dc.season_id = v_season_id and dc.combo_date = (now() at time zone 'utc')::date
    )
  ) into v_result;

  return v_result;
end;
$$;
