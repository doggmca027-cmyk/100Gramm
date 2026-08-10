-- Fix create_gang to bootstrap a missing user_seasons row with the active season's starting balance.
-- This is needed even after editing the original migration, because existing
-- databases must receive an explicit schema migration to update the stored
-- RPC definition.

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

  select coalesce((config->>'starting_balance')::numeric, 0)
  into v_balance
  from seasons
  where id = v_season_id;

  insert into user_seasons (user_id, season_id, balance, total_earned)
  values (p_user_id, v_season_id, v_balance, v_balance)
  on conflict (user_id, season_id) do nothing;

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
