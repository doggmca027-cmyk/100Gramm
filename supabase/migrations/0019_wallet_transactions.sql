-- 100ГРАМ: simulated deposit/withdraw for the GRAM wallet.
--
-- IMPORTANT: this touches only the internal virtual GRAM balance in
-- Supabase. There is no payment gateway, card, crypto wallet or Stars
-- integration anywhere here — "deposit" and "withdraw" are pure in-game
-- balance operations, same spirit as every other GRAM source/sink already
-- in this app (cycles, referrals, quests, combo, boosts). Limits and the
-- withdrawal fee are read from seasons.config, not hardcoded, matching
-- every other economy number in this project.

create table wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  season_id uuid not null references seasons(id) on delete cascade,
  type text not null check (type in ('deposit', 'withdraw')),
  amount numeric(12, 2) not null check (amount > 0),
  fee numeric(12, 2) not null default 0,
  net_amount numeric(12, 2) not null,
  created_at timestamptz not null default now()
);

create index wallet_transactions_user_idx on wallet_transactions (user_id, season_id, created_at desc);

alter table wallet_transactions enable row level security;

update seasons
set config = config || jsonb_build_object(
  'wallet', jsonb_build_object(
    'deposit_min', 1,
    'withdraw_min', 0.5,
    'withdraw_fee_percent', 10
  )
)
where not (config ? 'wallet');

-- ---------------------------------------------------------------------------
-- deposit_gram — simulated top-up: adds to the spendable balance only,
-- never to total_earned (that stat drives rank progress and is earned
-- through gameplay — a free top-up shouldn't buy rank).
-- ---------------------------------------------------------------------------
create or replace function deposit_gram(p_user_id uuid, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_deposit_min numeric;
  v_tx_id uuid;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select coalesce((config->'wallet'->>'deposit_min')::numeric, 1)
  into v_deposit_min
  from seasons where id = v_season_id;

  if p_amount is null or p_amount < v_deposit_min then
    raise exception 'amount_too_low';
  end if;

  update user_seasons set balance = balance + p_amount
  where user_id = p_user_id and season_id = v_season_id;

  if not found then
    raise exception 'no_active_season';
  end if;

  insert into wallet_transactions (user_id, season_id, type, amount, fee, net_amount)
  values (p_user_id, v_season_id, 'deposit', p_amount, 0, p_amount)
  returning id into v_tx_id;

  return jsonb_build_object('id', v_tx_id, 'amount', p_amount, 'fee', 0, 'net_amount', p_amount);
end;
$$;

-- ---------------------------------------------------------------------------
-- withdraw_gram — deducts the full requested amount from balance; fee/net
-- are recorded for display/history only (there's no external destination
-- to actually pay the net amount to — this is a closed-loop simulation).
-- ---------------------------------------------------------------------------
create or replace function withdraw_gram(p_user_id uuid, p_amount numeric)
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
  v_tx_id uuid;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select coalesce((config->'wallet'->>'withdraw_min')::numeric, 1),
         coalesce((config->'wallet'->>'withdraw_fee_percent')::numeric, 10)
  into v_withdraw_min, v_fee_percent
  from seasons where id = v_season_id;

  if p_amount is null or p_amount < v_withdraw_min then
    raise exception 'amount_too_low';
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

  insert into wallet_transactions (user_id, season_id, type, amount, fee, net_amount)
  values (p_user_id, v_season_id, 'withdraw', p_amount, v_fee, v_net)
  returning id into v_tx_id;

  return jsonb_build_object('id', v_tx_id, 'amount', p_amount, 'fee', v_fee, 'net_amount', v_net);
end;
$$;

-- ---------------------------------------------------------------------------
-- get_history — now also surfaces wallet deposits/withdrawals alongside
-- cycle payouts and referral earnings.
-- ---------------------------------------------------------------------------
create or replace function get_history(p_user_id uuid, p_limit integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_result jsonb;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into v_result
  from (
    select * from (
      select 'cycle' as type, tier, amount_out as amount, null::numeric as fee, null::numeric as net_amount, claimed_at as created_at
      from cycles
      where user_id = p_user_id and season_id = v_season_id and status = 'claimed'
      union all
      select 'referral' as type, level as tier, amount, null::numeric, null::numeric, created_at
      from referral_earnings
      where beneficiary_id = p_user_id
      union all
      select type, null::smallint as tier, amount, fee, net_amount, created_at
      from wallet_transactions
      where user_id = p_user_id and season_id = v_season_id
    ) combined
    order by created_at desc
    limit greatest(p_limit, 1)
  ) t;

  return v_result;
end;
$$;
