-- Gangs MVP (0058_gangs.sql) shipped create/join/leave/disband + a
-- gang bank that only ever fills itself automatically (10% of every claimed
-- cycle, see resolve_due_cycles) -- no way to top it up on purpose, no way
-- to use the 'co_leader' role the schema already had a CHECK constraint
-- for, no way to kick anyone, and no shareable "join this exact gang"
-- link (only the public browse-to-join list). This migration adds all
-- three, deliberately leaving *spending* the gang bank alone for now (no
-- product decision made on what it buys yet) -- it stays a display-only
-- running total, same as before.

-- ---------------------------------------------------------------------------
-- donate_to_gang_bank -- any member tops up their own gang's bank from their
-- own GRAM balance. Same balance-lock-then-check order every other
-- balance-deducting RPC in this schema uses; reuses gang_bank_transactions
-- (already fed automatically by resolve_due_cycles) so a manual donation and
-- an automatic cycle-cut both show up in the same "recent transactions" /
-- "top donors" lists with no UI changes needed.
-- ---------------------------------------------------------------------------
create or replace function donate_to_gang_bank(p_user_id uuid, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_gang_id uuid;
  v_balance numeric(14, 2);
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount_too_low';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id into v_gang_id from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select balance into v_balance
  from user_seasons
  where user_id = p_user_id and season_id = v_season_id
  for update;

  if v_balance is null then
    raise exception 'no_active_season';
  end if;
  if v_balance < p_amount then
    raise exception 'insufficient_balance';
  end if;

  update user_seasons set balance = balance - p_amount
  where user_id = p_user_id and season_id = v_season_id;

  update gangs
  set bank_balance_gram = bank_balance_gram + p_amount,
      bank_balance_ton = bank_balance_ton + p_amount
  where id = v_gang_id;

  insert into gang_bank_transactions (gang_id, from_user_id, amount_gram, amount_ton)
  values (v_gang_id, p_user_id, p_amount, p_amount);

  return jsonb_build_object('gang_id', v_gang_id, 'amount', p_amount, 'balance', v_balance - p_amount);
end;
$$;

-- ---------------------------------------------------------------------------
-- set_gang_member_role -- leader-only promote/demote between 'member' and
-- 'co_leader'. Deliberately narrow: only the leader can do this (co_leader
-- itself grants no extra authority yet, it's a badge until a real
-- lieutenant-permissions design exists), and the leader's own row can never
-- be retargeted through this path -- disband_gang/leave_gang are the only
-- ways the leader role itself ever changes.
-- ---------------------------------------------------------------------------
create or replace function set_gang_member_role(p_user_id uuid, p_target_user_id uuid, p_role text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_gang_id uuid;
  v_caller_role text;
  v_target_gang_id uuid;
  v_target_role text;
begin
  if p_role not in ('co_leader', 'member') then
    raise exception 'invalid_role';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_caller_gang_id, v_caller_role
  from gang_members where user_id = p_user_id;
  if v_caller_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_caller_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  select gang_id, role into v_target_gang_id, v_target_role
  from gang_members where user_id = p_target_user_id for update;
  if v_target_gang_id is null or v_target_gang_id <> v_caller_gang_id then
    raise exception 'not_gang_member';
  end if;
  if v_target_role = 'leader' then
    raise exception 'cannot_change_leader_role';
  end if;

  update gang_members set role = p_role where user_id = p_target_user_id;

  return jsonb_build_object('user_id', p_target_user_id, 'role', p_role);
end;
$$;

-- ---------------------------------------------------------------------------
-- kick_gang_member -- leader-only. Same row-lock-on-target idiom as
-- set_gang_member_role, so a member leaving on their own and the leader
-- kicking them at the same instant can't both "succeed" against a row
-- that's already gone.
-- ---------------------------------------------------------------------------
create or replace function kick_gang_member(p_user_id uuid, p_target_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_gang_id uuid;
  v_caller_role text;
  v_target_gang_id uuid;
  v_target_role text;
begin
  if p_user_id = p_target_user_id then
    raise exception 'cannot_kick_self';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_caller_gang_id, v_caller_role
  from gang_members where user_id = p_user_id;
  if v_caller_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_caller_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  select gang_id, role into v_target_gang_id, v_target_role
  from gang_members where user_id = p_target_user_id for update;
  if v_target_gang_id is null or v_target_gang_id <> v_caller_gang_id then
    raise exception 'not_gang_member';
  end if;
  if v_target_role = 'leader' then
    raise exception 'cannot_kick_leader';
  end if;

  delete from gang_members where user_id = p_target_user_id;

  return jsonb_build_object('kicked_user_id', p_target_user_id);
end;
$$;
