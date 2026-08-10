-- 100ГРАМ: "Банды / Синдикаты" (Gangs MVP) — create/join/leave a clan,
-- gang-level ranking fed by expedition activity.
--
-- Deviations from a literal auth.uid()/ton_balance spec, kept consistent
-- with every other table/RPC in this schema (see the header note in
-- 0056_bank_staking.sql, which explains the same two deviations in detail):
--   * No Supabase Auth here — this app authenticates via a custom Telegram
--     initData session (lib/telegram-auth.ts, lib/session.ts), not
--     auth.uid(). Every RPC below takes an explicit p_user_id, trusted only
--     because the calling Next.js route already ran requireUserId()
--     server-side before ever reaching this function.
--   * There is no standalone `ton_balance` column. GRAM *is* TON in this
--     game's economy (see get_player_state's exchange_rate comment,
--     "GRAM/USDT — GRAM is TON") and the one balance a player has lives on
--     user_seasons.balance, season-scoped like every other money field in
--     this schema. "5 TON" to found a gang is a straight 5 deducted from
--     that same balance — no conversion, no second currency.
--
-- Race-condition guards:
--   * pg_advisory_xact_lock(hashtext(p_user_id::text)) at the top of
--     create_gang/join_gang/leave_gang serializes concurrent calls for the
--     *same* user for the duration of the transaction (auto-released on
--     commit/rollback) — closes the "double-click Create/Join" window where
--     two concurrent calls could both pass the "not already in a gang"
--     check before either insert commits. gang_members.user_id is also
--     UNIQUE as a hard backstop; either call failing later rolls its own
--     transaction back in full (balance deduction included), so a losing
--     race never leaves a player charged with no membership to show for it.
--   * join_gang additionally locks the target gang's own row with
--     `for update` before counting members against max_members — every
--     concurrent join_gang(same gang) call serializes on that one row lock,
--     so the count-then-insert can't overshoot capacity, same idiom
--     start_cycle/request_withdrawal already use for balance rows.
--
-- Leveling: kept intentionally simple for the MVP — level = floor(exp/100)+1,
-- i.e. 100 expedition claims (see the resolve_due_cycles hook below) per
-- level, no separate level-up RPC or table to keep in sync. Easy to swap for
-- a real curve later without touching callers, since level is always
-- recomputed from experience in the same statement that changes it.

-- ---------------------------------------------------------------------------
-- gangs — one row per clan.
-- ---------------------------------------------------------------------------
create table gangs (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(name) between 3 and 15),
  leader_id uuid not null references users(id),
  level integer not null default 1,
  experience bigint not null default 0,
  bank_balance_gram numeric(14, 2) not null default 0,
  bank_balance_ton numeric(14, 2) not null default 0,
  max_members integer not null default 20,
  avatar_id text not null default 'default_gang'
    check (avatar_id in ('default_gang', 'skull', 'crown', 'flame', 'shield', 'swords', 'ghost', 'anchor')),
  created_at timestamptz not null default now()
);

-- Belt-and-suspenders on top of the plain `unique` above: catches
-- "Волки" vs "волки" duplicates the case-sensitive constraint alone would
-- let through.
create unique index gangs_name_lower_idx on gangs (lower(name));

alter table gangs enable row level security;

-- ---------------------------------------------------------------------------
-- gang_members — one row per (user), globally unique on user_id so "one gang
-- at a time" is enforced by the schema itself, not just application logic.
-- ---------------------------------------------------------------------------
create table gang_members (
  id uuid primary key default gen_random_uuid(),
  gang_id uuid not null references gangs(id) on delete cascade,
  user_id uuid not null references users(id) unique,
  role text not null check (role in ('leader', 'co_leader', 'member')),
  joined_at timestamptz not null default now()
);

create index gang_members_gang_idx on gang_members (gang_id);

