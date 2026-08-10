-- Gangs launch at max_members = 10 (0060_gang_max_members_10.sql) with no
-- way to grow past it. This adds a leader-only purchase: +5 member slots
-- for 1 GRAM ("1 TON", same GRAM-is-TON economy every other gang cost uses
-- — see create_gang's header in 0058_gangs.sql), paid from the gang's own
-- bank (bank_balance_gram/bank_balance_ton) rather than the leader's
-- personal balance — the first real sink for a bank that, until now, only
-- ever filled up (automatic 10% cycle cut + the manual donate_to_gang_bank
-- from 0061) and never spent anything. No cap on how many times a gang can
-- buy more room — repeatable indefinitely, same "no upper bound" posture
-- as e.g. buying more cycle slots on a maxed-out tier.
--
-- Deliberately does NOT insert a gang_bank_transactions row: that table's
-- sum-per-donor logic (bank_top_donors in get_player_state) assumes every
-- row is money coming IN from a member: a negative-amount "spend" row
-- there would silently misattribute the purchase as a donation and skew
-- the donor leaderboard. This is a separate ledger event, tracked only as
-- a balance decrease on the gangs row itself.
create or replace function upgrade_gang_capacity(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cost constant numeric := 1;
  v_slots_per_purchase constant integer := 5;
  v_gang_id uuid;
  v_role text;
  v_bank_balance numeric(14, 2);
  v_new_max integer;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  select bank_balance_gram into v_bank_balance
  from gangs where id = v_gang_id for update;

  if v_bank_balance < v_cost then
    raise exception 'insufficient_gang_bank';
  end if;

  update gangs
  set bank_balance_gram = bank_balance_gram - v_cost,
      bank_balance_ton = bank_balance_ton - v_cost,
      max_members = max_members + v_slots_per_purchase
  where id = v_gang_id
  returning max_members into v_new_max;

  return jsonb_build_object(
    'gang_id', v_gang_id,
    'max_members', v_new_max,
    'bank_balance_gram', v_bank_balance - v_cost
  );
end;
$$;
