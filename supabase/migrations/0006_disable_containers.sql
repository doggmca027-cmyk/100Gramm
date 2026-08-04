-- 100ГРАМ: containers move to a later season. Turn off the drop via a
-- season feature flag (data/config change, not a schema change) rather
-- than deleting container_templates/user_containers — re-enabling later
-- is then just flipping the flag back on for that season.

update seasons
set config = jsonb_set(config, '{features,containers}', 'false'::jsonb)
where slug = 'season-1';

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
  v_completed_cycles_total integer;
  v_slots_count integer;
  v_base_slots integer;
  v_cycles_per_slot integer;
  v_max_slots integer;
  v_containers_enabled boolean;
  v_new_slots integer;
  v_max_tier smallint;
  v_tier_progress record;
  v_next_required_cycles integer;
  v_next_min_hours numeric(8, 2);
  v_referrer1 uuid;
  v_referrer2 uuid;
  v_referrer3 uuid;
  v_bonus numeric(12, 2);
  v_claimed_count integer := 0;
  v_quest record;
  v_container_template_id uuid;
  v_open_minutes integer;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    return;
  end if;

  select coalesce((config->>'base_slots')::integer, 3),
         coalesce((config->>'cycles_per_slot')::integer, 5),
         (config->>'max_slots')::integer,
         coalesce((config->'features'->>'containers')::boolean, false)
  into v_base_slots, v_cycles_per_slot, v_max_slots, v_containers_enabled
  from seasons where id = v_season_id;

  for v_cycle in
    select c.* from cycles c
    where c.user_id = p_user_id
      and c.season_id = v_season_id
      and c.status = 'running'
      and c.ends_at <= now()
    order by c.ends_at asc
  loop
    select payout_percent into v_payout_percent
    from product_templates
    where season_id = v_season_id and tier = v_cycle.tier;

    v_amount_out := round(v_cycle.amount_in * (1 + v_payout_percent / 100), 2);

    update cycles
    set status = 'claimed', claimed_at = now(), amount_out = v_amount_out
    where id = v_cycle.id;

    update user_seasons
    set balance = balance + v_amount_out,
        total_earned = total_earned + v_amount_out,
        completed_cycles_total = completed_cycles_total + 1
    where user_id = p_user_id and season_id = v_season_id
    returning completed_cycles_total, slots_count into v_completed_cycles_total, v_slots_count;

    update user_tier_progress
    set completed_cycles = completed_cycles + 1
    where user_id = p_user_id and season_id = v_season_id and tier = v_cycle.tier;

    v_claimed_count := v_claimed_count + 1;

    -- containers: season-1 has them turned off (coming in a later season)
    if v_containers_enabled then
      -- every claimed cycle drops one container, weighted by drop_weight
      -- (exponential-clock method: min of -ln(U)/weight samples proportional to weight)
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

    -- slots: grow with total completed cycles, never shrink
    v_new_slots := v_base_slots + floor(v_completed_cycles_total::numeric / v_cycles_per_slot)::integer;
    if v_max_slots is not null and v_new_slots > v_max_slots then
      v_new_slots := v_max_slots;
    end if;
    if v_new_slots > v_slots_count then
      update user_seasons set slots_count = v_new_slots
      where user_id = p_user_id and season_id = v_season_id;
      v_slots_count := v_new_slots;
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

    -- 3-level virality-loop bonus (virtual GRAM only), paid to seasoned referrers
    select referred_by into v_referrer1 from users where id = p_user_id;
    if v_referrer1 is not null then
      v_bonus := round(v_amount_out * 0.10, 2);
      update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
      where user_id = v_referrer1 and season_id = v_season_id;
      if found then
        insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount)
        values (v_referrer1, p_user_id, 1, v_cycle.id, v_bonus);
      end if;

      select referred_by into v_referrer2 from users where id = v_referrer1;
      if v_referrer2 is not null then
        v_bonus := round(v_amount_out * 0.05, 2);
        update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
        where user_id = v_referrer2 and season_id = v_season_id;
        if found then
          insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount)
          values (v_referrer2, p_user_id, 2, v_cycle.id, v_bonus);
        end if;

        select referred_by into v_referrer3 from users where id = v_referrer2;
        if v_referrer3 is not null then
          v_bonus := round(v_amount_out * 0.02, 2);
          update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
          where user_id = v_referrer3 and season_id = v_season_id;
          if found then
            insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount)
            values (v_referrer3, p_user_id, 3, v_cycle.id, v_bonus);
          end if;
        end if;
      end if;
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
