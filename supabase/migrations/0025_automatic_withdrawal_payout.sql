-- 100ГРАМ: automatic on-chain payout for approved withdrawals. The admin
-- approve button now actually sends TON from the treasury hot wallet
-- (server-signed with a mnemonic — see src/lib/ton-wallet-sender.ts)
-- instead of only bookkeeping the approval.
--
-- Payout destination: the address the player had connected via TON Connect
-- at the moment they filed the withdrawal request (captured client-side,
-- required from here on — see request_withdrawal below).
--
-- New 'processing' status is a mutex, not just a label: lock_withdrawal_for_payout()
-- atomically flips pending -> processing, so two concurrent admin clicks
-- (or a retry racing the original) can't both trigger a send for the same
-- request — the second one simply finds no 'pending' row left to lock.
alter table withdrawal_requests
  drop constraint withdrawal_requests_status_check;

alter table withdrawal_requests
  add constraint withdrawal_requests_status_check
  check (status in ('pending', 'processing', 'approved', 'rejected'));

alter table withdrawal_requests add column payout_address text;
alter table withdrawal_requests add column payout_tx_hash text;

-- Replace the "one active request per player" index so it also covers the
-- new 'processing' status — otherwise a request mid-payout wouldn't block
-- a second one from being filed.
drop index withdrawal_requests_one_pending_idx;
create unique index withdrawal_requests_one_pending_idx
  on withdrawal_requests (user_id, season_id)
  where status in ('pending', 'processing');

-- ---------------------------------------------------------------------------
-- request_withdrawal — now requires the payout address up front (the
-- connected TON Connect wallet at request time). Same escrow behavior as
-- before, otherwise unchanged.
-- ---------------------------------------------------------------------------
create or replace function request_withdrawal(p_user_id uuid, p_amount numeric, p_payout_address text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_withdraw_min numeric;
  v_fee_percent numeric;
  v_balance numeric(14, 2);
  v_fee numeric(12, 2);
  v_net numeric(12, 2);
  v_request_id uuid;
begin
  if p_payout_address is null or length(trim(p_payout_address)) = 0 then
    raise exception 'payout_address_missing';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select coalesce((config->'wallet'->>'withdraw_min')::numeric, 0.5),
         coalesce((config->'wallet'->>'withdraw_fee_percent')::numeric, 15)
  into v_withdraw_min, v_fee_percent
  from seasons where id = v_season_id;

  if p_amount is null or p_amount < v_withdraw_min then
    raise exception 'amount_too_low';
  end if;

  if exists (
    select 1 from withdrawal_requests
    where user_id = p_user_id and season_id = v_season_id and status in ('pending', 'processing')
  ) then
    raise exception 'withdrawal_already_pending';
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

  v_fee := round(p_amount * v_fee_percent / 100, 2);
  v_net := p_amount - v_fee;

  update user_seasons set balance = balance - p_amount
  where user_id = p_user_id and season_id = v_season_id;

  insert into withdrawal_requests (user_id, season_id, amount, fee, net_amount, payout_address)
  values (p_user_id, v_season_id, p_amount, v_fee, v_net, trim(p_payout_address))
  returning id into v_request_id;

  return jsonb_build_object(
    'id', v_request_id, 'amount', p_amount, 'fee', v_fee, 'net_amount', v_net, 'status', 'pending'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- lock_withdrawal_for_payout — the mutex step. Called by the admin route
-- before it ever touches the treasury wallet. Returns the row (payout
-- address + net amount) the caller needs to actually send TON.
-- ---------------------------------------------------------------------------
create or replace function lock_withdrawal_for_payout(p_request_id uuid, p_admin_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request withdrawal_requests%rowtype;
begin
  update withdrawal_requests
  set status = 'processing', resolved_by = p_admin_user_id
  where id = p_request_id and status = 'pending'
  returning * into v_request;

  if not found then
    raise exception 'request_not_found';
  end if;

  if v_request.payout_address is null then
    -- Legacy request filed before payout addresses existed — revert the
    -- lock immediately and let the caller surface a clear error instead of
    -- silently failing the send.
    update withdrawal_requests set status = 'pending', resolved_by = null where id = p_request_id;
    raise exception 'payout_address_missing';
  end if;

  return jsonb_build_object(
    'id', v_request.id,
    'user_id', v_request.user_id,
    'payout_address', v_request.payout_address,
    'net_amount', v_request.net_amount
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- revert_withdrawal_processing — used only when the on-chain send itself
-- fails (network error, treasury out of funds, etc.) after locking. Puts
-- the request back to 'pending' so the admin can see the failure and retry
-- rather than it being stuck forever in 'processing'.
-- ---------------------------------------------------------------------------
create or replace function revert_withdrawal_processing(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update withdrawal_requests
  set status = 'pending', resolved_by = null
  where id = p_request_id and status = 'processing';
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_withdrawal_request — approve now only ever runs after a
-- successful lock + on-chain send (status must be 'processing'), and
-- records the payout's own transaction hash. Reject can act on a request
-- that's merely 'pending' (never attempted) or 'processing' (admin backed
-- out before the treasury send — see the API route).
-- ---------------------------------------------------------------------------
create or replace function resolve_withdrawal_request(
  p_request_id uuid,
  p_admin_user_id uuid,
  p_approve boolean,
  p_admin_note text default null,
  p_payout_tx_hash text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request withdrawal_requests%rowtype;
begin
  -- Approve must have gone through lock_withdrawal_for_payout() (status =
  -- 'processing') first — that's what proves a send was actually
  -- attempted. Reject can act on a request that never got that far
  -- ('pending') or one the admin backed out of after locking ('processing').
  if p_approve then
    select * into v_request from withdrawal_requests
    where id = p_request_id and status = 'processing'
    for update;
  else
    select * into v_request from withdrawal_requests
    where id = p_request_id and status in ('pending', 'processing')
    for update;
  end if;

  if not found then
    raise exception 'request_not_found';
  end if;

  if p_approve then
    update withdrawal_requests
    set status = 'approved', resolved_at = now(), resolved_by = p_admin_user_id,
        admin_note = p_admin_note, payout_tx_hash = p_payout_tx_hash
    where id = p_request_id;

    insert into wallet_transactions (user_id, season_id, type, amount, fee, net_amount, tx_hash)
    values (v_request.user_id, v_request.season_id, 'withdraw', v_request.amount, v_request.fee, v_request.net_amount, p_payout_tx_hash);
  else
    update withdrawal_requests
    set status = 'rejected', resolved_at = now(), resolved_by = p_admin_user_id, admin_note = p_admin_note
    where id = p_request_id;

    update user_seasons set balance = balance + v_request.amount
    where user_id = v_request.user_id and season_id = v_request.season_id;
  end if;

  return jsonb_build_object(
    'id', v_request.id,
    'status', case when p_approve then 'approved' else 'rejected' end
  );
end;
$$;
