-- 100ГРАМ: replace the pack-based TON shop with a direct 1:1 TON deposit.
--
-- Game concept: GRAM *is* TON — this is the game's branded name for the
-- native coin, not a separate purchasable in-game currency. There's no
-- price list to sell against, so the "buy a pack" flow (0020_gram_shop.sql)
-- is replaced by: connect wallet -> send any TON amount -> credited GRAM
-- 1:1. gram_packs and credit_gram_purchase are left in place (unused) —
-- nothing references them going forward, but dropping tables/functions on
-- a production DB for a UI simplification isn't worth the risk.
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

  -- 1 TON credited = 1 GRAM, by design.
  v_gram_amount := p_amount_ton;

  -- Insert first: the unique index on tx_hash (0020_gram_shop.sql) rejects
  -- a second credit for the same on-chain transaction outright (raises
  -- unique_violation, caught by the API route as tx_already_used), before
  -- we ever touch balance.
  insert into wallet_transactions (user_id, season_id, type, amount, fee, net_amount, tx_hash)
  values (p_user_id, v_season_id, 'purchase', p_amount_ton, 0, v_gram_amount, p_tx_hash)
  returning id into v_tx_id;

  update user_seasons set balance = balance + v_gram_amount
  where user_id = p_user_id and season_id = v_season_id;

  if not found then
    raise exception 'no_active_season';
  end if;

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
