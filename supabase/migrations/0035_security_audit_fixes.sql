-- 100ГРАМ: full-codebase security/correctness audit — fixes for the two
-- real issues found in the database layer (a third, unrelated fix for a
-- PostgREST filter-injection in the admin user-search route, lives in the
-- application code, not here).
--
-- ---------------------------------------------------------------------------
-- 1) CRITICAL — resolve_due_cycles double-credit race condition.
--
-- The cursor's SELECT had no row lock at all (not even a plain `for
-- update`, let alone the `skip locked` pattern every other claim-style
-- function in this schema uses — claim_quest, open_container,
-- apply_time_skip_item, ...). Two concurrent calls for the same user
-- (trivial to trigger: this runs on *every* get_player_state call, i.e.
-- every /api/state hit, so a handful of parallel requests right as a cycle
-- becomes due is enough) could both read the same due cycle as still
-- 'running' before either commits. The first UPDATE ... WHERE id = v_cycle.id
-- had no `and status = 'running'` guard either, so the second transaction,
-- once unblocked by the first's commit, applied the same status/amount
-- update *again* and credited user_seasons.balance a second time for a
-- cycle that had already paid out once. Net effect: an attacker (or just
-- two browser tabs) could mint unlimited GRAM by firing concurrent
-- requests at any endpoint that ends in get_player_state.
--
-- Fix: `for update skip locked` on the cursor so a second concurrent call
-- simply skips a cycle the first one is already holding (instead of
-- blocking and then double-processing it once unblocked), plus an
-- `and status = 'running'` guard + row-count check on the UPDATE as
-- defense in depth. Otherwise byte-for-byte identical to the
-- 0018_boost_inventory.sql version.
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
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    return;
  end if;

  select coalesce((config->'features'->>'containers')::boolean, false)
  into v_containers_enabled
  from seasons where id = v_season_id;

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

    -- tier unlock: needs BOTH enough completed cycles AND minimum elapsed time,
    -- so stacking slots can't rush progression (only wall-clock time can).
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

    if v_next_required_cycles is not null
       and v_tier_progress.completed_cycles >= v_next_required_cycles
       and now() >= v_tier_progress.unlocked_at + (v_next_min_hours::text || ' hours')::interval
       and exists (select 1 from product_templates where season_id = v_season_id and tier = v_max_tier + 1)
    then
      insert into user_tier_progress (user_id, season_id, tier, completed_cycles, unlocked_at)
      values (p_user_id, v_season_id, v_max_tier + 1, 0, now())
      on conflict (user_id, season_id, tier) do nothing;
    end if;
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
-- 2) MEDIUM — referral chain cycles enable mutual self-payout farming.
--
-- referred_by can only ever be set once per user (`where referred_by is
-- null`), which prevents changing an existing referral — but nothing
-- stopped it from being set to someone who (directly or via up to 2 more
-- hops) is *already* the caller's own referral. Since bootstrap_user runs
-- on every login (not just first signup) and always processes whatever
-- start_param is present, an already-registered, still-unreferred user
-- could open a teammate's invite link and set up a short cycle — e.g. A
-- refers B, then B (still unreferred at signup time isn't even required —
-- A just needs to have never been referred yet) opens A's own link,
-- setting A.referred_by = B. From then on, A and B each earn a recurring
-- cut of the *other's* own spending forever. A 3-party cycle is even more
-- profitable (see the migration's own commit message for the trace): with
-- exactly 3 colluding accounts, all 3 earn on *every* cycle any one of
-- them ever runs, because the payout walk is exactly 3 levels deep.
--
-- Fix: before setting referred_by, walk up to 3 links from the prospective
-- referrer (matching the payout depth exactly — a cycle longer than 3
-- hops can't actually self-pay, since the payout walk would never reach
-- back around to the original user) and refuse the referral if the caller
-- shows up anywhere in that chain. Otherwise identical to the
-- 0016_per_item_slots.sql version.
-- ---------------------------------------------------------------------------
create or replace function bootstrap_user(
  p_telegram_id bigint,
  p_username text,
  p_first_name text,
  p_ref_code text default null,
  p_photo_url text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_season_id uuid;
  v_referrer_id uuid;
  v_starting_balance numeric(14, 2);
  v_walk uuid;
  v_depth integer;
  v_creates_cycle boolean;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  insert into users (telegram_id, username, first_name, photo_url)
  values (p_telegram_id, p_username, p_first_name, p_photo_url)
  on conflict (telegram_id) do update
    set username = excluded.username,
        first_name = excluded.first_name,
        photo_url = excluded.photo_url
  returning id into v_user_id;

  if p_ref_code is not null and p_ref_code ~ '^[0-9]+$' then
    select id into v_referrer_id from users where telegram_id = p_ref_code::bigint;
    if v_referrer_id is not null and v_referrer_id <> v_user_id then
      v_walk := v_referrer_id;
      v_depth := 0;
      v_creates_cycle := false;
      while v_walk is not null and v_depth < 3 loop
        if v_walk = v_user_id then
          v_creates_cycle := true;
          exit;
        end if;
        select referred_by into v_walk from users where id = v_walk;
        v_depth := v_depth + 1;
      end loop;

      if not v_creates_cycle then
        update users set referred_by = v_referrer_id
        where id = v_user_id and referred_by is null;
      end if;
    end if;
  end if;

  select coalesce((config->>'starting_balance')::numeric, 0)
  into v_starting_balance
  from seasons where id = v_season_id;

  insert into user_seasons (user_id, season_id, balance, total_earned)
  values (v_user_id, v_season_id, v_starting_balance, v_starting_balance)
  on conflict (user_id, season_id) do nothing;

  insert into user_tier_progress (user_id, season_id, tier, completed_cycles, unlocked_at)
  values (v_user_id, v_season_id, 1, 0, now())
  on conflict (user_id, season_id, tier) do nothing;

  return v_user_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) PERFORMANCE — process_auto_collect_cycles ran unthrottled on *every*
-- get_player_state call, i.e. every /api/state request from every player —
-- a full scan + resolve/relaunch pass over every auto-collect-active
-- player in the season, every single time anyone's client fetches state.
-- The passive TON/USDT deposit sweeps added in 0032/0033 already learned
-- this lesson (throttled to one pass per ~30s via try_claim_deposit_sweep_slot);
-- this brings auto-collect in line with the same pattern instead of being
-- the one unthrottled global sweep left in the hot path. Nothing about
-- auto-collect's own correctness needs sub-30s freshness — cycles run for
-- hours — so this is a pure load reduction, not a behavior change.
-- ---------------------------------------------------------------------------
insert into deposit_sweep_state (kind) values ('auto_collect') on conflict (kind) do nothing;

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
  if not try_claim_deposit_sweep_slot('auto_collect', 20) then
    return jsonb_build_object('users_processed', 0, 'cycles_restarted', 0, 'skipped', true);
  end if;

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
