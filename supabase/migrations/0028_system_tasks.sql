-- 100ГРАМ: extended system tasks ("Связи на районе") — social/referral/
-- gameplay milestones, rewarded purely in boost items (reusing
-- combo_item_templates/user_inventory from 0027) + XP. No GRAM anywhere in
-- this reward path, per spec.
--
-- Deviation from the literal spec: a task can grant more than one item type
-- ("Своя сеть" = auto_collect_3d + 2x time_skip_10pct) — a single
-- reward_item_type/reward_item_qty column pair on system_tasks can't
-- represent that, so rewards live in a proper one-to-many
-- system_task_rewards table instead. user_id/season_id are used throughout
-- (not telegram_id), same reasoning as every other table in this schema.
--
-- Referral/gameplay progress is computed live from data we already track
-- (users.referred_by, user_seasons.completed_cycles_total,
-- user_tier_progress) — no separate counter to keep in sync. Social tasks
-- (channel_sub/chat_join) are verified the same way partner_tasks already
-- are: the API route calls Telegram's getChatMember *before* ever calling
-- the claim RPC, which is why claim_system_task doesn't re-check social
-- tasks itself (same trust boundary as claim_partner_task).

-- ---------------------------------------------------------------------------
-- system_tasks — the catalog.
--   target_type: 'referrals_level_1' | 'cycles_completed' | 'tier_reached'
--                | 'channel_sub' | 'chat_join' | 'post_view'
--   target_value: channel/chat username for the social checks, the tier
--                 number (as text) for tier_reached, unused otherwise
--   required_count: the referral/cycle count target; 1 for social tasks
-- ---------------------------------------------------------------------------
create table system_tasks (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title text not null,
  description text,
  category text not null check (category in ('social', 'referral', 'gameplay')),
  target_type text not null check (target_type in
    ('referrals_level_1', 'cycles_completed', 'tier_reached', 'channel_sub', 'chat_join', 'post_view')),
  target_value text,
  required_count integer not null default 1,
  reward_xp integer not null default 0,
  is_active boolean not null default true,
  sort_order smallint not null default 0
);

alter table system_tasks enable row level security;

create policy "system_tasks are publicly readable"
  on system_tasks for select
  using (true);

create table system_task_rewards (
  task_id uuid not null references system_tasks(id) on delete cascade,
  item_type text not null references combo_item_templates(item_type),
  quantity integer not null default 1 check (quantity > 0),
  primary key (task_id, item_type)
);

alter table system_task_rewards enable row level security;

create policy "system_task_rewards are publicly readable"
  on system_task_rewards for select
  using (true);

create table user_completed_tasks (
  user_id uuid not null references users(id) on delete cascade,
  season_id uuid not null references seasons(id) on delete cascade,
  task_id uuid not null references system_tasks(id) on delete cascade,
  completed_at timestamptz not null default now(),
  primary key (user_id, season_id, task_id)
);

alter table user_completed_tasks enable row level security;

alter table user_seasons add column xp integer not null default 0;

-- ---------------------------------------------------------------------------
-- Seed: Категория A (social) ship deliberately INACTIVE with no
-- target_value — "Первый шум в сети"/"Свои в чате" need a real channel/chat
-- username and "Разведка на районе" a real post link, none of which exist
-- in this codebase to seed correctly. Flip is_active to true and set
-- target_value once those are known (see the accompanying summary for the
-- exact UPDATE statements). Категории B and C need nothing external and
-- ship active immediately.
-- ---------------------------------------------------------------------------
insert into system_tasks (slug, title, description, category, target_type, target_value, required_count, reward_xp, is_active, sort_order) values
  ('social_main_channel', 'Первый шум в сети', 'Подпишись на главный канал проекта', 'social', 'channel_sub', null, 1, 100, false, 1),
  ('social_community_chat', 'Свои в чате', 'Вступи в официальный чат комьюнити', 'social', 'chat_join', null, 1, 150, false, 2),
  ('social_intel_post', 'Разведка на районе', 'Открой и просмотри инфо-пост', 'social', 'post_view', null, 1, 150, false, 3),
  ('referral_first_contacts', 'Первые связные', 'Пригласи 5 друзей 1-го уровня', 'referral', 'referrals_level_1', null, 5, 500, true, 4),
  ('referral_small_crew', 'Малая группировка', 'Пригласи 10 друзей 1-го уровня', 'referral', 'referrals_level_1', null, 10, 1200, true, 5),
  ('referral_own_network', 'Своя сеть', 'Пригласи 25 друзей 1-го уровня', 'referral', 'referrals_level_1', null, 25, 3500, true, 6),
  ('gameplay_night_shift', 'Ночная смена', 'Запусти и успешно заверши 5 любых циклов', 'gameplay', 'cycles_completed', null, 5, 300, true, 7),
  ('gameplay_big_business', 'Крупный бизнес', 'Прокачай своё предприятие до 3-го уровня', 'gameplay', 'tier_reached', '3', 1, 800, true, 8);