create table gang_bank_transactions (
  id uuid primary key default gen_random_uuid(),
  gang_id uuid not null references gangs(id) on delete cascade,
  from_user_id uuid not null references users(id),
  cycle_id uuid references cycles(id) on delete set null,
  amount_gram numeric(14, 2) not null,
  amount_ton numeric(14, 2) not null default 0,
  created_at timestamptz not null default now()
);

create index gang_bank_transactions_gang_idx on gang_bank_transactions (gang_id);

alter table gang_bank_transactions enable row level security;

alter table gang_members enable row level security;

-- ---------------------------------------------------------------------------
-- is_gang_name_clean — a deliberately small, MVP-grade profanity/junk
-- filter: rejects a short blacklist of common ru/en slurs and disallows
-- anything outside letters/digits/spaces/-/_. Not exhaustive by design —
-- swap for a real moderation service later without touching callers.
-- ---------------------------------------------------------------------------
create or replace function is_gang_name_clean(p_name text)
returns boolean
language sql
immutable
as $$
  select p_name ~ '^[[:alnum:][:space:]_-]+$'
    and not exists (
      select 1 from unnest(array[
        'хуй', 'хуе', 'хуё', 'пизд', 'ебан', 'ебал', 'ебуч', 'сука', 'блять', 'бляд',
        'мудак', 'долбоеб', 'долбоёб', 'залуп', 'пидор', 'пидар',
        'fuck', 'shit', 'bitch', 'cunt', 'nigger', 'nigga', 'asshole'
      ]) as bad
      where lower(p_name) like '%' || bad || '%'
    );
$$;

-- ---------------------------------------------------------------------------
-- create_gang — founds a gang for exactly 5 GRAM ("5 TON", see header),
-- makes the caller its leader. Atomic: any exception below (bad name,
-- insufficient balance, name already taken, already in a gang) rolls back
-- the whole call, including the balance deduction.
-- ---------------------------------------------------------------------------
create or replace function create_gang(p_user_id uuid, p_name text, p_avatar_id text default 'default_gang')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cost constant numeric := 5;
  v_season_id uuid;
  v_name text;
  v_avatar_id text;
  v_balance numeric(14, 2);
  v_gang_id uuid;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  if exists (select 1 from gang_members where user_id = p_user_id) then
    raise exception 'already_in_gang';
  end if;

  v_name := trim(coalesce(p_name, ''));
  if char_length(v_name) < 3 or char_length(v_name) > 15 then
    raise exception 'invalid_name_length';
  end if;
  if not is_gang_name_clean(v_name) then
    raise exception 'invalid_name_chars';
  end if;
  if exists (select 1 from gangs where lower(name) = lower(v_name)) then
    raise exception 'name_taken';
  end if;

  v_avatar_id := coalesce(nullif(trim(p_avatar_id), ''), 'default_gang');
  if v_avatar_id not in ('default_gang', 'skull', 'crown', 'flame', 'shield', 'swords', 'ghost', 'anchor') then
    v_avatar_id := 'default_gang';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  -- Lock first, check second — same order every other balance-deducting
  -- RPC in this schema uses (request_withdrawal, start_cycle, create_bank_deposit).
  select balance into v_balance
  from user_seasons
  where user_id = p_user_id and season_id = v_season_id
  for update;

  if v_balance is null then
    raise exception 'no_active_season';
  end if;
  if v_balance < v_cost then
    raise exception 'insufficient_balance';
  end if;

  update user_seasons set balance = balance - v_cost
  where user_id = p_user_id and season_id = v_season_id;

  insert into gangs (name, leader_id, avatar_id)
  values (v_name, p_user_id, v_avatar_id)
  returning id into v_gang_id;

  insert into gang_members (gang_id, user_id, role)
  values (v_gang_id, p_user_id, 'leader');

  return jsonb_build_object('gang_id', v_gang_id, 'name', v_name, 'balance', v_balance - v_cost);
end;
$$;

