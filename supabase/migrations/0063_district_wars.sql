-- 100ГРАМ: "Управление Синдикатом и Захват Районов" (District Wars MVP) —
-- gangs pick a district to contest, earn influence points from their
-- members' claimed expeditions, and whichever gang leads a district's
-- points controls it (and, in a later phase, grants its members that
-- district's bonus — this migration tracks and displays the bonus, see the
-- note above set_gang_district_target for why applying it to gameplay is
-- deliberately deferred). Also adds a leader-only gang-bank dividend payout.
--
-- Deviations from the literal spec, kept consistent with every other
-- table/RPC in this schema (same reasoning already documented in
-- 0056_bank_staking.sql and 0058_gangs.sql's headers):
--   * `district_influence.season_id` is `uuid references seasons(id)`, not
--     `integer default 1` — this app already has a real multi-season
--     system (seasons.id, active_season_id()), and "default 1" would
--     silently point every row at a season that doesn't exist here.
--   * Dividends land on `user_seasons.balance` (season-scoped), not a
--     `gram_balance` column — there is no such column anywhere in this
--     schema; the one balance a player has lives on user_seasons.balance,
--     same as every other money field (see create_gang's header in
--     0058_gangs.sql for the same note re: GRAM/TON).
--   * `distribute_bank_dividends` and `set_gang_district_target` take an
--     explicit `p_user_id`, not a client-supplied `p_gang_id`/implicit
--     leader claim — the caller's gang and role are always re-derived
--     server-side from gang_members, never trusted from the client, same
--     posture as create_gang/join_gang/kick_gang_member etc.
--   * No `icon` column on `districts` — the spec's own schema for that
--     table doesn't list one either; the map screen picks an icon
--     client-side from `slug`, the same "server stores an id, client maps
--     it to an icon" split gang-avatars.ts already uses for gang emblems.
--
-- RLS: enabled on both new tables (blocks direct anon/authenticated
-- access outright), but — same as gangs/gang_members/bank_deposits/every
-- other table here — there's no Supabase Auth session for these users
-- (see 0058_gangs.sql's header), so there's no auth.uid() for a real
-- policy to key off. The actual access control asked for ("обычные
-- участники не могут вызывать списание из Банка или назначение ролей")
-- is enforced the only way it can be in this schema: every privileged RPC
-- below re-derives the caller's gang membership and role from
-- gang_members before doing anything, and the client can only ever reach
-- these RPCs through server-only Next.js routes using the service-role
-- key — a regular member's session simply has no path to the underlying
-- tables at all, let alone a way to forge a leader/co_leader role.
--
-- Known MVP limitation, intentionally not solved here: `controlling_gang_id`
-- is a single column on the (season-less) districts row, recomputed from
-- the *current* active season's influence points every time a claim
-- lands. There's no season-rollover hook anywhere in this schema (seasons
-- are created manually), so a district's displayed controller can lag by
-- one season until the first claim of the new season re-triggers the
-- recompute. Acceptable for an MVP; a real fix needs a season-start hook
-- this schema doesn't have yet.

-- ---------------------------------------------------------------------------
-- districts — a fixed catalog of contestable city districts.
-- ---------------------------------------------------------------------------
create table districts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  bonus_type text not null check (bonus_type in ('cycle_boost', 'bank_boost', 'slot_discount')),
  bonus_value numeric(5, 2) not null,
  controlling_gang_id uuid references gangs(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table districts enable row level security;

-- ---------------------------------------------------------------------------
-- district_influence — one row per (district, gang, season); points only
-- ever go up (no way to lose influence in this MVP, matches gang
-- experience's own one-directional design in 0058_gangs.sql).
-- ---------------------------------------------------------------------------
create table district_influence (
  id uuid primary key default gen_random_uuid(),
  district_id uuid not null references districts(id) on delete cascade,
  gang_id uuid not null references gangs(id) on delete cascade,
  points bigint not null default 0,
  season_id uuid not null references seasons(id),
  unique (district_id, gang_id, season_id)
);

create index district_influence_district_idx on district_influence (district_id, season_id);
alter table district_influence enable row level security;

-- Which district a gang is currently "attacking" — every claimed
-- expedition by any of its members adds influence points there (see
-- resolve_due_cycles below). Null until a leader/co_leader picks one.
alter table gangs add column target_district_id uuid references districts(id) on delete set null;

insert into districts (name, slug, bonus_type, bonus_value) values
  ('Центральный Банк', 'central-bank', 'bank_boost', 5),
  ('Порт', 'port', 'slot_discount', 10),
  ('Промзона', 'industrial-zone', 'cycle_boost', 8),
  ('Старый Город', 'old-town', 'cycle_boost', 5);

-- ---------------------------------------------------------------------------
-- get_districts — powers the "Карта Районов" screen. p_user_id is only
-- used to flag the caller's own gang's current target and points, same
-- "is_mine"-style convenience get_gangs already provides — never used for
-- permission checks, this is a public read.
-- ---------------------------------------------------------------------------
create or replace function get_districts(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_my_gang_id uuid;
  v_result jsonb;
begin
  v_season_id := active_season_id();
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
    'is_my_target', coalesce(v_my_gang_id is not null and my_g.target_district_id = d.id, false),
    'my_gang_points', case when v_my_gang_id is not null then coalesce(my_inf.points, 0) else null end,
    'top_influence', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'gang_id', t.gang_id, 'name', t.name, 'avatar_id', t.avatar_id, 'points', t.points
      ) order by t.points desc), '[]'::jsonb)
      from (
        select g.id as gang_id, g.name, g.avatar_id, di.points
        from district_influence di
        join gangs g on g.id = di.gang_id
        where di.district_id = d.id and di.season_id = v_season_id
        order by di.points desc
        limit 3
      ) t
    )
  ) order by d.name), '[]'::jsonb)
  into v_result
  from districts d
  left join gangs cg on cg.id = d.controlling_gang_id
  left join gangs my_g on my_g.id = v_my_gang_id
  left join district_influence my_inf
    on my_inf.district_id = d.id and my_inf.gang_id = v_my_gang_id and my_inf.season_id = v_season_id;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- set_gang_district_target — "Атаковать этот район". Leader OR co_leader
