-- 100ГРАМ: referral payout rates updated —
--
--   level   standard   ambassador
--   1       5%         8%
--   2       3%         5%
--   3       1%         3%
--
-- (previously 10/5/2% standard, 15/9/5% ambassador — see
-- 0010_referral_on_start_and_ambassador_rates.sql). Same mechanism as
-- before: paid immediately off each cycle's own deposit amount at launch,
-- not a separate calculation step — start_cycle is otherwise byte-for-byte
-- identical to the 0018_boost_inventory.sql version.

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
  v_total_slots integer;
  v_boost_id uuid;
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

  v_total_slots := v_tier_slots + v_boost_count;

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

  -- does this launch's batch reach into the boosted (beyond-progression) capacity?
  if v_boost_count > 0 and (v_used_slots + v_free_slots) > v_tier_slots then
    select id into v_boost_id
    from user_boosts
    where user_id = p_user_id and season_id = v_season_id and target_tier = p_tier and status = 'ACTIVE'
    order by activated_at asc
    limit 1;
  end if;

  update user_seasons set balance = balance - v_total_price
  where user_id = p_user_id and season_id = v_season_id;

  insert into cycles (user_id, season_id, tier, status, started_at, ends_at, amount_in, slot_quantity, boost_id)
  values (
    p_user_id, v_season_id, p_tier, 'running', now(),
    now() + (v_cycle_hours::text || ' hours')::interval, v_total_price, v_free_slots, v_boost_id
  )
  returning id into v_cycle_id;

  -- 3-level referral bonus, paid now, off the deposit (v_total_price), to
  -- seasoned referrers (must already have a user_seasons row this season)
  select referred_by into v_referrer1 from users where id = p_user_id;
  if v_referrer1 is not null then
    select is_ambassador into v_is_ambassador from users where id = v_referrer1;
    v_bonus := round(v_total_price * (case when v_is_ambassador then 0.08 else 0.05 end), 2);
    update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
    where user_id = v_referrer1 and season_id = v_season_id;
    if found then
      insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount)
      values (v_referrer1, p_user_id, 1, v_cycle_id, v_bonus);
    end if;

    select referred_by into v_referrer2 from users where id = v_referrer1;
    if v_referrer2 is not null then
      select is_ambassador into v_is_ambassador from users where id = v_referrer2;
      v_bonus := round(v_total_price * (case when v_is_ambassador then 0.05 else 0.03 end), 2);
      update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
      where user_id = v_referrer2 and season_id = v_season_id;
      if found then
        insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount)
        values (v_referrer2, p_user_id, 2, v_cycle_id, v_bonus);
      end if;

      select referred_by into v_referrer3 from users where id = v_referrer2;
      if v_referrer3 is not null then
        select is_ambassador into v_is_ambassador from users where id = v_referrer3;
        v_bonus := round(v_total_price * (case when v_is_ambassador then 0.03 else 0.01 end), 2);
        update user_seasons set balance = balance + v_bonus, total_earned = total_earned + v_bonus
        where user_id = v_referrer3 and season_id = v_season_id;
        if found then
          insert into referral_earnings (beneficiary_id, source_user_id, level, cycle_id, amount)
          values (v_referrer3, p_user_id, 3, v_cycle_id, v_bonus);
        end if;
      end if;
    end if;
  end if;

  return v_cycle_id;
end;
$$;
