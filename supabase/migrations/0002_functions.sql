-- 100ГРАМ: economy engine as SECURITY DEFINER RPCs.
-- Every function trusts p_user_id as given — callers (Next.js route handlers)
-- must derive it themselves from a validated session, never from client input.

create or replace function active_season_id()
returns uuid
language sql
stable
as $$
  select id from seasons where is_active limit 1;
$$;

-- ---------------------------------------------------------------------------
-- bootstrap_user — idempotent upsert + enrollment into the active season
-- ---------------------------------------------------------------------------
create or replace function bootstrap_user(
  p_telegram_id bigint,
  p_username text,
  p_first_name text,
  p_ref_code text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_season_id uuid;
  v_referrer_id uuid;
  v_base_slots integer;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  insert into users (telegram_id, username, first_name)
  values (p_telegram_id, p_username, p_first_name)
  on conflict (telegram_id) do update
    set username = excluded.username,
        first_name = excluded.first_name
  returning id into v_user_id;

  if p_ref_code is not null and p_ref_code ~ '^[0-9]+$' then
    select id into v_referrer_id from users where telegram_id = p_ref_code::bigint;
    if v_referrer_id is not null and v_referrer_id <> v_user_id then
      update users set referred_by = v_referrer_id
      where id = v_user_id and referred_by is null;
    end if;
  end if;

  v_base_slots := coalesce((select (config->>'base_slots')::integer from seasons where id = v_season_id), 3);

  insert into user_seasons (user_id, season_id, slots_count)
  values (v_user_id, v_season_id, v_base_slots)
  on conflict (user_id, season_id) do nothing;

  insert into user_tier_progress (user_id, season_id, tier, completed_cycles, unlocked_at)
  values (v_user_id, v_season_id, 1, 0, now())
  on conflict (user_id, season_id, tier) do nothing;

  return v_user_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_due_cycles — lazy tick: claim everything whose timer has elapsed
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
  v_completed_cycles_total integer;
  v_slots_count integer;
  v_base_slots integer;
  v_cycles_per_slot integer;
  v_max_slots integer;
  v_new_slots integer;
  v_max_tier smallint;
  v_tier_progress record;
  v_next_required_cycles integer;
  v_next_min_hours numeric(8, 2);
  v_referrer1 uuid;
  v_referrer2 uuid;
  v_referrer3 uuid;
  v_bonus numeric(12, 2);
  v_claimed_count integer := 0;
  v_quest record;
  v_container_template_id uuid;
  v_open_minutes integer;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    return;
  end if;

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
    where user_id = p_user_id and season_id = v_season_id
    returning completed_cycles_total, slots_count into v_completed_cycles_total, v_slots_count;

    update user_tier_progress
    set completed_cycles = completed_cycles + 1
    where user_id = p_user_id and season_id = v_season_id and tier = v_cycle.tier;

    v_claimed_count := v_claimed_count + 1;

    -- every claimed cycle drops one container, weighted by drop_weight
    -- (exponential-clock method: min of -ln(U)/weight samples proportional to weight)
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

    -- slots: grow with total completed cycles, never shrink
    select coalesce((config->>'base_slots')::integer, 3),
           coalesce((config->>'cycles_per_slot')::integer, 5),
           (config->>'max_slots')::integer
    into v_base_slots, v_cycles_per_slot, v_max_slots
    from seasons where id = v_season_id;

    v_new_slots := v_base_slots + floor(v_completed_cycles_total::numeric / v_cycles_per_slot)::integer;
    if v_max_slots is not null and v_new_slots > v_max_slots then
      v_new_slots := v_max_slots;
    end if;
    if v_new_slots > v_slots_count then
      update user_seasons set slots_count = v_new_slots
      where user_id = p_user_id and season_id = v_season_id;
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

    -- 3-level virality-loop bonus (virtual GRAM only), paid to seasoned referrers
    select referred_by into v_referrer1 from users where id = p_user_id;
    if v_referrer1 is not null then
      v_bonus := round(v_amount_out * 0.10, 2);
      update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
      where user_id = v_referrer1 and season_id = v_season_id;
      if found then
        insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount)
        values (v_referrer1, p_user_id, 1, v_cycle.id, v_bonus);
      end if;

      select referred_by into v_referrer2 from users where id = v_referrer1;
      if v_referrer2 is not null then
        v_bonus := round(v_amount_out * 0.05, 2);
        update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
        where user_id = v_referrer2 and season_id = v_season_id;
        if found then
          insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount)
          values (v_referrer2, p_user_id, 2, v_cycle.id, v_bonus);
        end if;

        select referred_by into v_referrer3 from users where id = v_referrer2;
        if v_referrer3 is not null then
          v_bonus := round(v_amount_out * 0.02, 2);
          update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
          where user_id = v_referrer3 and season_id = v_season_id;
          if found then
            insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount)
            values (v_referrer3, p_user_id, 3, v_cycle.id, v_bonus);
          end if;
        end if;
      end if;
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
-- start_cycle
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
  v_slots_count integer;
  v_running_count integer;
  v_balance numeric(14, 2);
  v_cycle_id uuid;
