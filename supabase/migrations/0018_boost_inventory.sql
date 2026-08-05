-- 100ГРАМ: temporary "+1 Slot" boost inventory.
--
-- Sources: a Daily Combo win, or a quest whose template is flagged
-- grants_boost. A granted boost sits PENDING in the player's inventory for
-- 24h; if never applied it EXPIRES. Applying it (apply_boost) binds it to
-- one specific unlocked tier (ACTIVE), adding +1 to that tier's slot
-- capacity ON TOP of the normal 3→5 progression — deliberately not capped
-- by slot_max_count, since exceeding the normal cap is the whole point.
-- Once a purchase actually reaches into that extra capacity, the cycle row
-- is tagged (cycles.boost_id); when that cycle resolves, the boost flips to
-- USED and the extra capacity disappears (slots_open is computed live from
-- ACTIVE boosts, so this needs no separate "close the slot" step).
--
-- Simplification: at most one ACTIVE boost per tier at a time (enforced in
-- apply_boost) — the spec always frames this as "a" temporary slot, never
-- stacking multiple on one item, so this keeps the consumption bookkeeping
-- (which cycle row consumed which boost) unambiguous without a many-to-many
-- join table.

create table user_boosts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  season_id uuid not null references seasons(id) on delete cascade,
  boost_type text not null default 'EXTRA_SLOT' check (boost_type in ('EXTRA_SLOT')),
  source text not null,
  status text not null default 'PENDING' check (status in ('PENDING', 'ACTIVE', 'USED', 'EXPIRED')),
  target_tier smallint,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  activated_at timestamptz
);

create index user_boosts_user_status_idx on user_boosts (user_id, season_id, status);

alter table user_boosts enable row level security;

alter table cycles add column if not exists boost_id uuid references user_boosts(id);

alter table quest_templates add column if not exists grants_boost boolean not null default false;
update quest_templates set grants_boost = true where code in ('daily_2_cycles', 'daily_5_cycles');