-- ---------------------------------------------------------------------------
-- join_gang — adds the caller as a plain member, capacity-checked under a
-- row lock on the target gang (see header for the race-condition reasoning).
-- ---------------------------------------------------------------------------
create or replace function join_gang(p_user_id uuid, p_gang_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max_members integer;
  v_member_count integer;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  if exists (select 1 from gang_members where user_id = p_user_id) then
    raise exception 'already_in_gang';
  end if;

  select max_members into v_max_members
  from gangs
  where id = p_gang_id
  for update;

  if not found then
    raise exception 'gang_not_found';
  end if;

  select count(*) into v_member_count from gang_members where gang_id = p_gang_id;
  if v_member_count >= v_max_members then
    raise exception 'gang_full';
  end if;

  insert into gang_members (gang_id, user_id, role)
  values (p_gang_id, p_user_id, 'member');

  return jsonb_build_object('gang_id', p_gang_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- leave_gang — a leader can't leave (must disband_gang instead, see
-- below); anyone else just drops their membership row.
-- ---------------------------------------------------------------------------
create or replace function leave_gang(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select role into v_role from gang_members where user_id = p_user_id for update;
  if not found then
    raise exception 'not_in_gang';
  end if;
  if v_role = 'leader' then
    raise exception 'leader_cannot_leave';
  end if;

  delete from gang_members where user_id = p_user_id;

  return jsonb_build_object('left', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- disband_gang — the leader's only way out (spec: "требуется передача
-- лидерки или удаление банды"). Deletes the gang outright; ON DELETE
-- CASCADE clears every member row, including the leader's own, in the same
-- statement.
-- ---------------------------------------------------------------------------
create or replace function disband_gang(p_user_id uuid)
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

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id for update;
  if not found then
    raise exception 'not_in_gang';
  end if;
  if v_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  delete from gangs where id = v_gang_id;

  return jsonb_build_object('disbanded', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- get_gangs — powers both the "browse to join" list and the "Топ Банд
-- Района" ranking table: same ordering (level desc, experience desc) either
-- way, p_search just narrows it by name. is_mine flags the caller's own
-- gang so the UI can highlight it in the ranking table.
-- ---------------------------------------------------------------------------
create or replace function get_gangs(p_user_id uuid, p_search text default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', g.id,
    'name', g.name,
    'avatar_id', g.avatar_id,
    'level', g.level,
    'experience', g.experience,
    'max_members', g.max_members,
    'member_count', coalesce(mc.member_count, 0),
    'leader_name', coalesce(u.username, u.first_name, 'Игрок'),
    'is_mine', exists (select 1 from gang_members where user_id = p_user_id and gang_id = g.id)
  ) order by g.level desc, g.experience desc, g.name asc), '[]'::jsonb)
  from gangs g
  join users u on u.id = g.leader_id
  left join (
    select gang_id, count(*) as member_count from gang_members group by gang_id
  ) mc on mc.gang_id = g.id
  where p_search is null or p_search = '' or g.name ilike '%' || p_search || '%'
  limit 100;
$$;

-- ---------------------------------------------------------------------------
-- resolve_due_cycles — one change from 0051_fix_tier_unlock_check_timing.sql:
-- each cycle actually claimed in the loop now also credits +1 EXP to the
-- claimant's gang, if they're in one (spec: "при каждом успешном сборе
-- экспедиции ... +1 EXP"). level is recomputed in the same statement (see
-- header). Everything else is byte-for-byte unchanged.
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
  select gang_id into v_gang_id from gang_members where user_id = p_user_id;

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
-- get_player_state — adds 'gang': null when the caller isn't in one,
-- otherwise the gang's own summary plus its full member roster (capped at
-- max_members = 20, cheap to inline here rather than a separate on-demand
-- endpoint like fetchSquadLevels). Otherwise identical to the
-- 0057_bank_daily_payouts.sql version.
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
        ) order by donors.total_amount desc, donors.from_user_id limit 5), '[]'::jsonb)
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
        ) order by gb.created_at desc limit 10), '[]'::jsonb)
        from gang_bank_transactions gb
        join users du on du.id = gb.from_user_id
        where gb.gang_id = g.id
      )
      )
      from gang_members gm_self
      join gangs g on g.id = gm_self.gang_id
      join users lu on lu.id = g.leader_id
      where gm_self.user_id = p_user_id
    )
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- start_cycle — override 0056_bank_staking.sql to remove the old referral
-- payout path from cycle launch. Referrals now pay only on deposits.
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
  v_bank_slot_active boolean;
  v_bank_slot_bonus integer;
  v_bank_speed_active boolean;
  v_total_slots integer;
  v_boost_id uuid;
  v_used_slots integer;
  v_free_slots integer;
  v_balance numeric(14, 2);
  v_total_price numeric(12, 2);
  v_cycle_id uuid;
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

  select exists (
    select 1 from bank_deposits
    where user_id = p_user_id and season_id = v_season_id
      and status = 'active' and ends_at > now() and bonus_slot
  ) into v_bank_slot_active;
  v_bank_slot_bonus := case when v_bank_slot_active then 1 else 0 end;

  v_total_slots := v_tier_slots + v_boost_count + v_bank_slot_bonus;

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

  if v_boost_count > 0 and (v_used_slots + v_free_slots) > v_tier_slots then
    select id into v_boost_id
    from user_boosts
    where user_id = p_user_id and season_id = v_season_id and target_tier = p_tier and status = 'ACTIVE'
    order by activated_at asc
    limit 1;
  end if;

  update user_seasons set balance = balance - v_total_price
  where user_id = p_user_id and season_id = v_season_id;

  select exists (
    select 1 from bank_deposits
    where user_id = p_user_id and season_id = v_season_id
      and status = 'active' and ends_at > now() and bonus_speed
  ) into v_bank_speed_active;

  insert into cycles (user_id, season_id, tier, status, started_at, ends_at, amount_in, slot_quantity, boost_id)
  values (
    p_user_id, v_season_id, p_tier, 'running', now(),
    now() + (
      (case when v_bank_speed_active then v_cycle_hours / 1.10 else v_cycle_hours end)::text || ' hours'
    )::interval,
    v_total_price, v_free_slots, v_boost_id
  )
  returning id into v_cycle_id;

  return v_cycle_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- deposit referral helpers — 10/5/2% on real deposits only.