insert into system_task_rewards (task_id, item_type, quantity)
select id, 'time_skip_1pct', 1 from system_tasks where slug = 'social_main_channel'
union all
select id, 'time_skip_3pct', 1 from system_tasks where slug = 'social_community_chat'
union all
select id, 'time_skip_3pct', 1 from system_tasks where slug = 'social_intel_post'
union all
select id, 'time_skip_5pct', 1 from system_tasks where slug = 'referral_first_contacts'
union all
select id, 'auto_collect_1d', 1 from system_tasks where slug = 'referral_first_contacts'
union all
select id, 'time_skip_10pct', 1 from system_tasks where slug = 'referral_small_crew'
union all
select id, 'auto_collect_1d', 1 from system_tasks where slug = 'referral_small_crew'
union all
select id, 'auto_collect_3d', 1 from system_tasks where slug = 'referral_own_network'
union all
select id, 'time_skip_10pct', 2 from system_tasks where slug = 'referral_own_network'
union all
select id, 'time_skip_5pct', 1 from system_tasks where slug = 'gameplay_night_shift'
union all
select id, 'auto_collect_1d', 1 from system_tasks where slug = 'gameplay_big_business';

-- ---------------------------------------------------------------------------
-- claim_system_task — grants a task's item rewards + XP. Referral/gameplay
-- progress is re-checked here (cheap, all internal data); social tasks are
-- trusted to have been verified by the API route already (see header).
-- ---------------------------------------------------------------------------
create or replace function claim_system_task(p_user_id uuid, p_slug text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_task system_tasks%rowtype;
  v_progress integer;
  v_reward record;
  v_shelf_life_hours numeric;
  i integer;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select * into v_task from system_tasks where slug = p_slug and is_active;
  if not found then
    raise exception 'unknown_task';
  end if;

  if exists (
    select 1 from user_completed_tasks
    where user_id = p_user_id and season_id = v_season_id and task_id = v_task.id
  ) then
    raise exception 'already_claimed';
  end if;

  if v_task.category = 'referral' then
    select count(*) into v_progress from users where referred_by = p_user_id;
    if v_progress < v_task.required_count then
      raise exception 'task_not_claimable';
    end if;
  elsif v_task.category = 'gameplay' then
    if v_task.target_type = 'cycles_completed' then
      select coalesce(completed_cycles_total, 0) into v_progress
      from user_seasons where user_id = p_user_id and season_id = v_season_id;
      if coalesce(v_progress, 0) < v_task.required_count then
        raise exception 'task_not_claimable';
      end if;
    elsif v_task.target_type = 'tier_reached' then
      if not exists (
        select 1 from user_tier_progress
        where user_id = p_user_id and season_id = v_season_id
          and tier = v_task.target_value::smallint
      ) then
        raise exception 'task_not_claimable';
      end if;
    end if;
  end if;
  -- social tasks: no progress check here — the route already verified
  -- Telegram membership (channel_sub/chat_join) or the task is a
  -- self-report by design (post_view — nothing Telegram exposes to verify
  -- "viewed a post" with).

  insert into user_completed_tasks (user_id, season_id, task_id)
  values (p_user_id, v_season_id, v_task.id);

  for v_reward in select item_type, quantity from system_task_rewards where task_id = v_task.id loop
    select shelf_life_hours into v_shelf_life_hours
    from combo_item_templates where item_type = v_reward.item_type;

    for i in 1..v_reward.quantity loop
      insert into user_inventory (user_id, season_id, item_type, expires_at)
      values (p_user_id, v_season_id, v_reward.item_type, now() + (v_shelf_life_hours::text || ' hours')::interval);
    end loop;
  end loop;

  update user_seasons set xp = xp + v_task.reward_xp
  where user_id = p_user_id and season_id = v_season_id;

  return jsonb_build_object(
    'task_slug', p_slug,
    'reward_xp', v_task.reward_xp,
    'rewards', (
      select coalesce(jsonb_agg(jsonb_build_object('item_type', item_type, 'quantity', quantity)), '[]'::jsonb)
      from system_task_rewards where task_id = v_task.id
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- get_player_state — adds wallet.xp and the system_tasks array (each with
-- live-computed progress + its reward list, for the progress bars and item
-- icons the UI needs). Identical to the 0027_combo_item_drops.sql version
-- otherwise.
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
  perform process_auto_collect_cycles();

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
        'completed', exists (
          select 1 from user_completed_tasks uct
          where uct.user_id = p_user_id and uct.season_id = v_season_id and uct.task_id = st.id
        )
      ) order by st.sort_order), '[]'::jsonb)
      from system_tasks st
      where st.is_active
    ),
    'squad', jsonb_build_object(
      'invite_code', (select telegram_id::text from users where id = p_user_id),
      'referred_count', (select count(*) from users where referred_by = p_user_id),
      'earned_total', (select coalesce(sum(amount), 0) from referral_earnings where beneficiary_id = p_user_id),
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
    )
  ) into v_result;

  return v_result;
end;
$$;