-- (unlike promote/demote/kick/dividends, which stay leader-only) — this is
-- the one action this migration gives the co_leader badge (0061) real
-- authority over, matching the spec's "Кнопка для Босса/Зама".
--
-- Deliberately does NOT apply bonus_type/bonus_value to any gameplay
-- mechanic (cycle speed, slot price, bank cut) yet — the spec's own RPC
-- section only asks for points tracking, not for wiring the bonus into
-- start_cycle/resolve_due_cycles. Controlling a district currently earns a
-- gang bragging rights and a map badge; making bonus_type do something is
-- a deliberate follow-up, not an oversight — flagged in this migration's
-- header and in the final report, not silently skipped.
-- ---------------------------------------------------------------------------
create or replace function set_gang_district_target(p_user_id uuid, p_district_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gang_id uuid;
  v_role text;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_role not in ('leader', 'co_leader') then
    raise exception 'not_gang_officer';
  end if;

  if not exists (select 1 from districts where id = p_district_id) then
    raise exception 'district_not_found';
  end if;

  update gangs set target_district_id = p_district_id where id = v_gang_id;

  return jsonb_build_object('gang_id', v_gang_id, 'target_district_id', p_district_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- distribute_bank_dividends — leader-only. Splits p_amount evenly across
-- every current gang member and deducts exactly p_amount from the bank.
-- Uses the same cumulative-target rounding trick resolve_due_bank_payouts
-- (0057) already uses for daily installments, so the per-member shares
-- always sum to exactly p_amount regardless of how unevenly member_count
-- divides it — no leftover cents stuck in limbo, no member shortchanged
-- because someone else's share got rounded up.
--
-- Bootstraps any member's missing current-season user_seasons row before
-- crediting (same fix create_gang got in 0059, after the same gap caused
-- a real bug there) — a member who's been in the gang since a past
-- season could otherwise silently receive nothing while still counting
-- toward the equal split.
-- ---------------------------------------------------------------------------
create or replace function distribute_bank_dividends(p_user_id uuid, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gang_id uuid;
  v_role text;
  v_bank_balance numeric(14, 2);
  v_season_id uuid;
  v_season_starting_balance numeric(14, 2);
  v_member_count integer;
  v_member record;
  v_idx integer := 0;
  v_running_target numeric(14, 2) := 0;
  v_running_paid numeric(14, 2) := 0;
  v_share numeric(14, 2);
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount_too_low';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  select bank_balance_gram into v_bank_balance from gangs where id = v_gang_id for update;
  if v_bank_balance < p_amount then
    raise exception 'insufficient_gang_bank';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select count(*) into v_member_count from gang_members where gang_id = v_gang_id;

  select coalesce((config->>'starting_balance')::numeric, 0)
  into v_season_starting_balance
  from seasons where id = v_season_id;

  for v_member in
    select user_id from gang_members where gang_id = v_gang_id order by joined_at
  loop
    v_idx := v_idx + 1;
    v_running_target := round(p_amount * v_idx / v_member_count, 2);
    v_share := v_running_target - v_running_paid;
    v_running_paid := v_running_target;

    insert into user_seasons (user_id, season_id, balance, total_earned)
    values (v_member.user_id, v_season_id, v_season_starting_balance, v_season_starting_balance)
    on conflict (user_id, season_id) do nothing;

    update user_seasons set balance = balance + v_share
    where user_id = v_member.user_id and season_id = v_season_id;
  end loop;

  update gangs
  set bank_balance_gram = bank_balance_gram - p_amount,
      bank_balance_ton = bank_balance_ton - p_amount
  where id = v_gang_id;

  return jsonb_build_object(
    'gang_id', v_gang_id,
    'amount', p_amount,
    'member_count', v_member_count,
    'bank_balance_gram', v_bank_balance - p_amount
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_due_cycles — one change from 0058_gangs.sql: inside the existing
-- "claimant is in a gang" block, also add +10 district influence points
-- toward the gang's target_district_id (if it has one), then recompute
-- that district's controlling_gang_id as whichever gang now leads its
-- points. target_district_id is looked up once before the claim loop,
-- same reasoning as v_gang_id right above it. Everything else is
-- byte-for-byte unchanged from 0058_gangs.sql.
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
    -- the new experience total — see this migration's header for the formula.
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

      -- District Wars: +10 influence toward the gang's current attack
      -- target, then recompute who leads that district's points.
      if v_target_district_id is not null then
        insert into district_influence (district_id, gang_id, points, season_id)
        values (v_target_district_id, v_gang_id, 10, v_season_id)
        on conflict (district_id, gang_id, season_id) do update
          set points = district_influence.points + 10;

        update districts d
        set controlling_gang_id = (
          select di.gang_id from district_influence di
          where di.district_id = v_target_district_id and di.season_id = v_season_id
          order by di.points desc, di.gang_id asc
          limit 1
        )
        where d.id = v_target_district_id;
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
-- get_player_state — one addition to the 'gang' object: target_district_id
-- + target_district_name, so the UI can show "сейчас атакуем: <район>"
-- without a second round trip. Everything else byte-for-byte unchanged
-- from the live definition (0058_gangs.sql plus 0058's own later fixes).
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