-- ---------------------------------------------------------------------------
create or replace function distribute_deposit_referral_bonuses(
  p_source_user_id uuid,
  p_amount numeric
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_referrer1 uuid;
  v_referrer2 uuid;
  v_referrer3 uuid;
  v_bonus numeric(12, 2);
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    return;
  end if;

  select referred_by into v_referrer1 from users where id = p_source_user_id;
  if v_referrer1 is null then
    return;
  end if;

  v_bonus := round(p_amount * 0.10, 2);
  update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
  where user_id = v_referrer1 and season_id = v_season_id;
  if found then
    insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount, season_id)
    values (v_referrer1, p_source_user_id, 1, null, v_bonus, v_season_id);
  else
    return;
  end if;

  select referred_by into v_referrer2 from users where id = v_referrer1;
  if v_referrer2 is null then
    return;
  end if;

  v_bonus := round(p_amount * 0.05, 2);
  update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
  where user_id = v_referrer2 and season_id = v_season_id;
  if found then
    insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount, season_id)
    values (v_referrer2, p_source_user_id, 2, null, v_bonus, v_season_id);
  else
    return;
  end if;

  select referred_by into v_referrer3 from users where id = v_referrer2;
  if v_referrer3 is null then
    return;
  end if;

  v_bonus := round(p_amount * 0.02, 2);
  update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
  where user_id = v_referrer3 and season_id = v_season_id;
  if found then
    insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount, season_id)
    values (v_referrer3, p_source_user_id, 3, null, v_bonus, v_season_id);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Override older deposit handlers to pay referral bonuses on every
