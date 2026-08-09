-- Unify the deposit and withdraw floors at 1 GRAM.
--
-- deposit_min in seasons.config->wallet was already 1 (seeded that way
-- back in 0021_withdrawal_requests.sql) but unused — the actual deposit
-- floor lives in code as MIN_DEPOSIT_GRAM (src/lib/deposit-config.ts),
-- which this same change bumps 0.5 -> 1 to match. withdraw_min was still
-- 0.5, which *is* live-read by request_withdrawal — bump it to 1 so both
-- directions reject anything under 1 GRAM with the same amount_too_low
-- error the UI already surfaces (see WalletModal's handleWithdraw catch).
update seasons
set config = jsonb_set(config, '{wallet,withdraw_min}', '1', true)
where slug = 'season-1';

-- Defense in depth: request_withdrawal's own coalesce fallback (used only
-- if config->wallet->withdraw_min were ever absent) still said 0.5 — bump
-- it to 1 too so it can't silently reintroduce the old floor. Otherwise
-- byte-for-byte identical to the 0025_automatic_withdrawal_payout.sql
-- version.
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