begin
  perform resolve_due_cycles(p_user_id);

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  if not exists (
    select 1 from user_tier_progress
    where user_id = p_user_id and season_id = v_season_id and tier = p_tier
  ) then
    raise exception 'tier_locked';
  end if;

  select price, cycle_hours into v_price, v_cycle_hours
  from product_templates
  where season_id = v_season_id and tier = p_tier;

  if v_price is null then
    raise exception 'unknown_tier';
  end if;

  select slots_count, balance into v_slots_count, v_balance
  from user_seasons
  where user_id = p_user_id and season_id = v_season_id
  for update;

  select count(*) into v_running_count
  from cycles
  where user_id = p_user_id and season_id = v_season_id and status = 'running';

  if v_running_count >= v_slots_count then
    raise exception 'no_free_slots';
  end if;

  if v_balance < v_price then
    raise exception 'insufficient_balance';
  end if;

  update user_seasons set balance = balance - v_price
  where user_id = p_user_id and season_id = v_season_id;

  insert into cycles (user_id, season_id, tier, status, started_at, ends_at, amount_in)
  values (p_user_id, v_season_id, p_tier, 'running', now(), now() + (v_cycle_hours::text || ' hours')::interval, v_price)
  returning id into v_cycle_id;

  return v_cycle_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- open_container
-- ---------------------------------------------------------------------------
create or replace function open_container(p_user_id uuid, p_container_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reward numeric(12, 2);
  v_min numeric(12, 2);
  v_max numeric(12, 2);
  v_season_id uuid;
begin
  select ct.reward_min, ct.reward_max, uc.season_id
  into v_min, v_max, v_season_id
  from user_containers uc
  join container_templates ct on ct.id = uc.container_template_id
  where uc.id = p_container_id
    and uc.user_id = p_user_id
    and uc.opened_at is null
    and uc.opens_at <= now()
  for update of uc;

  if v_min is null then
    raise exception 'container_not_ready';
  end if;

  v_reward := round(v_min + random() * (v_max - v_min), 2);

  update user_containers set opened_at = now(), reward_amount = v_reward
  where id = p_container_id;

  update user_seasons set balance = balance + v_reward, total_earned = total_earned + v_reward
  where user_id = p_user_id and season_id = v_season_id;

  return v_reward;
end;
$$;

-- ---------------------------------------------------------------------------
-- claim_quest
-- ---------------------------------------------------------------------------
create or replace function claim_quest(p_user_id uuid, p_quest_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reward numeric(12, 2);
  v_season_id uuid;
begin
  select qt.reward_amount, uqp.season_id into v_reward, v_season_id
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

  return v_reward;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_leaderboard
-- ---------------------------------------------------------------------------
create or replace function get_leaderboard(p_metric text default 'total_earned', p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_result jsonb;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into v_result
  from (
    select
      coalesce(u.username, u.first_name, 'Игрок') as display_name,
      us.total_earned,
      us.completed_cycles_total
    from user_seasons us
    join users u on u.id = us.user_id
    where us.season_id = v_season_id
    order by
      case when p_metric = 'completed_cycles_total' then us.completed_cycles_total end desc,
      case when p_metric <> 'completed_cycles_total' then us.total_earned end desc
    limit greatest(p_limit, 1)
  ) t;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_player_state — everything the UI needs for one render
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

  select jsonb_build_object(
    'season', (
      select jsonb_build_object(
        'id', s.id, 'slug', s.slug, 'title', s.title, 'story_theme', s.story_theme,
        'starts_at', s.starts_at, 'ends_at', s.ends_at
      ) from seasons s where s.id = v_season_id
    ),
    'wallet', (
      select jsonb_build_object(
        'balance', us.balance,
        'total_earned', us.total_earned,
        'slots_count', us.slots_count,
        'completed_cycles_total', us.completed_cycles_total,
        'has_seen_intro', us.has_seen_intro
      ) from user_seasons us where us.user_id = p_user_id and us.season_id = v_season_id
    ),
    'rank', (
      select jsonb_build_object('name', r.name, 'icon', r.icon)
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
        'price', pt.price,
        'payout_percent', pt.payout_percent,
        'cycle_hours', pt.cycle_hours,
        'unlocked', (utp.tier is not null),
        'completed_cycles', coalesce(utp.completed_cycles, 0),
        'unlock_required_cycles', pt.unlock_required_cycles,
        'unlock_min_hours', pt.unlock_min_hours,
        'unlocked_at', utp.unlocked_at
      ) order by pt.tier), '[]'::jsonb)
      from product_templates pt
      left join user_tier_progress utp
        on utp.season_id = v_season_id and utp.tier = pt.tier and utp.user_id = p_user_id
      where pt.season_id = v_season_id
    ),
    'active_cycles', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'tier', c.tier, 'started_at', c.started_at, 'ends_at', c.ends_at,
        'amount_in', c.amount_in,
        'seconds_remaining', greatest(0, extract(epoch from (c.ends_at - now())))
      ) order by c.ends_at), '[]'::jsonb)
      from cycles c
      where c.user_id = p_user_id and c.season_id = v_season_id and c.status = 'running'
    ),
    'quests', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', qt.id, 'title', qt.title, 'description', qt.description,
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
    'squad', jsonb_build_object(
      'invite_code', (select telegram_id::text from users where id = p_user_id),
      'referred_count', (select count(*) from users where referred_by = p_user_id),
      'earned_total', (select coalesce(sum(amount), 0) from referral_earnings where beneficiary_id = p_user_id)
    )
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- mark_intro_seen
-- ---------------------------------------------------------------------------
create or replace function mark_intro_seen(p_user_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update user_seasons set has_seen_intro = true
  where user_id = p_user_id and season_id = active_season_id();
$$;
