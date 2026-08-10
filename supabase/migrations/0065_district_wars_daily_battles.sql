-- District Wars rework: from "continuous points, current leader controls"
-- (0063_district_wars.sql) to daily 12h battle windows with an explicit
-- attacker-vs-defender fight.
--
-- Deviations from the literal spec, same reasoning this whole feature's
-- earlier migrations already document:
--   * No stored `districts.battle_status` column. A column needs
--     something to keep it in sync with wall-clock time — either a cron
--     tick or an on-read check, and if it's the latter anyway there's no
--     reason to also persist it. battle_status is computed live from
--     window_start_time/window_end_time via district_battle_status()
--     below, same "derive it, don't store a copy that can go stale" call
--     already made for e.g. `expires_at` fields elsewhere in this schema.
--   * No `processing` status. Finalizing a battle (resolve_due_district_
--     battles below) runs as a single atomic transaction — there's no
--     observable window where a district sits "in progress", so a third
--     status would never actually be seen by anyone.
--   * "Автоматически вызывается в момент закрытия окна" is implemented
--     as the same lazy-catch-up pattern every time-based transition in
--     this schema already uses (resolve_due_cycles, expire_due_boosts,
--     resolve_due_bank_payouts, ensure_daily_combo) — called
--     unconditionally from get_player_state, so the first person to load
--     the app after a window closes triggers the finalize, rather than
--     correctness depending on a cron actually firing on time. A cron
--     endpoint is added too (matching this schema's existing
--     /api/cron/* "backstop for opportunistic work" pattern — see
--     refresh-rate's header) purely so battles resolve promptly at
--     window-close instead of waiting for the next active player; it
--     calls the exact same function.
--
-- Design notes not spelled out in the spec, decided here:
--   * "battle_date" (which day's fight a row belongs to) is computed as:
--     if it's currently before today's window_end, battle_date = today;
--     otherwise (today's window has already closed) battle_date =
--     tomorrow. Applying during peace time before the window opens
--     registers for *today's* upcoming window; applying during peace
--     time after it closes registers for *tomorrow's*.
--   * Multiple gangs may apply to attack the same district on the same
--     day (the spec doesn't say only one challenger is allowed). At
--     finalize time, the single challenger with the highest points among
--     all of that day's applicants is the one compared against the
--     defender — everyone else's application simply didn't score enough
--     to matter, no separate rejection needed.
--   * A gang can only ever be attacking-or-defending ONE district at a
--     time (gangs.target_district_id, unchanged) — the same field
--     decides both roles: pointed at a district your gang controls ->
--     defending it; pointed at one you don't -> attacking it (provided
--     you've applied for today, see request_district_attack). A
--     defending gang whose leader retargets elsewhere stops accruing
--     defense for their own district — a deliberate tension, not a bug.
--   * district_influence (0063) is dropped outright — its "points only
--     ever go up, forever, across the whole season" model has no
--     equivalent in a daily-reset battle system, and nothing else reads
--     it.

drop table if exists district_influence;

alter table districts
  add column window_start_time time not null default '10:00:00',
  add column window_end_time time not null default '22:00:00';

-- ---------------------------------------------------------------------------
-- district_battles — one row per (district, day) a fight actually
-- happened on (created lazily, see request_district_attack /
-- resolve_due_cycles below — never pre-created for every district on
-- every day up front).
-- ---------------------------------------------------------------------------
create table district_battles (
  id uuid primary key default gen_random_uuid(),
  district_id uuid not null references districts(id) on delete cascade,
  battle_date date not null,
  defender_gang_id uuid references gangs(id) on delete set null,
  defense_points bigint not null default 0,
  resolved boolean not null default false,
  created_at timestamptz not null default now(),
  unique (district_id, battle_date)
);

create index district_battles_unresolved_idx on district_battles (district_id) where not resolved;
alter table district_battles enable row level security;

-- ---------------------------------------------------------------------------
-- district_challenges — one row per (district, day, attacking gang).
-- ---------------------------------------------------------------------------
create table district_challenges (
  id uuid primary key default gen_random_uuid(),
  district_id uuid not null references districts(id) on delete cascade,
  battle_date date not null,
  gang_id uuid not null references gangs(id) on delete cascade,
  points bigint not null default 0,
  created_at timestamptz not null default now(),
  unique (district_id, battle_date, gang_id)
);

create index district_challenges_lookup_idx on district_challenges (district_id, battle_date);
alter table district_challenges enable row level security;

-- ---------------------------------------------------------------------------
-- Time-window helpers — stable (not immutable: they read now()), shared by
-- get_districts, resolve_due_cycles, and resolve_due_district_battles so
-- the "what day/status is it" logic only lives in one place.
--
-- Assumes window_start_time < window_end_time within the same calendar
-- day (matches the spec's own "10:00 to 22:00" example and every seeded
-- district) -- a window configured to wrap past midnight (e.g. 22:00 to
-- 02:00) would never register as "active", since no time-of-day is both
-- >= 22:00 and < 02:00 in a same-day comparison. Not reachable with any
-- district this schema currently seeds; flagged here rather than solved,
-- since supporting a wrapping window would meaningfully complicate every
-- date-boundary computation below for a configuration nothing uses.
-- ---------------------------------------------------------------------------
create or replace function district_battle_date(p_window_end time)
returns date
language sql
stable
as $$
  select case when (now() at time zone 'utc')::time < p_window_end
    then (now() at time zone 'utc')::date
    else (now() at time zone 'utc')::date + 1
  end;
$$;

create or replace function district_battle_status(p_window_start time, p_window_end time)
returns text
language sql
stable
as $$
  select case when (now() at time zone 'utc')::time >= p_window_start
            and (now() at time zone 'utc')::time < p_window_end
    then 'active' else 'peace' end;
$$;

create or replace function district_next_transition_at(p_window_start time, p_window_end time)
returns timestamptz
language sql
stable
as $$
  select case
    when (now() at time zone 'utc')::time >= p_window_start and (now() at time zone 'utc')::time < p_window_end
      then ((now() at time zone 'utc')::date::timestamp + p_window_end) at time zone 'utc'
    when (now() at time zone 'utc')::time < p_window_start
      then ((now() at time zone 'utc')::date::timestamp + p_window_start) at time zone 'utc'
    else (((now() at time zone 'utc')::date + 1)::timestamp + p_window_start) at time zone 'utc'
  end;
$$;

-- ---------------------------------------------------------------------------
-- request_district_attack — replaces set_gang_district_target (0063).
-- Leader-or-co_leader-only, same as before. Rejects attacking a district
-- your own gang already controls (nothing to challenge — you're already
-- the automatic defender). Registers today-or-tomorrow's challenge and
-- makes sure a district_battles row exists for that battle_date (so
-- resolve_due_district_battles always has something to finalize even if
-- the defender never scores a single point) before pointing the gang's
-- target at this district.
-- ---------------------------------------------------------------------------
drop function if exists set_gang_district_target(uuid, uuid);

create or replace function request_district_attack(p_user_id uuid, p_district_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gang_id uuid;
  v_role text;
  v_district districts%rowtype;
  v_battle_date date;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_role not in ('leader', 'co_leader') then
    raise exception 'not_gang_officer';
  end if;

  select * into v_district from districts where id = p_district_id;
  if not found then
    raise exception 'district_not_found';
  end if;
  if v_district.controlling_gang_id = v_gang_id then
    raise exception 'already_controls_district';
  end if;

  v_battle_date := district_battle_date(v_district.window_end_time);

  insert into district_battles (district_id, battle_date, defender_gang_id, defense_points)
  values (p_district_id, v_battle_date, v_district.controlling_gang_id, 0)
  on conflict (district_id, battle_date) do nothing;

  insert into district_challenges (district_id, battle_date, gang_id, points)
  values (p_district_id, v_battle_date, v_gang_id, 0)
  on conflict (district_id, battle_date, gang_id) do nothing;

  update gangs set target_district_id = p_district_id where id = v_gang_id;

  return jsonb_build_object('gang_id', v_gang_id, 'target_district_id', p_district_id, 'battle_date', v_battle_date);
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_due_district_battles — global lazy catch-up (see header), no
-- p_user_id: finalizes every district_battles row whose battle_date's
-- window has fully closed and hasn't been resolved yet. `for update skip
-- locked` so an overlapping call (two requests landing at once right
-- after window-close) can't double-transfer the same district.
--
-- Ordered oldest-battle_date-first: each finalize unconditionally SETS
-- controlling_gang_id (it doesn't check "is this still current"), so if a
-- gap in traffic ever let more than one stale day pile up for the same
-- district (nobody opened the app for 2+ days), processing them out of
-- order could let an older day's result clobber a more recent one on the
-- way out. Oldest-first guarantees the most recent day's outcome is
-- always what's left standing.
-- ---------------------------------------------------------------------------
create or replace function resolve_due_district_battles()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_battle record;
  v_top_gang_id uuid;
  v_top_points bigint;
begin
  for v_battle in
    select db.id, db.district_id, db.battle_date, db.defense_points
    from district_battles db
    join districts d on d.id = db.district_id
    where not db.resolved
      and db.battle_date < district_battle_date(d.window_end_time)
    order by db.battle_date asc
    for update of db skip locked
  loop
    select gang_id, points into v_top_gang_id, v_top_points
    from district_challenges
    where district_id = v_battle.district_id and battle_date = v_battle.battle_date
    order by points desc
    limit 1;

    if v_top_points is not null and v_top_points > v_battle.defense_points then
      update districts set controlling_gang_id = v_top_gang_id where id = v_battle.district_id;
    end if;
    -- Ties and a defender lead both keep the current controller (spec:
    -- defender wins on >=) -- no update needed, controlling_gang_id is
    -- already whoever it was.

    update district_battles set resolved = true where id = v_battle.id;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_districts — full rework for the daily-battle UI: live battle_status
-- + next_transition_at for the countdown, the defender's current-day
-- points, the single best challenger (if any), and the caller's own
-- gang's role/points in today's fight for each district.
-- ---------------------------------------------------------------------------
create or replace function get_districts(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_my_gang_id uuid;
  v_result jsonb;
begin
  select gang_id into v_my_gang_id from gang_members where user_id = p_user_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id,
    'name', d.name,
    'slug', d.slug,
    'bonus_type', d.bonus_type,
    'bonus_value', d.bonus_value,
    'controlling_gang', case when cg.id is not null then jsonb_build_object(
      'id', cg.id, 'name', cg.name, 'avatar_id', cg.avatar_id
    ) else null end,
    'battle_status', bstate.battle_status,
    'next_transition_at', bstate.next_transition_at,
    'defender', case when cg.id is not null then jsonb_build_object(
      'gang_id', cg.id, 'name', cg.name, 'avatar_id', cg.avatar_id,
      'points', coalesce(db.defense_points, 0)
    ) else null end,
    'top_challenger', (
      select jsonb_build_object('gang_id', chg.id, 'name', chg.name, 'avatar_id', chg.avatar_id, 'points', ch.points)
      from district_challenges ch
      join gangs chg on chg.id = ch.gang_id
      where ch.district_id = d.id and ch.battle_date = bstate.battle_date
      order by ch.points desc
      limit 1
    ),
    'my_gang_role', case
      when v_my_gang_id is null then null
      when v_my_gang_id = d.controlling_gang_id then 'defender'
      when exists (
        select 1 from district_challenges
        where district_id = d.id and battle_date = bstate.battle_date and gang_id = v_my_gang_id
      ) then 'attacker'
      else null
    end,
    'my_gang_points', case
      when v_my_gang_id is null then null
      when v_my_gang_id = d.controlling_gang_id then coalesce(db.defense_points, 0)
      else (
        select points from district_challenges
        where district_id = d.id and battle_date = bstate.battle_date and gang_id = v_my_gang_id
      )
    end
  ) order by d.name), '[]'::jsonb)
  into v_result
  from districts d
  left join gangs cg on cg.id = d.controlling_gang_id
  left join lateral (
    select
      district_battle_status(d.window_start_time, d.window_end_time) as battle_status,
      district_battle_date(d.window_end_time) as battle_date,
      district_next_transition_at(d.window_start_time, d.window_end_time) as next_transition_at
  ) bstate on true
  left join district_battles db on db.district_id = d.id and db.battle_date = bstate.battle_date;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_due_cycles — replaces 0063's "always-on points, current leader
-- controls" district section with the daily-battle version: only scores
-- while the target district's window is active, and routes points to
-- defense (this gang currently controls the district) or to that gang's
-- own challenge for today (only if they already applied — see
-- request_district_attack). Everything else byte-for-byte unchanged from
-- 0063_district_wars.sql / 0064_gang_audit_fixes.sql.
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
  v_updated_rows integer;
  v_gang_id uuid;
  v_target_district_id uuid;
  v_district_window_start time;
  v_district_window_end time;
  v_district_controller uuid;
  v_battle_date date;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    return;
  end if;

  select coalesce((config->'features'->>'containers')::boolean, false)
  into v_containers_enabled
  from seasons where id = v_season_id;

  -- Looked up once, not per claimed cycle — membership can't change mid-call,
  -- and this keeps the common case (not in a gang) from running an extra
  -- subquery+update per cycle claimed this pass.
  select gm.gang_id, g.target_district_id into v_gang_id, v_target_district_id
  from gang_members gm
  join gangs g on g.id = gm.gang_id
  where gm.user_id = p_user_id;

  if v_target_district_id is not null then
    select window_start_time, window_end_time, controlling_gang_id
    into v_district_window_start, v_district_window_end, v_district_controller
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

    v_amount_out := round(v_cycle.amount_in * (1 + v_payout_percent / 100), 2);

    update cycles
    set status = 'claimed', claimed_at = now(), amount_out = v_amount_out
    where id = v_cycle.id and status = 'running';

    get diagnostics v_updated_rows = row_count;
    if v_updated_rows = 0 then
      -- Already claimed by someone else between the lock and here — SKIP
      -- LOCKED above should make this unreachable, but never credit twice
      -- regardless of how that happens.
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

    -- Gang XP: +1 EXP per successfully claimed expedition, to whichever
    -- gang the claimant belongs to, if any. Level is recomputed inline from
    -- the new experience total — see 0058_gangs.sql's header for the formula.
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

      -- District Wars: only scores during the target district's active
      -- 12h window (see this migration's header) — peace-time claims
      -- still earn gang XP/bank above, just no battle points.
      if v_target_district_id is not null
         and district_battle_status(v_district_window_start, v_district_window_end) = 'active' then
        v_battle_date := district_battle_date(v_district_window_end);

        if v_district_controller = v_gang_id then
          insert into district_battles (district_id, battle_date, defender_gang_id, defense_points)
          values (v_target_district_id, v_battle_date, v_gang_id, 10)
          on conflict (district_id, battle_date) do update
            set defense_points = district_battles.defense_points + 10;
        else
          -- Only counts if this gang already applied for today's battle
          -- (request_district_attack) -- a bare target_district_id with
          -- no application on file scores nothing, matching the spec's
          -- distinct "подать заявку" step.
          update district_challenges set points = points + 10
          where district_id = v_target_district_id and battle_date = v_battle_date and gang_id = v_gang_id;
        end if;
      end if;
    end if;

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
  end loop;

  -- tier unlock: needs BOTH enough completed cycles AND minimum elapsed
  -- time, so stacking slots can't rush progression (only wall-clock time
  -- can). Checked unconditionally on every call (not just when a cycle was
  -- just claimed above) so the time-floor side of the condition gets
  -- re-evaluated even on calls where no cycle happens to be due; looped so
  -- a player who qualifies for more than one tier at once (e.g. after being
  -- stuck by the bug this replaces) catches all the way up in one pass.
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
-- get_player_state — one addition: perform resolve_due_district_battles()
-- alongside ensure_daily_combo, the other global (not per-user) daily
-- lazy catch-up. Everything else byte-for-byte unchanged from
-- 0064_gang_audit_fixes.sql (which didn't touch this function itself —
-- last real change was 0063's target_district_id/name fields, still here).
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
begin
  perform resolve_due_cycles(p_user_id);
  perform expire_due_boosts(p_user_id);
  perform resolve_due_bank_payouts(p_user_id);

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  perform ensure_daily_combo(v_season_id);
  perform resolve_due_district_battles();
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
        'level', g.level,
        'experience', g.experience,
        'exp_into_level', g.experience % 100,
        'exp_per_level', 100,
        'max_members', g.max_members,
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
