-- Audit pass over the whole gang mechanic (0058-0063) — three real
-- fund-safety bugs found and fixed here, all confirmed live in a
-- rolled-back transaction before being applied for real.
--
-- 1. disband_gang destroyed the gang's bank outright. bank_balance_gram/
--    ton can hold real player money (manual donate_to_gang_bank
--    donations, not just the automatic 10% cycle cut) and `delete from
--    gangs` had no payout step — a leader disbanding a gang with a
--    nonzero bank simply erased that money from the economy, with no
--    refund to the members who put it there. Now auto-distributes
--    whatever's left in the bank across every current member (same
--    formula as distribute_bank_dividends) before deleting the gang, so
--    disbanding can never destroy real GRAM.
--
-- 2. distribute_bank_dividends read the member count and then re-queried
--    the member list as two separate statements. Under READ COMMITTED
--    (this database's default), a leave_gang/kick_gang_member that
--    commits in between those two statements changes who the second
--    query actually returns — but the bank deduction afterward always
--    subtracts the full requested amount regardless of how many members
--    the loop actually paid. A member leaving/getting kicked in that
--    narrow window meant the bank lost the full amount while the
--    now-smaller member set split a share computed for the original,
--    larger count — the shortfall vanished, credited to no one. Fixed by
--    locking and materializing the exact member list once (`for update`),
--    so the count used for the split and the set actually paid are
--    always the same locked snapshot.
--
-- 3. donate_to_gang_bank deducted the donor's personal balance before
--    crediting the gang's bank, with no check that the credit actually
--    landed anywhere. A gang disbanding in the same instant as a member's
--    donation (gang_members cascades away with the gang) meant the bank
--    UPDATE silently affected zero rows — donor charged, no gang left to
--    receive it. Now checks the update's row count and raises
--    'gang_not_found' if the gang is gone, which rolls back the whole
--    call (including the balance deduction) instead of losing the money.

create or replace function disband_gang(p_user_id uuid)
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
  v_member_ids uuid[];
  v_member_count integer;
  v_idx integer;
  v_running_target numeric(14, 2) := 0;
  v_running_paid numeric(14, 2) := 0;
  v_share numeric(14, 2);
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id for update;
  if not found then
    raise exception 'not_in_gang';
  end if;
  if v_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  select bank_balance_gram into v_bank_balance from gangs where id = v_gang_id for update;

  if v_bank_balance > 0 then
    v_season_id := active_season_id();
    if v_season_id is null then
      raise exception 'no_active_season';
    end if;

    -- FOR UPDATE can't sit directly on an aggregate query — lock the rows
    -- in an inner subquery first, then aggregate the (now-locked) result.
    select array_agg(user_id order by joined_at) into v_member_ids
    from (select user_id, joined_at from gang_members where gang_id = v_gang_id for update) locked_members;
    v_member_count := coalesce(array_length(v_member_ids, 1), 0);

    select coalesce((config->>'starting_balance')::numeric, 0)
    into v_season_starting_balance
    from seasons where id = v_season_id;

    for v_idx in 1..v_member_count loop
      v_running_target := round(v_bank_balance * v_idx / v_member_count, 2);
      v_share := v_running_target - v_running_paid;
      v_running_paid := v_running_target;

      insert into user_seasons (user_id, season_id, balance, total_earned)
      values (v_member_ids[v_idx], v_season_id, v_season_starting_balance, v_season_starting_balance)
      on conflict (user_id, season_id) do nothing;

      update user_seasons set balance = balance + v_share
      where user_id = v_member_ids[v_idx] and season_id = v_season_id;
    end loop;
  end if;

  delete from gangs where id = v_gang_id;

  return jsonb_build_object('disbanded', true, 'bank_distributed', coalesce(v_bank_balance, 0));
end;
$$;

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
  v_member_ids uuid[];
  v_member_count integer;
  v_idx integer;
  v_running_target numeric(14, 2) := 0;
  v_running_paid numeric(14, 2) := 0;
  v_share numeric(14, 2);
  v_updated_rows integer;
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

  -- Locked and materialized once — the split (member_count) and the set
  -- actually paid (the loop below) now always agree, even if someone
  -- leaves/gets kicked in between; their gang_members row is locked here
  -- for the rest of this transaction either way, so leave_gang/
  -- kick_gang_member simply wait for this call to finish rather than
  -- silently changing who gets paid mid-distribution (see header).
  -- FOR UPDATE can't sit directly on an aggregate query — lock the rows
  -- in an inner subquery first, then aggregate the (now-locked) result.
  select array_agg(user_id order by joined_at) into v_member_ids
  from (select user_id, joined_at from gang_members where gang_id = v_gang_id for update) locked_members;
  v_member_count := coalesce(array_length(v_member_ids, 1), 0);

  select coalesce((config->>'starting_balance')::numeric, 0)
  into v_season_starting_balance
  from seasons where id = v_season_id;

  for v_idx in 1..v_member_count loop
    v_running_target := round(p_amount * v_idx / v_member_count, 2);
    v_share := v_running_target - v_running_paid;
    v_running_paid := v_running_target;

    insert into user_seasons (user_id, season_id, balance, total_earned)
    values (v_member_ids[v_idx], v_season_id, v_season_starting_balance, v_season_starting_balance)
    on conflict (user_id, season_id) do nothing;

    update user_seasons set balance = balance + v_share
    where user_id = v_member_ids[v_idx] and season_id = v_season_id;
  end loop;

  update gangs
  set bank_balance_gram = bank_balance_gram - p_amount,
      bank_balance_ton = bank_balance_ton - p_amount
  where id = v_gang_id;
  get diagnostics v_updated_rows = row_count;
  if v_updated_rows = 0 then
    raise exception 'gang_not_found';
  end if;

  return jsonb_build_object(
    'gang_id', v_gang_id,
    'amount', p_amount,
    'member_count', v_member_count,
    'bank_balance_gram', v_bank_balance - p_amount
  );
end;
$$;

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
  v_updated_rows integer;
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
  get diagnostics v_updated_rows = row_count;
  if v_updated_rows = 0 then
    -- The gang was disbanded in the same instant as this donation (its
    -- gang_members row, read above, cascaded away with it) — raising
    -- here rolls back the balance deduction too, so the donor is never
    -- charged for a donation that landed nowhere.
    raise exception 'gang_not_found';
  end if;

  insert into gang_bank_transactions (gang_id, from_user_id, amount_gram, amount_ton)
  values (v_gang_id, p_user_id, p_amount, p_amount);

  return jsonb_build_object('gang_id', v_gang_id, 'amount', p_amount, 'balance', v_balance - p_amount);
end;
$$;
