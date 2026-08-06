-- 100ГРАМ: manual TON deposits get the same passive background sweep USDT
-- already has (0032_usdt_manual_deposits.sql) — the wallet modal's GRAM tab
-- now shows treasury address + memo requisites alongside the existing TON
-- Connect flow, for players sending from a wallet/exchange that was never
-- TON Connect-paired. credit_ton_deposit (0024_ton_deposit_1to1.sql)
-- already accepts an arbitrary amount + tx_hash, so the sweep needs no new
-- crediting RPC — just a way to find "recent inbound transfers nobody's
-- credited yet", same as lib/usdt-deposit-sweep.ts.
--
-- usdt_deposit_sweep_state was a singleton scoped to exactly one sweep
-- kind; replaced with a generic table keyed by `kind` so TON and USDT
-- sweeps each get their own throttle slot without duplicating the table.

drop function if exists try_claim_usdt_sweep_slot(integer);
drop table if exists usdt_deposit_sweep_state;

create table deposit_sweep_state (
  kind text primary key,
  last_swept_at timestamptz not null default '-infinity'
);

insert into deposit_sweep_state (kind) values ('ton'), ('usdt');

alter table deposit_sweep_state enable row level security;

create or replace function try_claim_deposit_sweep_slot(p_kind text, p_min_interval_seconds integer default 30)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows integer;
begin
  update deposit_sweep_state
  set last_swept_at = now()
  where kind = p_kind and last_swept_at < now() - (p_min_interval_seconds::text || ' seconds')::interval;

  get diagnostics v_rows = row_count;
  return v_rows > 0;
end;
$$;