-- ---------------------------------------------------------------------------
-- expire_due_boosts — lazy sweep, same pattern as resolve_due_cycles /
-- ensure_daily_combo: called on every state read, no cron required.
-- ---------------------------------------------------------------------------
create or replace function expire_due_boosts(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update user_boosts
  set status = 'EXPIRED'
  where user_id = p_user_id and status = 'PENDING' and expires_at <= now();
end;
$$;

-- ---------------------------------------------------------------------------
-- grant_boost — internal only (not exposed via any API route); called from
-- submit_daily_combo_guess on a win and claim_quest when the template
-- grants one. p_source is free text for traceability ('combo', or the
-- quest's code).
-- ---------------------------------------------------------------------------
create or replace function grant_boost(p_user_id uuid, p_source text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_boost_id uuid;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    return null;
  end if;

  insert into user_boosts (user_id, season_id, boost_type, source, status, expires_at)
  values (p_user_id, v_season_id, 'EXTRA_SLOT', p_source, 'PENDING', now() + interval '24 hours')
  returning id into v_boost_id;

  return v_boost_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- apply_boost — binds a PENDING boost to one of the player's unlocked
-- tiers. Blocks a second boost stacking on the same tier (see note above).
-- ---------------------------------------------------------------------------
create or replace function apply_boost(p_user_id uuid, p_boost_id uuid, p_tier smallint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_boost user_boosts;
begin
  perform expire_due_boosts(p_user_id);

  select * into v_boost from user_boosts
  where id = p_boost_id and user_id = p_user_id
  for update;

  if v_boost.id is null then
    raise exception 'unknown_boost';
  end if;

  if v_boost.status <> 'PENDING' then
    raise exception 'boost_not_pending';
  end if;

  if not exists (
    select 1 from user_tier_progress
    where user_id = p_user_id and season_id = v_boost.season_id and tier = p_tier
  ) then
    raise exception 'tier_locked';
  end if;

  if exists (
    select 1 from user_boosts
    where user_id = p_user_id and season_id = v_boost.season_id
      and target_tier = p_tier and status = 'ACTIVE'
  ) then
    raise exception 'tier_already_boosted';
  end if;

  update user_boosts
  set status = 'ACTIVE', target_tier = p_tier, activated_at = now()
  where id = p_boost_id;

  return jsonb_build_object('id', v_boost.id, 'target_tier', p_tier);
end;
$$;

-- ---------------------------------------------------------------------------
-- start_cycle — free-slot capacity now includes ACTIVE boosts on this tier
-- (on top of, not capped by, the normal progression cap). If this launch's
-- batch fills capacity beyond the un-boosted cap, the oldest ACTIVE boost
-- on the tier is tagged onto the new cycle row.
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

  v_total_slots := v_tier_slots + v_boost_count;

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

  insert into cycles (user_id, season_id, tier, status, started_at, ends_at, amount_in, slot_quantity, boost_id)
  values (
    p_user_id, v_season_id, p_tier, 'running', now(),
    now() + (v_cycle_hours::text || ' hours')::interval, v_total_price, v_free_slots, v_boost_id
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

  return v_cycle_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_due_cycles — when a claimed cycle carries a boost_id, that's
-- "on_cycle_complete": flip the boost ACTIVE -> USED. Its extra capacity
-- disappears automatically since slots_open only counts ACTIVE boosts.
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
-- submit_daily_combo_guess — a win now also grants an EXTRA_SLOT boost.
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

  update user_combo_progress
  set attempts_used = attempts_used + 1,
      last_guess_tiers = p_tiers,
      last_guess_correct = v_correct,
      is_completed = coalesce(v_is_win, false),
      completed_at = case when v_is_win then now() else completed_at end
  where user_id = p_user_id and season_id = v_season_id and combo_date = v_combo.combo_date;

  if v_is_win then
    update user_seasons
    set balance = balance + v_combo.reward_amount, total_earned = total_earned + v_combo.reward_amount
    where user_id = p_user_id and season_id = v_season_id;

    perform grant_boost(p_user_id, 'combo');
  end if;

  return jsonb_build_object(
    'is_win', coalesce(v_is_win, false),
    'correct', v_correct,
    'attempts_used', v_progress.attempts_used + 1,
    'attempts_max', v_combo.max_attempts,
    'reward_amount', v_combo.reward_amount
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- claim_quest — now also grants a boost when the template is flagged, and
-- reports back whether it did (jsonb return instead of a bare numeric —
-- Postgres won't let CREATE OR REPLACE change the return type, hence the
-- explicit DROP first).
-- ---------------------------------------------------------------------------
drop function if exists claim_quest(uuid, uuid);

create or replace function claim_quest(p_user_id uuid, p_quest_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reward numeric(12, 2);
  v_season_id uuid;
  v_grants_boost boolean;
  v_quest_code text;
  v_boost_granted boolean := false;
begin
  select qt.reward_amount, uqp.season_id, qt.grants_boost, qt.code
  into v_reward, v_season_id, v_grants_boost, v_quest_code
  from user_quest_progress uqp
  join quest_templates qt on qt.id = uqp.quest_id
  where uqp.user_id = p_user_id
    and uqp.quest_id = p_quest_id
    and uqp.quest_date = current_date
    and uqp.completed_at is not null
    and uqp.claimed_at is null
  for update of uqp;

  if v_reward is null then
    raise exception 'quest_not_claimable';
  end if;

  update user_quest_progress set claimed_at = now()
  where user_id = p_user_id and quest_id = p_quest_id and quest_date = current_date;

  update user_seasons set balance = balance + v_reward, total_earned = total_earned + v_reward
  where user_id = p_user_id and season_id = v_season_id;

  if v_grants_boost then
    perform grant_boost(p_user_id, v_quest_code);
    v_boost_granted := true;
  end if;

  return jsonb_build_object('reward_amount', v_reward, 'boost_granted', v_boost_granted);
end;
$$;

-- ---------------------------------------------------------------------------
-- get_player_state — tiers gain slots_boost/slots_total; new top-level
-- `boosts` array (the "Мои бусты" inventory: PENDING + ACTIVE only).
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
  perform expire_due_boosts(p_user_id);

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
        'slots_boost', coalesce(bc.boost_count, 0),
        'slots_total', case when utp.tier is not null
          then tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level) + coalesce(bc.boost_count, 0)
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
    )
  ) into v_result;

  return v_result;
end;
$$;
