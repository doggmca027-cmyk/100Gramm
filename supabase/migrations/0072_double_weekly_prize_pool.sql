-- Doubles the weekly Syndicate leaderboard's prize pool from 100 TON to
-- 200 TON, keeping the same proportional 1st-15th split (every rank's
-- prize simply doubles): 60/36/24/12x2/8x5/3.2x5, still summing to
-- exactly 200.00. Same "GRAM is TON, no real on-chain payment" posture as
-- every other TON figure in this schema (see 0067_syndicate_weekly_
-- leaderboard.sql's header) — only the two v_prizes tables (finalize_
-- weekly_leaderboard_season's payout, get_syndicate_leaderboard's display)
-- and the reported prize_pool_ton change; nothing else about either
-- function's logic is touched.
create or replace function finalize_weekly_leaderboard_season()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period_end timestamptz := weekly_leaderboard_next_reset(now()) - interval '7 days';
  v_period_start timestamptz := weekly_leaderboard_next_reset(now()) - interval '14 days';
  v_last_finalized timestamptz;
  v_prizes numeric(10, 2)[] := array[60, 36, 24, 12, 12, 8, 8, 8, 8, 8, 3.2, 3.2, 3.2, 3.2, 3.2];
  v_gang record;
  v_rank integer := 0;
begin
  perform pg_advisory_xact_lock(hashtext('weekly_leaderboard_finalize'));

  select last_finalized_period_end into v_last_finalized from leaderboard_season_state for update;
  if v_last_finalized is not null and v_last_finalized >= v_period_end then
    return;
  end if;

  for v_gang in
    select id, name, weekly_influence_points
    from gangs
    where weekly_influence_points > 0
    order by weekly_influence_points desc, id asc
    limit 15
  loop
    v_rank := v_rank + 1;

    update gangs
    set bank_balance_gram = bank_balance_gram + v_prizes[v_rank],
        bank_balance_ton = bank_balance_ton + v_prizes[v_rank]
    where id = v_gang.id;

    insert into leaderboard_history (period_start, period_end, gang_id, gang_name, rank, influence_points, prize_ton)
    values (v_period_start, v_period_end, v_gang.id, v_gang.name, v_rank, v_gang.weekly_influence_points, v_prizes[v_rank]);
  end loop;

  update gangs set weekly_influence_points = 0;

  update leaderboard_season_state set last_finalized_period_end = v_period_end;
end;
$$;

create or replace function get_syndicate_leaderboard(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_my_gang_id uuid;
  v_prizes numeric(10, 2)[] := array[60, 36, 24, 12, 12, 8, 8, 8, 8, 8, 3.2, 3.2, 3.2, 3.2, 3.2];
  v_result jsonb;
begin
  select gang_id into v_my_gang_id from gang_members where user_id = p_user_id;

  select jsonb_build_object(
    'next_reset_at', weekly_leaderboard_next_reset(now()),
    'prize_pool_ton', 200,
    'entries', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'rank', ranked.rank,
        'gang_id', ranked.id,
        'name', ranked.name,
        'avatar_id', ranked.avatar_id,
        'premium_avatar_id', ranked.premium_avatar_id,
        'frame_id', ranked.frame_id,
        'member_count', ranked.member_count,
        'weekly_influence_points', ranked.weekly_influence_points,
        'prize_ton', v_prizes[ranked.rank::int],
        'is_mine', ranked.id = v_my_gang_id
      ) order by ranked.rank), '[]'::jsonb)
      from (
        select g.id, g.name, g.avatar_id, g.premium_avatar_id, g.frame_id, g.weekly_influence_points,
          coalesce(mc.member_count, 0) as member_count,
          row_number() over (order by g.weekly_influence_points desc, g.id asc) as rank
        from gangs g
        left join (select gang_id, count(*) as member_count from gang_members group by gang_id) mc on mc.gang_id = g.id
        where g.weekly_influence_points > 0
        order by g.weekly_influence_points desc, g.id asc
        limit 15
      ) ranked
    ),
    'my_gang', (
      select jsonb_build_object(
        'gang_id', g.id,
        'name', g.name,
        'weekly_influence_points', g.weekly_influence_points,
        'rank', case when g.weekly_influence_points > 0 then my_rank.rank else null end,
        'prize_ton', case when g.weekly_influence_points > 0 and my_rank.rank <= 15
          then v_prizes[my_rank.rank::int] else 0 end,
        'my_role', gm.role,
        'target_district_id', g.target_district_id
      )
      from gang_members gm
      join gangs g on g.id = gm.gang_id
      cross join lateral (
        select count(*) + 1 as rank from gangs g2
        where g2.weekly_influence_points > g.weekly_influence_points
           or (g2.weekly_influence_points = g.weekly_influence_points and g2.id < g.id)
      ) my_rank
      where gm.user_id = p_user_id
    )
  ) into v_result;

  return v_result;
end;
$$;
