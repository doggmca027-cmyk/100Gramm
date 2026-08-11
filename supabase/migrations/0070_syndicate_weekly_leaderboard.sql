-- Syndicate Weekly Leaderboard: moves the gang ranking out of the "Банды"
-- section and into the main Leaderboard as a "Синдикаты" tab, switches its
-- scoring to a weekly-resetting Influence Points system, and adds a 100
-- TON/week prize pool auto-paid to the top 15 gangs.
--
-- Deviations from the literal spec, same reasoning as every earlier
-- District Wars migration:
--   * "100 TON" and "1 TON = 200 Influence" are GRAM, same as every other
--     "N TON" in this schema — see 0066_district_wars_monetization.sql's
--     header for why (no second currency or real on-chain payment exists
--     anywhere in this game's economy). The weekly prize therefore credits
--     gangs.bank_balance_gram *and* bank_balance_ton together, same
--     "always mirrored" convention every other gang-bank credit in this
--     schema already follows (resolve_due_cycles' 10% cut,
--     donate_to_gang_bank, resolve_due_gang_bank_interest, etc.) — it does
--     NOT touch any real wallet/withdrawal flow.
--   * The spec's "23:59 (UTC/MSK)" is contradictory (those are different
--     instants) — resolved to UTC only, the one timezone every other
--     time-window computation in this schema already uses exclusively
--     (district battle windows, daily combo reset, bank payouts, ...).
--   * buy_direct_influence's spec signature is `(p_gang_id, p_ton_amount)`.
--     Same deviation 0066 already made for activate_district_boost/
--     activate_mercenary_bot and documented there: every privileged RPC in
--     this schema takes an explicit p_user_id and re-derives the caller's
--     gang + role server-side from gang_members, never a client-supplied
--     gang id — there's no Supabase Auth session here for a policy (or a
--     client-trusted id) to key off instead. Signature is
--     `(p_user_id, p_ton_amount, p_pay_from_bank)`, matching
--     activate_district_boost/activate_mercenary_bot's own
--     p_pay_from_bank pattern for "gang bank vs personal balance".
--   * `weekly_influence_points` lives on `gangs` as the spec asks (not a
--     season-scoped table like the old, now-dropped district_influence) —
--     it's a rolling weekly counter, zeroed in place by
--     finalize_weekly_leaderboard_season() every reset, not something a
--     new row per period would help with.
--   * Finalizing a reset needs a real persisted guard against double-
--     paying (unlike every other resolve_due_* lazy catch-up here, which
--     is naturally idempotent via the status transition on the very rows
--     it processes) — `leaderboard_season_state` is a single-row table
--     holding the last period_end that was actually paid out;
--     finalize_weekly_leaderboard_season() no-ops once that's caught up.
--     Same lazy-catch-up-plus-cron-backstop shape as resolve_due_district_
--     battles otherwise (called unconditionally from get_player_state,
--     the cron endpoint below is purely a promptness backstop).
--   * Whether an active `engineer_shield` should also freeze weekly_
--     influence_points, not just that one district's defense/attack
--     tally, isn't addressed by the spec. Resolved as: no — shield only
--     freezes progress toward controlling that ONE district (its literal,
--     narrow purpose); the wider weekly leaderboard keeps counting every
--     point a gang's members actually earned regardless. See
--     district_credit_battle_points below.

alter table gangs
  add column weekly_influence_points bigint not null default 0;

