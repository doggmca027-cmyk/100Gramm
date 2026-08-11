-- Opens Battle Boost purchases (activate_district_boost) and direct
-- Influence purchases (buy_direct_influence) to every gang member, not
-- just leader/co_leader — plain members may only ever pay from their own
-- personal balance, never the gang bank (that stays officer-only, same
-- "protect the treasury" posture the bank already has everywhere else in
-- this schema). Also adds a lightweight gang activity feed so a member's
-- purchase visibly nudges the rest of the roster to chip in too.
--
-- Deviations from the literal spec, same reasoning as every earlier
-- District Wars migration:
--   * "auth.uid() состоит в gang_members" — there's still no Supabase Auth
--     session in this schema (see 0058_gangs.sql's header); membership is
--     re-derived from the explicit p_user_id every privileged RPC here
--     already takes, same as always. Nothing new here, just re-stating it
--     since this migration's spec text mentions auth.uid() directly.
--   * The gang activity feed is a new, minimal table (gang_activity_log),
--     not a full chat — one system-generated line per boost/influence
--     purchase, latest 10 surfaced on get_player_state.gang.activity_feed
--     (same "last 10, newest first" shape bank_transactions already
--     uses). Message text is generated server-side in Russian only, not
--     per-locale i18n — same posture the TON payout memo ("Накатил ...")
--     already takes for this kind of flavor/system text, since building
--     full 5-language i18n for freeform generated strings is a much
--     bigger, separate piece of work than what was asked for here.
create table gang_activity_log (
  id uuid primary key default gen_random_uuid(),
  gang_id uuid not null references gangs(id) on delete cascade,
  user_id uuid references users(id) on delete set null,
  message text not null,
  created_at timestamptz not null default now()
);

create index gang_activity_log_gang_idx on gang_activity_log (gang_id, created_at desc);
alter table gang_activity_log enable row level security;

-- ---------------------------------------------------------------------------
-- activate_district_boost — one change from 0066_district_wars_
-- monetization.sql: any gang member may activate a boost (was leader/
-- co_leader-only); p_pay_from_bank additionally requires leader/co_leader
-- regardless of who's buying. Logs a gang_activity_log entry on success.
-- Everything else (cost table, "only the defender may buy engineer_shield",
-- one-active-boost-per-family, the battle-window gate, both advisory
-- locks) is byte-for-byte unchanged.
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
  v_display_name text;
  v_boost_label text;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if p_pay_from_bank and v_role not in ('leader', 'co_leader') then
    raise exception 'bank_payment_officers_only';
  end if;

  -- A second lock keyed on (district, gang) rather than the caller: any two
  -- members of the same gang are two different p_user_id values, so the
  -- lock above alone doesn't stop them both passing the "not already
  -- active" check below in the same instant and both getting charged for
  -- what only ends up looking like one active boost (district_battle_
  -- boosts has no unique constraint to catch this at the database level
  -- either — it's an append-only history table by design). This closes
  -- that window regardless of which two members are racing.
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
      v_boost_label := 'Авиаудар 2X';
    when 'airstrike_3x' then
      v_family := 'airstrike'; v_cost := 5; v_multiplier := 3.0; v_duration := interval '2 hours';
      v_boost_label := 'Авиаудар 3X';
    when 'engineer_shield' then
      v_family := 'shield'; v_cost := 3; v_multiplier := null; v_duration := interval '20 minutes';
      v_boost_label := 'Щит Района';
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

  select coalesce(username, first_name, 'Боец') into v_display_name from users where id = p_user_id;
  insert into gang_activity_log (gang_id, user_id, message)
  values (v_gang_id, p_user_id, '⚔️ ' || v_display_name || ' активировал(а) ' || v_boost_label || ' для Синдиката!');

  return jsonb_build_object(
    'gang_id', v_gang_id, 'district_id', p_district_id, 'boost_type', p_boost_type, 'expires_at', v_expires_at
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- buy_direct_influence — one change from 0067_syndicate_weekly_
-- leaderboard.sql: any gang member may buy influence (was leader/
-- co_leader-only); p_pay_from_bank additionally requires leader/co_leader
-- regardless of who's buying. Logs a gang_activity_log entry on success.
-- Everything else (200 pts/TON, 1 TON minimum, the target-district
-- routing) is byte-for-byte unchanged.
-- ---------------------------------------------------------------------------
create or replace function buy_direct_influence(p_user_id uuid, p_ton_amount numeric, p_pay_from_bank boolean)
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
  v_points bigint;
  v_gang gangs%rowtype;
  v_district districts%rowtype;
  v_battle_date date;
  v_display_name text;
begin
  if p_ton_amount is null or p_ton_amount < 1 then
    raise exception 'amount_too_low';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if p_pay_from_bank and v_role not in ('leader', 'co_leader') then
    raise exception 'bank_payment_officers_only';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  if p_pay_from_bank then
    perform resolve_due_gang_bank_interest(v_gang_id);
    select bank_balance_gram into v_balance from gangs where id = v_gang_id for update;
    if v_balance < p_ton_amount then
      raise exception 'insufficient_gang_bank';
    end if;
    update gangs set bank_balance_gram = bank_balance_gram - p_ton_amount, bank_balance_ton = bank_balance_ton - p_ton_amount
    where id = v_gang_id;
  else
    select balance into v_balance from user_seasons
    where user_id = p_user_id and season_id = v_season_id for update;
    if v_balance is null then
      raise exception 'no_active_season';
    end if;
    if v_balance < p_ton_amount then
      raise exception 'insufficient_balance';
    end if;
    update user_seasons set balance = balance - p_ton_amount
    where user_id = p_user_id and season_id = v_season_id;
  end if;

  v_points := round(p_ton_amount * 200);

  update gangs set weekly_influence_points = weekly_influence_points + v_points
  where id = v_gang_id
  returning * into v_gang;

  if v_gang.target_district_id is not null then
    select * into v_district from districts where id = v_gang.target_district_id;
    if district_battle_status(v_district.window_start_time, v_district.window_end_time) = 'active' then
      v_battle_date := district_battle_date(v_district.window_end_time);
      if v_district.controlling_gang_id = v_gang_id
         or exists (
           select 1 from district_challenges
           where district_id = v_district.id and battle_date = v_battle_date and gang_id = v_gang_id
         ) then
        perform district_apply_points(v_district.id, v_gang_id, v_battle_date, v_points);
      end if;
    end if;
  end if;

  select coalesce(username, first_name, 'Боец') into v_display_name from users where id = p_user_id;
  insert into gang_activity_log (gang_id, user_id, message)
  values (v_gang_id, p_user_id, '💎 ' || v_display_name || ' закупил(а) ' || v_points || ' очков влияния для Синдиката!');

  return jsonb_build_object(
    'gang_id', v_gang_id, 'points_added', v_points, 'weekly_influence_points', v_gang.weekly_influence_points
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- get_player_state — one addition to the 'gang' object: activity_feed
-- (latest 10 gang_activity_log rows, newest first — same shape
-- bank_transactions already uses). Everything else byte-for-byte
-- unchanged from 0070_syndicate_weekly_leaderboard.sql.
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
  perform finalize_weekly_leaderboard_season();
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
        'weekly_influence_points', g.weekly_influence_points,
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
