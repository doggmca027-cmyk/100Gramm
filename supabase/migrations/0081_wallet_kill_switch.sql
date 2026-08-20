-- Emergency kill switch for deposits and withdrawals — added while the
-- economy is being reworked (balances were just reset to "amount not yet
-- recouped" for every real-money player) so no new TON/USDT can come in
-- and no GRAM can go out mid-change, without needing an app deploy: these
-- three SECURITY DEFINER functions are the *only* path real money ever
-- moves through (credit_ton_deposit / credit_usdt_payment credit GRAM for
-- an on-chain transfer, request_withdrawal escrows GRAM against a payout
-- request), so gating them here is authoritative the moment this migration
-- lands, regardless of what the deployed Next.js app still thinks.
--
-- Both flags default true (nothing changes for any other season), and are
-- flipped off for the current season as part of this same migration. Flip
-- them back with:
--   update seasons set config = jsonb_set(jsonb_set(config, '{wallet,deposits_enabled}', 'true'), '{wallet,withdrawals_enabled}', 'true');

update seasons
set config = jsonb_set(
  jsonb_set(config, '{wallet,deposits_enabled}', 'false', true),
  '{wallet,withdrawals_enabled}', 'false', true
);

-- ---------------------------------------------------------------------------
-- credit_ton_deposit — unchanged except for the leading deposits_enabled
-- check. Byte-for-byte identical otherwise to the 0058_gangs.sql version.
-- ---------------------------------------------------------------------------
create or replace function credit_ton_deposit(
  p_user_id uuid,
  p_tx_hash text,
  p_amount_ton numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_gram_amount numeric(12, 2);
  v_tx_id uuid;
  v_deposits_enabled boolean;
begin
  if p_tx_hash is null or length(p_tx_hash) = 0 then
    raise exception 'invalid_tx_hash';
  end if;

  if p_amount_ton is null or p_amount_ton <= 0 then
    raise exception 'amount_too_low';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select coalesce((config->'wallet'->>'deposits_enabled')::boolean, true)
  into v_deposits_enabled
  from seasons where id = v_season_id;

  if not v_deposits_enabled then
    raise exception 'deposits_disabled';
  end if;

  v_gram_amount := p_amount_ton;

  insert into wallet_transactions (user_id, season_id, type, amount, fee, net_amount, tx_hash)
  values (p_user_id, v_season_id, 'purchase', p_amount_ton, 0, v_gram_amount, p_tx_hash)
  returning id into v_tx_id;

  update user_seasons set balance = balance + v_gram_amount
  where user_id = p_user_id and season_id = v_season_id;

  if not found then
    raise exception 'no_active_season';
  end if;

  perform distribute_deposit_referral_bonuses(p_user_id, v_gram_amount);

  return jsonb_build_object(
    'id', v_tx_id,
    'gram_amount', v_gram_amount,
    'amount_ton', p_amount_ton,
    'tx_hash', p_tx_hash
  );
exception
  when unique_violation then
    raise exception 'tx_already_used';
end;
$$;

-- ---------------------------------------------------------------------------
-- credit_usdt_payment — same deposits_enabled gate. Byte-for-byte identical
-- otherwise to the 0058_gangs.sql version.
-- ---------------------------------------------------------------------------
create or replace function credit_usdt_payment(
  p_user_id uuid,
  p_tx_hash text,
  p_usdt_amount numeric,
  p_gram_amount numeric,
  p_quote_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_tx_id uuid;
  v_deposits_enabled boolean;
begin
  if p_tx_hash is null or length(p_tx_hash) = 0 then
    raise exception 'invalid_tx_hash';
  end if;

  if p_gram_amount is null or p_gram_amount <= 0 then
    raise exception 'amount_too_low';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select coalesce((config->'wallet'->>'deposits_enabled')::boolean, true)
  into v_deposits_enabled
  from seasons where id = v_season_id;

  if not v_deposits_enabled then
    raise exception 'deposits_disabled';
  end if;

  insert into wallet_transactions (user_id, season_id, type, amount, fee, net_amount, tx_hash)
  values (p_user_id, v_season_id, 'purchase', p_usdt_amount, 0, p_gram_amount, p_tx_hash)
  returning id into v_tx_id;

  update user_seasons set balance = balance + p_gram_amount
  where user_id = p_user_id and season_id = v_season_id;

  if not found then
    raise exception 'no_active_season';
  end if;

  if p_quote_id is not null then
    update usdt_payment_quotes set consumed_at = now()
    where id = p_quote_id and user_id = p_user_id and consumed_at is null;
  end if;

  perform distribute_deposit_referral_bonuses(p_user_id, p_gram_amount);

  return jsonb_build_object(
    'id', v_tx_id,
    'gram_amount', p_gram_amount,
    'usdt_amount', p_usdt_amount,
    'tx_hash', p_tx_hash
  );
exception
  when unique_violation then
    raise exception 'tx_already_used';
end;
$$;

-- ---------------------------------------------------------------------------
-- request_withdrawal — same idea, withdrawals_enabled gate up front, before
-- the payout_address/min-amount checks so a disabled wallet always reports
-- the same reason regardless of what else is wrong with the request. Byte-
-- for-byte identical otherwise to the 0052_unify_min_deposit_withdraw.sql
-- version.
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
  v_withdrawals_enabled boolean;
  v_balance numeric(14, 2);
  v_fee numeric(12, 2);
  v_net numeric(12, 2);
  v_request_id uuid;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select coalesce((config->'wallet'->>'withdrawals_enabled')::boolean, true)
  into v_withdrawals_enabled
  from seasons where id = v_season_id;

  if not v_withdrawals_enabled then
    raise exception 'withdrawals_disabled';
  end if;

  if p_payout_address is null or length(trim(p_payout_address)) = 0 then
    raise exception 'payout_address_missing';
  end if;

  select coalesce((config->'wallet'->>'withdraw_min')::numeric, 1),
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
