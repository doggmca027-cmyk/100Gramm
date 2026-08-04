-- 100ГРАМ: "Связи на районе" — subscribe-to-partner-channel tasks.
-- Verification happens in the Next.js route (Telegram Bot API getChatMember
-- needs an HTTP call, which plpgsql can't make reliably); the RPC only ever
-- performs the trusted balance mutation once the route has confirmed
-- membership, matching the pattern used everywhere else (cycles, quests).

create table partner_tasks (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references seasons(id) on delete cascade,
  title text not null,
  description text,
  reward_amount numeric(12, 2) not null check (reward_amount >= 0),
  channel_username text not null,
  channel_id text not null, -- e.g. "-1001234567890", passed to getChatMember
  icon_url text,
  sort_order integer not null default 0,
  is_active boolean not null default true
);

create table user_partner_tasks (
  user_id uuid not null references users(id) on delete cascade,
  task_id uuid not null references partner_tasks(id) on delete cascade,
  season_id uuid not null references seasons(id) on delete cascade,
  completed_at timestamptz not null default now(),
  primary key (user_id, task_id)
);

alter table partner_tasks enable row level security;
alter table user_partner_tasks enable row level security;

-- ---------------------------------------------------------------------------
-- get_partner_task_channel — just enough for the route to call getChatMember
-- ---------------------------------------------------------------------------
create or replace function get_partner_task_channel(p_task_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'channel_id', channel_id,
    'reward_amount', reward_amount,
    'season_id', season_id,
    'is_active', is_active
  )
  from partner_tasks where id = p_task_id;
$$;

-- ---------------------------------------------------------------------------
-- claim_partner_task — trusted balance mutation, called only after the route
-- has confirmed membership via the Bot API
-- ---------------------------------------------------------------------------
create or replace function claim_partner_task(p_user_id uuid, p_task_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_reward numeric(12, 2);
  v_active boolean;
begin
  select season_id, reward_amount, is_active
  into v_season_id, v_reward, v_active
  from partner_tasks where id = p_task_id;

  if v_season_id is null or v_season_id <> active_season_id() or not v_active then
    raise exception 'unknown_task';
  end if;

  insert into user_partner_tasks (user_id, task_id, season_id)
  values (p_user_id, p_task_id, v_season_id)
  on conflict (user_id, task_id) do nothing;

  if not found then
    raise exception 'already_claimed';
  end if;

  update user_seasons set balance = balance + v_reward, total_earned = total_earned + v_reward
  where user_id = p_user_id and season_id = v_season_id;

  return v_reward;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_player_state — add partner_tasks list
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
    'profile', (
      select jsonb_build_object('username', u.username, 'first_name', u.first_name)
      from users u where u.id = p_user_id
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
    )
  ) into v_result;

  return v_result;
end;
$$;
