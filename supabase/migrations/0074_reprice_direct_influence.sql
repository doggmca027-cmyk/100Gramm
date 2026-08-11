-- Reprices buy_direct_influence's "Забустить Влияние" purchase: 200
-- Influence Points now cost 5 TON (was 1 TON) — a straight 5x price hike,
-- same 200-points-per-purchase-unit shape, just re-priced.
--   * The points formula drops from `round(p_ton_amount * 200)` to
--     `round(p_ton_amount * 40)`, so 5 TON still buys exactly 200 points —
--     same as 1 TON used to — keeping "200 pts" a round, recognizable unit
--     instead of introducing a new fractional one.
--   * The `p_ton_amount < 1` minimum-purchase guard rises to `< 5` in
--     lockstep — the purchase has always had a "buy at least one full
--     unit" floor, and that floor is 5 TON now, not 1.
--   * Everything else about the function (gang bank vs personal balance,
--     the officer-only bank-payment gate, the district-tally routing, the
--     activity-log line) is byte-for-byte unchanged from
--     0071_open_battle_boosts_to_members.sql.
--
-- Alongside the reprice, this migration does a one-time correction for the
-- old 1-TON price already having been live:
--   1. Zeroes gangs.weekly_influence_points for every gang — the current
--      standing was built partly on the old, 5x-cheaper price, so the
--      leaderboard restarts clean under the new price rather than mixing
--      cheap and expensive points in the same weekly total. Same "zero in
--      place" operation finalize_weekly_leaderboard_season() already does
--      on every normal weekly reset.
--   2. Best-effort refunds every buy_direct_influence purchase back to the
--      buyer's personal balance. There is no dedicated ledger of who paid
--      how much (or from where — personal balance vs gang bank) for this
--      purchase; the only trace is gang_activity_log's free-text
--      "💎 <name> закупил(а) <N> очков влияния для Синдиката!" line, added
--      in 0071_open_battle_boosts_to_members.sql — purchases made before
--      that migration shipped left no record at all and can't be refunded
--      here. For every line that does exist: N points implies N/200 TON
--      was paid (the OLD rate, since that's what was live when the
--      purchase happened), refunded unconditionally to the buyer's
--      personal user_seasons.balance regardless of which balance the
--      purchase actually drew from (the gang-bank case can't be
--      distinguished from the text alone) — recorded as a wallet_
--      transactions 'deposit' row so it's visible in the player's own
--      history, same as every other balance credit in this schema.
--      Skipped entirely if there's no active season to credit into.

create or replace function buy_direct_influence(p_user_id uuid, p_ton_amount numeric, p_pay_from_bank boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gang_id uuid;
  v_role text;
  v_season_id uuid;
  v_balance numeric(14, 2);
  v_points bigint;
  v_gang gangs%rowtype;
  v_district districts%rowtype;
  v_battle_date date;
  v_display_name text;
begin
  if p_ton_amount is null or p_ton_amount < 5 then
    raise exception 'amount_too_low';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if p_pay_from_bank and v_role not in ('leader', 'co_leader') then
    raise exception 'bank_payment_officers_only';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  if p_pay_from_bank then
    perform resolve_due_gang_bank_interest(v_gang_id);
    select bank_balance_gram into v_balance from gangs where id = v_gang_id for update;
    if v_balance < p_ton_amount then
      raise exception 'insufficient_gang_bank';
    end if;
    update gangs set bank_balance_gram = bank_balance_gram - p_ton_amount, bank_balance_ton = bank_balance_ton - p_ton_amount
    where id = v_gang_id;
  else
    select balance into v_balance from user_seasons
    where user_id = p_user_id and season_id = v_season_id for update;
    if v_balance is null then
      raise exception 'no_active_season';
    end if;
    if v_balance < p_ton_amount then
      raise exception 'insufficient_balance';
    end if;
    update user_seasons set balance = balance - p_ton_amount
    where user_id = p_user_id and season_id = v_season_id;
  end if;

  v_points := round(p_ton_amount * 40);

  update gangs set weekly_influence_points = weekly_influence_points + v_points
  where id = v_gang_id
  returning * into v_gang;

  if v_gang.target_district_id is not null then
    select * into v_district from districts where id = v_gang.target_district_id;
    if district_battle_status(v_district.window_start_time, v_district.window_end_time) = 'active' then
      v_battle_date := district_battle_date(v_district.window_end_time);
      if v_district.controlling_gang_id = v_gang_id
         or exists (
           select 1 from district_challenges
           where district_id = v_district.id and battle_date = v_battle_date and gang_id = v_gang_id
         ) then
        perform district_apply_points(v_district.id, v_gang_id, v_battle_date, v_points);
      end if;
    end if;
  end if;

  select coalesce(username, first_name, 'Боец') into v_display_name from users where id = p_user_id;
  insert into gang_activity_log (gang_id, user_id, message)
  values (v_gang_id, p_user_id, '💎 ' || v_display_name || ' закупил(а) ' || v_points || ' очков влияния для Синдиката!');

  return jsonb_build_object(
    'gang_id', v_gang_id, 'points_added', v_points, 'weekly_influence_points', v_gang.weekly_influence_points
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- One-time correction: best-effort refund of every buy_direct_influence
-- purchase logged so far, using the OLD rate (200 pts/TON) to recover the
-- TON amount each logged purchase implies. See this migration's header.
-- ---------------------------------------------------------------------------
do $$
declare
  v_season_id uuid := active_season_id();
  v_row record;
  v_points bigint;
  v_ton numeric(12, 2);
begin
  if v_season_id is not null then
    for v_row in
      select id, user_id, message
      from gang_activity_log
      where user_id is not null
        and message like '💎 %закупил(а)%очков влияния для Синдиката!'
    loop
      v_points := nullif(substring(v_row.message from 'закупил\(а\) (\d+) очков'), '')::bigint;
      if v_points is not null and v_points > 0 then
        v_ton := round(v_points / 200.0, 2);

        update user_seasons set balance = balance + v_ton
        where user_id = v_row.user_id and season_id = v_season_id;

        if found then
          insert into wallet_transactions (user_id, season_id, type, amount, fee, net_amount)
          values (v_row.user_id, v_season_id, 'deposit', v_ton, 0, v_ton);
        end if;
      end if;
    end loop;
  end if;
end;
$$;

-- One-time correction: restart the weekly Influence leaderboard clean under
-- the new price, same "zero in place" shape as a normal weekly reset.
update gangs set weekly_influence_points = 0;
