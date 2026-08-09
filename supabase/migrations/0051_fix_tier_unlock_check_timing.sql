-- Bug: tier unlock was only ever (re-)checked from *inside* the loop over
-- cycles due right this instant, in resolve_due_cycles. That loop body only
-- runs when a cycle is actually ending at call time — but resolve_due_cycles
-- itself runs unconditionally on every get_player_state hit (and most other
-- RPCs). Result: a player who already has enough completed_cycles gets
-- stuck if the unlock_min_hours time-floor happens to be crossed while no
-- cycle is ending — the check never re-fires until their *next* cycle
-- naturally completes, which can be hours away. Reported symptom: a user
-- sitting at 19/9 cycles done and >72h elapsed (both conditions already
-- satisfied) still locked out of tier 2, because their last claim landed
-- before the 72h floor was crossed and nothing has completed since.
--
-- Fix: pull the tier-unlock check out of the per-cycle loop so it runs
-- once, unconditionally, every time resolve_due_cycles is called —
-- regardless of whether any cycle was actually claimed this call. Wrapped
-- in a loop (not a single if) so a call that catches up after being stuck
-- for a while can cascade through more than one already-qualified tier in
-- one pass, instead of needing one more state fetch per tier. Otherwise
-- byte-for-byte identical to the 0035_security_audit_fixes.sql version.
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

-- One-time backfill: run the fixed check for every user who's already
-- stuck the way 1011001919 was (qualifies for the next tier right now but
-- hasn't had a cycle complete since crossing the time floor). Without
-- this, they'd still self-heal on their own next state fetch, but no
-- reason to make them wait.
do $$
declare
  v_user record;
begin
  for v_user in select distinct user_id from user_tier_progress
  loop
    perform resolve_due_cycles(v_user.user_id);
  end loop;
end;
$$;
