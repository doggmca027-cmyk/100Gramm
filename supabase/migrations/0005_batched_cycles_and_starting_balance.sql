-- 100ГРАМ: batch launches + a starting balance so the game isn't a soft-lock.
--
-- 1) One "launch" now commits every currently-idle slot to the chosen tier
--    in a single `cycles` row (slot_quantity), instead of one row per slot.
--    Progression counting is untouched — resolve_due_cycles already does
--    +1 per resolved ROW, and a row now represents a whole batch, so N
--    slots started together always count as exactly 1 cycle, matching the
--    original Day-3.3 example (money/slots scale payout, not pacing).
-- 2) New players start with a small virtual balance (season-configurable)
--    so the very first launch is possible without a real-money deposit.

alter table cycles add column if not exists slot_quantity integer not null default 1 check (slot_quantity > 0);

update seasons
set config = config || jsonb_build_object('starting_balance', 3)
where slug = 'season-1';

-- ---------------------------------------------------------------------------
-- bootstrap_user — same as before, plus a season-configurable starting balance
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
  v_starting_balance numeric(14, 2);
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

  select coalesce((config->>'base_slots')::integer, 3),
         coalesce((config->>'starting_balance')::numeric, 0)
  into v_base_slots, v_starting_balance
  from seasons where id = v_season_id;

  insert into user_seasons (user_id, season_id, slots_count, balance, total_earned)
  values (v_user_id, v_season_id, v_base_slots, v_starting_balance, v_starting_balance)
  on conflict (user_id, season_id) do nothing;

  insert into user_tier_progress (user_id, season_id, tier, completed_cycles, unlocked_at)
  values (v_user_id, v_season_id, 1, 0, now())
  on conflict (user_id, season_id, tier) do nothing;

  return v_user_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- start_cycle — fills every idle slot for the tier in one batched row
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
  v_used_slots integer;
  v_free_slots integer;
  v_balance numeric(14, 2);
  v_total_price numeric(12, 2);
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

  select coalesce(sum(slot_quantity), 0) into v_used_slots
  from cycles
  where user_id = p_user_id and season_id = v_season_id and status = 'running';

  v_free_slots := v_slots_count - v_used_slots;
  if v_free_slots <= 0 then
    raise exception 'no_free_slots';
  end if;

  -- Fill as many idle slots as the player can afford, capped at all of them.
  -- Whatever quantity ends up in this one row, it is still exactly 1 cycle
  -- towards tier/slot progression once it resolves.
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

  return v_cycle_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_player_state — expose slot_quantity so the UI can show batch size and
-- compute free slots as slots_count - sum(active slot_quantity)
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
        'starts_at', s.starts_at, 'ends_at', s.ends_at, 'config', s.config
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
        'amount_in', c.amount_in, 'slot_quantity', c.slot_quantity,
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
