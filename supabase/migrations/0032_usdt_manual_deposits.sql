-- 100ГРАМ: fixes + extends the USDT payment path from 0031_gram_usdt_rate.sql.
--
-- Bug fix — locked quotes: the original /api/wallet/usdt-payment/verify
-- re-fetched the live GRAM/USDT rate at *verify* time to compute the
-- matching floor, instead of using the rate that was actually quoted at
-- *prepare* time. If the wallet approval took long enough for the 60s rate
-- cache to roll over, a fully honest payment could be rejected as
-- underpaid even though the buyer sent exactly what they were quoted. Spec
-- explicitly wants "курс, актуальный на момент создания транзакции" — this
-- table is what actually locks that in, instead of re-deriving it.
--
-- New feature — manual USDT deposits: unlike the direct-cycle-purchase
-- flow (a prompted, TonConnect-signed Jetton transfer for a known amount),
-- a manual deposit can arrive from *any* wallet or exchange the player
-- pastes the treasury address + memo into — there's nothing to "quote" in
-- advance, and no client-side sendTransaction call to hang a verify step
-- off of. usdt_deposit_sweep_state exists purely to throttle the
-- background scan (lib/usdt-deposit-sweep.ts) that watches for these.

-- ---------------------------------------------------------------------------
-- usdt_payment_quotes — locks in gram_amount/usdt_amount/rate at prepare
-- time. verify/route.ts reads the quote back by id (never trusting a
-- client-supplied amount) to compute both the on-chain matching floor and
-- the GRAM amount to credit — closes a real spoofing gap the previous
-- design had (a client could otherwise claim any gramAmount/usdtAmount
-- pairing it wanted).
-- ---------------------------------------------------------------------------
create table usdt_payment_quotes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  comment text not null,
  gram_amount numeric(12, 2) not null check (gram_amount > 0),
  usdt_amount numeric(14, 6) not null check (usdt_amount > 0),
  rate numeric(12, 6) not null check (rate > 0),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz
);

create index usdt_payment_quotes_lookup_idx on usdt_payment_quotes (user_id, id);

alter table usdt_payment_quotes enable row level security;

create or replace function create_usdt_payment_quote(
  p_user_id uuid,
  p_comment text,
  p_gram_amount numeric,
  p_usdt_amount numeric,
  p_rate numeric,
  p_ttl_seconds integer default 600
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_gram_amount is null or p_gram_amount <= 0 then
    raise exception 'amount_too_low';
  end if;

  insert into usdt_payment_quotes (user_id, comment, gram_amount, usdt_amount, rate, expires_at)
  values (p_user_id, p_comment, p_gram_amount, p_usdt_amount, p_rate, now() + (p_ttl_seconds::text || ' seconds')::interval)
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- credit_usdt_payment — now also accepts an optional quote to consume
-- atomically alongside the credit, so a finished quote can never be
-- matched against a second, unrelated later transfer with the same
-- comment. p_quote_id is null for the passive deposit sweep (nothing was
-- quoted in advance there — see usdt-deposit-sweep.ts). Postgres won't let
-- CREATE OR REPLACE add a parameter in the middle, so this is dropped and
-- recreated with the new trailing optional arg; call sites using the old
-- 4-arg signature keep working unchanged.
-- ---------------------------------------------------------------------------
drop function if exists credit_usdt_payment(uuid, text, numeric, numeric);

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

  -- Insert first: the unique index on tx_hash (0020_gram_shop.sql) rejects a
  -- second credit for the same on-chain event outright, before balance is
  -- ever touched — identical guard to credit_ton_deposit.
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
-- usdt_deposit_sweep_state — singleton row throttling the background
-- deposit scan to at most once per p_min_interval_seconds, so a burst of
-- concurrent /api/state calls doesn't all hit TonAPI at once. Same
-- "atomic UPDATE ... WHERE claims the slot" idiom as everywhere else in
-- this schema — no separate advisory lock needed.
-- ---------------------------------------------------------------------------
create table usdt_deposit_sweep_state (
  id smallint primary key default 1 check (id = 1),
  last_swept_at timestamptz not null default '-infinity'
);

insert into usdt_deposit_sweep_state (id, last_swept_at) values (1, '-infinity');

alter table usdt_deposit_sweep_state enable row level security;

create or replace function try_claim_usdt_sweep_slot(p_min_interval_seconds integer default 30)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows integer;
begin
  update usdt_deposit_sweep_state
  set last_swept_at = now()
  where id = 1 and last_swept_at < now() - (p_min_interval_seconds::text || ' seconds')::interval;

  get diagnostics v_rows = row_count;
  return v_rows > 0;
end;
$$;
