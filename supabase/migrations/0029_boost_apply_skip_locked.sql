-- 100ГРАМ: fix a spurious item_not_available on rapid concurrent "use boost"
-- calls for the same item_type (double-tap, or a network retry landing
-- twice).
--
-- apply_time_skip_item/apply_auto_collect_item pick the soonest-expiring
-- active unit via `select ... order by expires_at asc limit 1 for update`.
-- When two calls race on units of the same item_type, the second blocks on
-- the row the first one just locked. Once that lock is released, Postgres
-- re-checks the row's WHERE clause against its now-'used' state — and
-- because of how LIMIT interacts with that re-check, a row that stops
-- matching is simply dropped from the result instead of being replaced by
-- the next-soonest candidate. The caller ends up with item_not_available
-- even though a second unit of the same type is free.
--
-- `skip locked` fixes it at the root: instead of waiting on (and then
-- losing) a row someone else already has locked, the second call moves on
-- immediately to the next available unit. Bodies are otherwise byte-for-byte
-- identical to the 0027_combo_item_drops.sql versions.

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
  for update skip locked;

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
  for update skip locked;

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