-- ---------------------------------------------------------------------------
-- leaderboard_history — one row per (period, ranked gang), append-only
-- audit trail of every weekly payout. gang_id -> set null on disband (a
-- disbanded gang's past wins should stay visible), gang_name is a snapshot
-- for exactly that reason.
-- ---------------------------------------------------------------------------
create table leaderboard_history (
  id uuid primary key default gen_random_uuid(),
  period_start timestamptz not null,
  period_end timestamptz not null,
  gang_id uuid references gangs(id) on delete set null,
  gang_name text not null,
  rank smallint not null,
  influence_points bigint not null,
  prize_ton numeric(10, 2) not null,
  created_at timestamptz not null default now(),
  unique (period_end, rank)
);

create index leaderboard_history_period_idx on leaderboard_history (period_end);
alter table leaderboard_history enable row level security;

-- ---------------------------------------------------------------------------
-- leaderboard_season_state — single-row marker of the last period_end
-- finalize_weekly_leaderboard_season() actually paid out. The one piece of
-- state in this whole feature that has to be a persisted fact rather than
-- derived, see this migration's header.
-- ---------------------------------------------------------------------------
create table leaderboard_season_state (
  id boolean primary key default true check (id),
  last_finalized_period_end timestamptz
);

insert into leaderboard_season_state (id) values (true);
alter table leaderboard_season_state enable row level security;

-- ---------------------------------------------------------------------------
-- weekly_leaderboard_next_reset — the next upcoming Sunday 23:59 UTC
-- strictly after p_ref. date_trunc('week', ...) anchors to that week's
-- Monday 00:00 in Postgres, so +6 days +23:59 lands on that same week's
-- Sunday 23:59; if p_ref is already past that instant (only possible in
-- the 1-minute window from Sunday 23:59:00 to Monday 00:00:00, since
-- date_trunc re-anchors every Monday), roll forward 7 days.
-- ---------------------------------------------------------------------------
create or replace function weekly_leaderboard_next_reset(p_ref timestamptz default now())
returns timestamptz
language sql
stable
as $$
  select case when candidate > p_ref then candidate else candidate + interval '7 days' end
  from (
    select (
      date_trunc('week', p_ref at time zone 'utc')::date + interval '6 days' + interval '23 hours 59 minutes'
    ) at time zone 'utc' as candidate
  ) c;
$$;

-- ---------------------------------------------------------------------------
-- district_apply_points — the raw defense/attack tally update, factored
-- out of district_credit_battle_points (0066) so buy_direct_influence
-- below can route its "текущий целевой район" component through the exact
-- same district-control bookkeeping (including the shield freeze) without
-- also re-running the airstrike-multiplier lookup or double-bumping
-- weekly_influence_points (district_credit_battle_points does both of
-- those itself, once, for every organic point source below).
-- ---------------------------------------------------------------------------
create or replace function district_apply_points(
  p_district_id uuid,
  p_gang_id uuid,
  p_battle_date date,
  p_points bigint
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_controller uuid;
begin
  select controlling_gang_id into v_controller from districts where id = p_district_id;

  if v_controller = p_gang_id then
    insert into district_battles (district_id, battle_date, defender_gang_id, defense_points)
    values (p_district_id, p_battle_date, p_gang_id, p_points)
    on conflict (district_id, battle_date) do update
      set defense_points = district_battles.defense_points + p_points;
  else
    if exists (
      select 1 from district_battle_boosts
      where district_id = p_district_id and boost_family = 'shield' and expires_at > now()
    ) then
      return; -- frozen -- attacker's points don't count while the shield holds
    end if;
    update district_challenges set points = points + p_points
    where district_id = p_district_id and battle_date = p_battle_date and gang_id = p_gang_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- district_credit_battle_points — one change from 0066_district_wars_
-- monetization.sql: the defense/attack update itself now goes through
-- district_apply_points (identical logic, just factored out), and every
-- point credited here also lands on gangs.weekly_influence_points, once,
-- unconditionally (even if district_apply_points silently no-opped due to
-- an active shield — see this migration's header for why the shield
-- doesn't reach the wider weekly leaderboard). This is the single shared
-- path every organic point source (claimed cycles via resolve_due_cycles,
-- mercenary-bot ticks via resolve_due_mercenary_bots) already goes
-- through, so both keep feeding the weekly leaderboard automatically with
-- no further changes needed at either call site.
-- ---------------------------------------------------------------------------
create or replace function district_credit_battle_points(
  p_district_id uuid,
  p_gang_id uuid,
  p_battle_date date,
  p_base_points bigint
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_multiplier numeric(3, 1);
  v_points bigint;
begin
  select multiplier into v_multiplier
  from district_battle_boosts
  where district_id = p_district_id and gang_id = p_gang_id and boost_family = 'airstrike' and expires_at > now()
  order by expires_at desc limit 1;

  v_points := round(p_base_points * coalesce(v_multiplier, 1));

  perform district_apply_points(p_district_id, p_gang_id, p_battle_date, v_points);

  update gangs set weekly_influence_points = weekly_influence_points + v_points where id = p_gang_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- buy_direct_influence — leader-or-co_leader-only. Always credits
-- weekly_influence_points (the whole point is a guaranteed, instant
-- purchase — not gated on any battle window). Additionally routes the same
-- amount into the gang's current target district's battle tally, but only
-- under the same conditions organic points already require: the window is
-- currently active, and — if the gang isn't that district's defender — it
-- has actually applied as today's/tonight's challenger (request_district_
-- attack), same as resolve_due_cycles. No minimum via district gating: if
-- there's no target district, or its window is closed, or the gang hasn't
-- applied, the purchase still fully lands on weekly_influence_points, it
-- just doesn't also move that one district's tug-of-war bar.
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
begin
  if p_ton_amount is null or p_ton_amount < 1 then
    raise exception 'amount_too_low';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_role not in ('leader', 'co_leader') then
    raise exception 'not_gang_officer';
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

  return jsonb_build_object(
    'gang_id', v_gang_id, 'points_added', v_points, 'weekly_influence_points', v_gang.weekly_influence_points
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- finalize_weekly_leaderboard_season — the weekly reset + payout. Called
-- unconditionally from get_player_state (lazy catch-up, same posture as
-- resolve_due_district_battles); the cron endpoint below is purely a
-- promptness backstop, matching /api/cron/finalize-district-battles'
-- own role.
--
-- v_period_end is, by construction, always <= now(): weekly_leaderboard_
-- next_reset(now()) is always strictly in the future (see its own
-- definition above), so subtracting exactly one week always lands on the
-- most recently PASSED Sunday-23:59 boundary — there's no "nothing due
-- yet" case to guard here, only "already paid", which last_finalized_
-- period_end (checked under the advisory lock, so two overlapping calls
-- can't both pass it) exists to catch.
-- ---------------------------------------------------------------------------
create or replace function finalize_weekly_leaderboard_season()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period_end timestamptz := weekly_leaderboard_next_reset(now()) - interval '7 days';
  v_period_start timestamptz := weekly_leaderboard_next_reset(now()) - interval '14 days';
  v_last_finalized timestamptz;
  v_prizes numeric(10, 2)[] := array[30, 18, 12, 6, 6, 4, 4, 4, 4, 4, 1.6, 1.6, 1.6, 1.6, 1.6];
  v_gang record;
  v_rank integer := 0;
begin
  perform pg_advisory_xact_lock(hashtext('weekly_leaderboard_finalize'));

  select last_finalized_period_end into v_last_finalized from leaderboard_season_state for update;
  if v_last_finalized is not null and v_last_finalized >= v_period_end then
    return;
  end if;

  for v_gang in
    select id, name, weekly_influence_points
    from gangs
    where weekly_influence_points > 0
    order by weekly_influence_points desc, id asc
    limit 15
  loop
    v_rank := v_rank + 1;

    update gangs
    set bank_balance_gram = bank_balance_gram + v_prizes[v_rank],
        bank_balance_ton = bank_balance_ton + v_prizes[v_rank]
    where id = v_gang.id;

    insert into leaderboard_history (period_start, period_end, gang_id, gang_name, rank, influence_points, prize_ton)
    values (v_period_start, v_period_end, v_gang.id, v_gang.name, v_rank, v_gang.weekly_influence_points, v_prizes[v_rank]);
  end loop;

  update gangs set weekly_influence_points = 0;

  update leaderboard_season_state set last_finalized_period_end = v_period_end;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_syndicate_leaderboard — powers the Leaderboard screen's "Синдикаты"
-- tab. `entries` is the top-15 (gangs with 0 points are never ranked or
-- paid, same "nothing to show" posture as every other empty-state in this
-- schema). `my_gang` is always returned separately (even ranked > 15, or
-- with 0 points and therefore no rank at all) so the caller's own row —
-- and its "Забустить Влияние" button — always has something to render,
-- same is_mine/is_my_target convenience get_gangs/get_districts already
-- provide.
-- ---------------------------------------------------------------------------
create or replace function get_syndicate_leaderboard(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_my_gang_id uuid;
  v_prizes numeric(10, 2)[] := array[30, 18, 12, 6, 6, 4, 4, 4, 4, 4, 1.6, 1.6, 1.6, 1.6, 1.6];
  v_result jsonb;
begin
  select gang_id into v_my_gang_id from gang_members where user_id = p_user_id;

  select jsonb_build_object(
    'next_reset_at', weekly_leaderboard_next_reset(now()),
    'prize_pool_ton', 100,
    'entries', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'rank', ranked.rank,
        'gang_id', ranked.id,
        'name', ranked.name,
        'avatar_id', ranked.avatar_id,
        'premium_avatar_id', ranked.premium_avatar_id,
        'frame_id', ranked.frame_id,
        'member_count', ranked.member_count,
        'weekly_influence_points', ranked.weekly_influence_points,
        'prize_ton', v_prizes[ranked.rank::int],
        'is_mine', ranked.id = v_my_gang_id
      ) order by ranked.rank), '[]'::jsonb)
      from (
        select g.id, g.name, g.avatar_id, g.premium_avatar_id, g.frame_id, g.weekly_influence_points,
          coalesce(mc.member_count, 0) as member_count,
          row_number() over (order by g.weekly_influence_points desc, g.id asc) as rank
        from gangs g
        left join (select gang_id, count(*) as member_count from gang_members group by gang_id) mc on mc.gang_id = g.id
        where g.weekly_influence_points > 0
        order by g.weekly_influence_points desc, g.id asc
        limit 15
      ) ranked
    ),
    'my_gang', (
      select jsonb_build_object(
        'gang_id', g.id,
        'name', g.name,
        'weekly_influence_points', g.weekly_influence_points,
        'rank', case when g.weekly_influence_points > 0 then my_rank.rank else null end,
        'prize_ton', case when g.weekly_influence_points > 0 and my_rank.rank <= 15
          then v_prizes[my_rank.rank::int] else 0 end,
        'my_role', gm.role,
        'target_district_id', g.target_district_id
      )
      from gang_members gm
      join gangs g on g.id = gm.gang_id
      cross join lateral (
        select count(*) + 1 as rank from gangs g2
        where g2.weekly_influence_points > g.weekly_influence_points
           or (g2.weekly_influence_points = g.weekly_influence_points and g2.id < g.id)
      ) my_rank
      where gm.user_id = p_user_id
    )
  ) into v_result;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_player_state — two changes from 0066_district_wars_monetization.sql:
--   1. perform finalize_weekly_leaderboard_season() alongside resolve_due_
--      district_battles/resolve_due_mercenary_bots, the other global
--      (not per-user) lazy catch-ups.
--   2. 'gang' gains weekly_influence_points. Everything else byte-for-byte
--      unchanged from 0066_district_wars_monetization.sql.
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
