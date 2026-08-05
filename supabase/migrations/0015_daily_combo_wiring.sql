-- 100ГРАМ: wire Daily Combo into the real economy — start_cycle reveals a
-- slot server-side (never trusting client-claimed progress) and pays the
-- reward the moment all 4 are found; get_player_state ships today's combo
-- state (revealed slots only — unfound slots stay hidden, matching the
-- "guess it or get the answer shilled in the channel" mechanic).

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

  -- Daily Combo — server-side only reveal + reward. Buying a tier that is
  -- part of TODAY's secret combo fills its slot; a client can never fake
  -- this because it rides on the same trusted purchase path above.
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
-- get_player_state — adds `daily_combo`. Unfound slots stay hidden
-- (found: false, no tier field) so the client can't peek at the answer.
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
