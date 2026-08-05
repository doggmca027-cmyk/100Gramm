-- 100ГРАМ: real on-chain GRAM shop — pay TON via TON Connect, credit the
-- spendable balance once the payment is verified server-side.
--
-- Unlike wallet_transactions' deposit/withdraw (0019_wallet_transactions.sql,
-- a pure closed-loop simulation), this is real money: a TON transfer to
-- NEXT_PUBLIC_GAME_TREASURY_WALLET. The `tx_hash` unique constraint below is
-- the only thing standing between one on-chain payment and one GRAM credit —
-- it must never be relaxed.

-- ---------------------------------------------------------------------------
-- gram_packs — the purchasable catalog. Source of truth for price/amount on
-- both client (display) and server (verification) so they can never drift;
-- the client never gets to tell the server how much GRAM a payment is worth.
-- ---------------------------------------------------------------------------
create table gram_packs (
  id text primary key,
  title text not null,
  gram_amount numeric(12, 2) not null check (gram_amount > 0),
  price_ton numeric(12, 4) not null check (price_ton > 0),
  is_active boolean not null default true,
  sort_order smallint not null default 0
);

alter table gram_packs enable row level security;

create policy "gram_packs are publicly readable"
  on gram_packs for select
  using (true);

insert into gram_packs (id, title, gram_amount, price_ton, sort_order) values
  ('pack_100', 'Pack 100 GRAM', 100, 0.5, 1),
  ('pack_500', 'Pack 500 GRAM', 500, 2.2, 2);

-- ---------------------------------------------------------------------------
-- wallet_transactions — extended with a 'purchase' type alongside the
-- existing simulated deposit/withdraw, so TON purchases show up in the same
-- history feed (get_history already selects `type` with no filter — no
-- change needed there). tx_hash is unique and NOT NULL only for purchases;
-- it's what makes crediting idempotent against retries/replays.
-- ---------------------------------------------------------------------------
alter table wallet_transactions
  drop constraint wallet_transactions_type_check;

alter table wallet_transactions
  add constraint wallet_transactions_type_check
  check (type in ('deposit', 'withdraw', 'purchase'));

alter table wallet_transactions add column tx_hash text;
alter table wallet_transactions add column pack_id text references gram_packs(id);

-- Partial unique index: only purchases carry a tx_hash, and each on-chain
-- transaction may credit GRAM exactly once.
create unique index wallet_transactions_tx_hash_idx
  on wallet_transactions (tx_hash)
  where tx_hash is not null;

-- ---------------------------------------------------------------------------
-- credit_gram_purchase — called only after the API route has independently
-- verified the on-chain transfer (destination, amount, comment) against
-- TonAPI. p_amount_ton is recorded for the history/audit trail only; the
-- GRAM amount credited always comes from gram_packs, never from the caller.
-- ---------------------------------------------------------------------------
create or replace function credit_gram_purchase(
  p_user_id uuid,
  p_pack_id text,
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
begin
  if p_tx_hash is null or length(p_tx_hash) = 0 then
    raise exception 'invalid_tx_hash';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select gram_amount into v_gram_amount
  from gram_packs
  where id = p_pack_id and is_active;

  if v_gram_amount is null then
    raise exception 'unknown_pack';
  end if;

  -- Insert first: the unique index on tx_hash rejects a second credit for
  -- the same on-chain transaction outright (raises unique_violation, caught
  -- by the API route as tx_already_used), before we ever touch balance.
  insert into wallet_transactions (user_id, season_id, type, amount, fee, net_amount, tx_hash, pack_id)
  values (p_user_id, v_season_id, 'purchase', p_amount_ton, 0, v_gram_amount, p_tx_hash, p_pack_id)
  returning id into v_tx_id;

  update user_seasons set balance = balance + v_gram_amount
  where user_id = p_user_id and season_id = v_season_id;

  if not found then
    raise exception 'no_active_season';
  end if;

  return jsonb_build_object(
    'id', v_tx_id,
    'pack_id', p_pack_id,
    'gram_amount', v_gram_amount,
    'amount_ton', p_amount_ton,
    'tx_hash', p_tx_hash
  );
exception
  when unique_violation then
    raise exception 'tx_already_used';
end;
$$;