-- balance top-up, not on cycle launch.
-- ---------------------------------------------------------------------------
create or replace function deposit_gram(p_user_id uuid, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_deposit_min numeric;
  v_tx_id uuid;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select coalesce((config->'wallet'->>'deposit_min')::numeric, 1)
  into v_deposit_min
  from seasons where id = v_season_id;

  if p_amount is null or p_amount < v_deposit_min then
    raise exception 'amount_too_low';
  end if;

  update user_seasons set balance = balance + p_amount
  where user_id = p_user_id and season_id = v_season_id;

  if not found then
    raise exception 'no_active_season';
  end if;

  insert into wallet_transactions (user_id, season_id, type, amount, fee, net_amount)
  values (p_user_id, v_season_id, 'deposit', p_amount, 0, p_amount)
  returning id into v_tx_id;

  perform distribute_deposit_referral_bonuses(p_user_id, p_amount);

  return jsonb_build_object('id', v_tx_id, 'amount', p_amount, 'fee', 0, 'net_amount', p_amount);
end;
$$;

create or replace function credit_ton_deposit(
  p_user_id uuid,
  p_tx_hash text,
  p_amount_ton numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_gram_amount numeric(12, 2);
  v_tx_id uuid;
begin
  if p_tx_hash is null or length(p_tx_hash) = 0 then
    raise exception 'invalid_tx_hash';
  end if;

  if p_amount_ton is null or p_amount_ton <= 0 then
    raise exception 'amount_too_low';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  v_gram_amount := p_amount_ton;

  insert into wallet_transactions (user_id, season_id, type, amount, fee, net_amount, tx_hash)
  values (p_user_id, v_season_id, 'purchase', p_amount_ton, 0, v_gram_amount, p_tx_hash)
  returning id into v_tx_id;

  update user_seasons set balance = balance + v_gram_amount
  where user_id = p_user_id and season_id = v_season_id;

  if not found then
    raise exception 'no_active_season';
  end if;

  perform distribute_deposit_referral_bonuses(p_user_id, v_gram_amount);

  return jsonb_build_object(
    'id', v_tx_id,
    'gram_amount', v_gram_amount,
    'amount_ton', p_amount_ton,
    'tx_hash', p_tx_hash
  );
exception
  when unique_violation then
    raise exception 'tx_already_used';
end;
$$;

create or replace function credit_usdt_payment(
  p_user_id uuid,
  p_tx_hash text,
  p_usdt_amount numeric,
  p_gram_amount numeric,
  p_quote_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_tx_id uuid;
begin
  if p_tx_hash is null or length(p_tx_hash) = 0 then
    raise exception 'invalid_tx_hash';
  end if;

  if p_gram_amount is null or p_gram_amount <= 0 then
    raise exception 'amount_too_low';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  insert into wallet_transactions (user_id, season_id, type, amount, fee, net_amount, tx_hash)
  values (p_user_id, v_season_id, 'purchase', p_usdt_amount, 0, p_gram_amount, p_tx_hash)
  returning id into v_tx_id;

  update user_seasons set balance = balance + p_gram_amount
  where user_id = p_user_id and season_id = v_season_id;

  if not found then
    raise exception 'no_active_season';
  end if;

  if p_quote_id is not null then
    update usdt_payment_quotes set consumed_at = now()
    where id = p_quote_id and user_id = p_user_id and consumed_at is null;
  end if;

  perform distribute_deposit_referral_bonuses(p_user_id, p_gram_amount);

  return jsonb_build_object(
    'id', v_tx_id,
    'gram_amount', p_gram_amount,
    'usdt_amount', p_usdt_amount,
    'tx_hash', p_tx_hash
  );
exception
  when unique_violation then
    raise exception 'tx_already_used';
end;
$$;
