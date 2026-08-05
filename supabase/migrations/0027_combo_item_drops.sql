-- 100ГРАМ: Daily Combo's fixed +5 GRAM reward is replaced with a random
-- item drop into a new per-player inventory (Улучшения tab). Two families:
-- time-skip percentages (shave a % off an active cycle's remaining time)
-- and auto-collect passes (claim + auto-relaunch cycles while the player is
-- away). Drop odds and shelf life are data (combo_item_templates), not
-- hardcoded in the RPC, matching every other tunable number in this game
-- (product_templates, ranks, quest_templates, ...).
--
-- Deviations from a literal telegram_id/quantity-column spec, kept
-- consistent with the rest of this schema:
--   * user_id/season_id (not telegram_id) — every other table keys off the
--     internal user id; telegram_id is a users.telegram_id lookup away.
--   * One row per unit (not a `quantity` counter + one `expires_at`) — the
--     same pattern user_boosts already uses. A single scalar can't actually
--     represent "each of N units expires at its own time"; per-unit rows
--     make "quantity" and "nearest expiry" simple aggregates
--     (count(*) / min(expires_at)) instead of a value nothing keeps in sync.
--   * The reward is rolled inside submit_daily_combo_guess itself (the
--     existing win/loss RPC), not a separate claim_daily_combo_reward call —
--     that function is already the one atomic, server-authoritative place
--     a win is decided; splitting reward-granting into a second round trip
--     would just add a step without adding safety.

-- ---------------------------------------------------------------------------
-- combo_item_templates — the catalog. drop_weight sums to 100 (a 1-100 roll
-- picks by cumulative weight, see submit_daily_combo_guess below).
-- ---------------------------------------------------------------------------
create table combo_item_templates (
  item_type text primary key,
  category text not null check (category in ('time_skip', 'auto_collect')),
  drop_weight numeric(5, 2) not null check (drop_weight > 0),
  shelf_life_hours numeric(8, 2) not null check (shelf_life_hours > 0),
  -- time_skip: % shaved off the tier's full cycle_hours. auto_collect: hours
  -- added to user_seasons.auto_collect_until. Exactly one is set, per category.
  effect_percent numeric(5, 2),
  effect_hours numeric(8, 2),
  sort_order smallint not null default 0
);

alter table combo_item_templates enable row level security;

create policy "combo_item_templates are publicly readable"
  on combo_item_templates for select
  using (true);

insert into combo_item_templates (item_type, category, drop_weight, shelf_life_hours, effect_percent, sort_order) values
  ('time_skip_1pct',  'time_skip', 40, 48, 1,  1),
  ('time_skip_3pct',  'time_skip', 30, 48, 3,  2),
  ('time_skip_5pct',  'time_skip', 15, 72, 5,  3),
  ('time_skip_10pct', 'time_skip', 4,  72, 10, 4);

insert into combo_item_templates (item_type, category, drop_weight, shelf_life_hours, effect_hours, sort_order) values
  ('auto_collect_1d', 'auto_collect', 10, 24 * 7,  24, 5),
  ('auto_collect_3d', 'auto_collect', 1,  24 * 14, 72, 6);

-- ---------------------------------------------------------------------------
-- user_inventory — one row per granted unit (see header note on why not a
-- quantity column). status stays 'active' until explicitly consumed by
-- apply_time_skip_item/apply_auto_collect_item ('used'); items that simply
-- age past expires_at are never flipped to an 'expired' status — every
-- query that counts "what can I still use" already filters
-- `status = 'active' and expires_at > now()`, so there's nothing to sweep.
-- ---------------------------------------------------------------------------
create table user_inventory (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  season_id uuid not null references seasons(id) on delete cascade,
  item_type text not null references combo_item_templates(item_type),
  status text not null default 'active' check (status in ('active', 'used')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);

create index user_inventory_user_idx on user_inventory (user_id, season_id, item_type, status);

alter table user_inventory enable row level security;

-- ---------------------------------------------------------------------------
-- auto_collect_until — season-scoped like every other wallet/progress
-- number (resets with the season, same as balance/slots/cycles).
-- ---------------------------------------------------------------------------
alter table user_seasons add column auto_collect_until timestamptz;

-- ---------------------------------------------------------------------------
-- user_combo_progress — remembers *which* item a win actually granted, so
-- reloading the page after winning still shows the right prize instead of
-- just "you won something".
-- ---------------------------------------------------------------------------
alter table user_combo_progress
  add column reward_item_type text references combo_item_templates(item_type);

-- The fixed reward is gone — daily_combo.reward_amount no longer means
-- anything (nothing computes a payout from it any more).
alter table daily_combo drop column reward_amount;

-- ---------------------------------------------------------------------------
-- submit_daily_combo_guess — win/loss logic unchanged; the payout branch is
-- replaced with a weighted random item drop into user_inventory.
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
  v_roll numeric;
  v_item_type text;
  v_shelf_life_hours numeric;
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
    -- weighted pick: roll 1-100, walk the catalog in sort_order and take
    -- the first item whose cumulative weight reaches the roll.
    v_roll := 1 + floor(random() * 100);
    select item_type into v_item_type
    from (
      select item_type, sort_order,
        sum(drop_weight) over (order by sort_order) as cum_weight
      from combo_item_templates
    ) weighted
    where cum_weight >= v_roll
    order by sort_order
    limit 1;

    select shelf_life_hours into v_shelf_life_hours
    from combo_item_templates where item_type = v_item_type;

    insert into user_inventory (user_id, season_id, item_type, expires_at)
    values (p_user_id, v_season_id, v_item_type, now() + (v_shelf_life_hours::text || ' hours')::interval);
  end if;

  update user_combo_progress
  set attempts_used = attempts_used + 1,
      last_guess_tiers = p_tiers,
      last_guess_correct = v_correct,
      is_completed = coalesce(v_is_win, false),
      completed_at = case when v_is_win then now() else completed_at end,
      reward_item_type = case when v_is_win then v_item_type else reward_item_type end
  where user_id = p_user_id and season_id = v_season_id and combo_date = v_combo.combo_date;

  return jsonb_build_object(
    'is_win', coalesce(v_is_win, false),
    'correct', v_correct,
    'attempts_used', v_progress.attempts_used + 1,
    'attempts_max', v_combo.max_attempts,
    'reward_item_type', v_item_type
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- apply_time_skip_item — consumes the soonest-expiring active unit of
-- p_item_type, shaving effect_percent% of the tier's *full* cycle_hours
-- (the tier's canonical duration, not whatever time happens to be left —
-- otherwise stacking skips would erode against a shrinking base) off
-- p_cycle_id's ends_at. Clamped so a skip can never push ends_at into the
-- past — it just makes the cycle immediately claimable.
-- ---------------------------------------------------------------------------
create or replace function apply_time_skip_item(p_user_id uuid, p_item_type text, p_cycle_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_item_id uuid;
  v_effect_percent numeric;
  v_cycle cycles%rowtype;
  v_full_cycle_hours numeric;
  v_skip_interval interval;
  v_new_ends_at timestamptz;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select effect_percent into v_effect_percent
  from combo_item_templates
  where item_type = p_item_type and category = 'time_skip';
  if v_effect_percent is null then
    raise exception 'unknown_item';
  end if;

  select id into v_item_id
  from user_inventory
  where user_id = p_user_id and season_id = v_season_id and item_type = p_item_type
    and status = 'active' and expires_at > now()
  order by expires_at asc
  limit 1
  for update;

  if v_item_id is null then
    raise exception 'item_not_available';
  end if;

  select * into v_cycle
  from cycles
  where id = p_cycle_id and user_id = p_user_id and season_id = v_season_id and status = 'running'
  for update;

  if not found then
    raise exception 'cycle_not_found';
  end if;

  select cycle_hours into v_full_cycle_hours
  from product_templates
  where season_id = v_season_id and tier = v_cycle.tier;

  v_skip_interval := ((v_full_cycle_hours * v_effect_percent / 100)::text || ' hours')::interval;
  v_new_ends_at := greatest(now(), v_cycle.ends_at - v_skip_interval);

  update cycles set ends_at = v_new_ends_at where id = p_cycle_id;
  update user_inventory set status = 'used', used_at = now() where id = v_item_id;

  return jsonb_build_object('cycle_id', p_cycle_id, 'new_ends_at', v_new_ends_at);
end;
$$;

-- ---------------------------------------------------------------------------
-- apply_auto_collect_item — consumes one unit, extends auto_collect_until.
-- Extends from whichever is later: "now" (if inactive/expired) or the
-- current auto_collect_until (stacks on top if still running).
-- ---------------------------------------------------------------------------
create or replace function apply_auto_collect_item(p_user_id uuid, p_item_type text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_item_id uuid;
  v_effect_hours numeric;
  v_new_until timestamptz;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select effect_hours into v_effect_hours
  from combo_item_templates
  where item_type = p_item_type and category = 'auto_collect';
  if v_effect_hours is null then
    raise exception 'unknown_item';
  end if;

  select id into v_item_id
  from user_inventory
  where user_id = p_user_id and season_id = v_season_id and item_type = p_item_type
    and status = 'active' and expires_at > now()
  order by expires_at asc
  limit 1
  for update;

  if v_item_id is null then
    raise exception 'item_not_available';
  end if;

  update user_inventory set status = 'used', used_at = now() where id = v_item_id;

  update user_seasons
  set auto_collect_until = greatest(coalesce(auto_collect_until, now()), now())
    + (v_effect_hours::text || ' hours')::interval
  where user_id = p_user_id and season_id = v_season_id
  returning auto_collect_until into v_new_until;

  if not found then
    raise exception 'no_active_season';
  end if;

  return jsonb_build_object('auto_collect_until', v_new_until);
end;
$$;

-- ---------------------------------------------------------------------------
-- process_auto_collect_cycles — global sweep, no user argument. Claims due
-- cycles (via the existing per-user resolve_due_cycles) for every player
-- whose auto_collect_until is still in the future, then relaunches the same
-- tier(s) once (start_cycle already batches "as many slots as balance/free
-- slots allow" in one call, same as a manual launch). A relaunch failing
-- (insufficient_balance, no_free_slots, ...) is expected and silently
-- skipped — the claim already happened either way.
--
-- Called from two places: get_player_state (so any active user's request
-- opportunistically sweeps *everyone* due — this is what actually keeps
-- auto-collect timely, since Vercel's free-tier cron granularity is far
-- coarser than cycle durations) and /api/cron/auto-collect (a once-daily
-- backstop for when nobody's using the app at all).
-- ---------------------------------------------------------------------------
create or replace function process_auto_collect_cycles()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_user_id uuid;
  v_tiers smallint[];
  v_t smallint;
  v_users_processed integer := 0;
  v_cycles_restarted integer := 0;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    return jsonb_build_object('users_processed', 0, 'cycles_restarted', 0);
  end if;

  for v_user_id in
    select distinct c.user_id
    from cycles c
    join user_seasons us on us.user_id = c.user_id and us.season_id = c.season_id
    where c.season_id = v_season_id
      and c.status = 'running'
      and c.ends_at <= now()
      and us.auto_collect_until is not null
      and us.auto_collect_until > now()
  loop
    select array_agg(distinct tier) into v_tiers
    from cycles
    where user_id = v_user_id and season_id = v_season_id
      and status = 'running' and ends_at <= now();

    perform resolve_due_cycles(v_user_id);
    v_users_processed := v_users_processed + 1;

    if v_tiers is not null then
      foreach v_t in array v_tiers loop
        begin
          perform start_cycle(v_user_id, v_t);
          v_cycles_restarted := v_cycles_restarted + 1;
        exception when others then
          -- insufficient_balance / no_free_slots / tier_locked / etc. — the
          -- claim already happened, a failed relaunch just means auto-collect
          -- quietly stops compounding for this tier until the player acts.
          null;
        end;
      end loop;
    end if;
  end loop;

  return jsonb_build_object('users_processed', v_users_processed, 'cycles_restarted', v_cycles_restarted);
end;
$$;

-- ---------------------------------------------------------------------------
-- get_player_state — adds wallet.auto_collect_until, the inventory array,
-- and reworks daily_combo (possible_drops catalog + reward_item instead of
-- the flat reward_amount). Identical to the 0026_squad_ambassador_flag.sql
-- version otherwise. Also opportunistically runs the global auto-collect
-- sweep — see process_auto_collect_cycles's comment for why.
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
