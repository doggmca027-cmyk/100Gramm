-- 100ГРАМ: Squad screen — per-level referral breakdown ("1 линия / 2 линия /
-- 3 линия"), each with participant count, total invested (deposits) by that
-- level, GRAM earned from that level this season, and the list of players
-- who joined through the chain, most recent first.
--
-- get_player_state's existing 'squad' object stays as-is (referred_count is
-- level-1-only, earned_total is all-levels-combined) — this is a separate,
-- on-demand call from the Squad screen's level tabs, not folded into every
-- /api/state poll, for the same reason process_auto_collect_cycles was
-- throttled in 0035: get_player_state already runs on a tight poll loop for
-- every active user, and a 3-level tree walk + per-member cycle/earnings
-- lookups is real work that most of those polls have no use for.
--
-- referred_by had no index at all before this — get_player_state's own
-- 'referrals_level_1' progress count and this new function both filter on
-- it, so it was a sequential scan of the whole users table on every call.
create index if not exists users_referred_by_idx on users (referred_by);

create or replace function get_squad_levels(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_is_ambassador boolean;
  v_result jsonb;
  v_list_cap constant integer := 300;
begin
  v_season_id := active_season_id();
  if v_season_id is null then
    return '[]'::jsonb;
  end if;

  select coalesce(is_ambassador, false) into v_is_ambassador
  from users where id = p_user_id;

  with level1 as (
    select id from users where referred_by = p_user_id
  ),
  level2 as (
    select u.id from users u
    where u.referred_by in (select id from level1) and u.id <> p_user_id
  ),
  level3 as (
    select u.id from users u
    where u.referred_by in (select id from level2) and u.id <> p_user_id
  ),
  members as (
    select 1::smallint as level, id from level1
    union all
    select 2::smallint, id from level2
    union all
    select 3::smallint, id from level3
  ),
  member_stats as (
    select
      m.level,
      m.id as user_id,
      u.username,
      u.first_name,
      u.photo_url,
      u.created_at as joined_at,
      coalesce((
        select sum(c.amount_in) from cycles c
        where c.user_id = m.id and c.season_id = v_season_id
      ), 0) as deposited,
      coalesce((
        select sum(re.amount) from referral_earnings re
        where re.beneficiary_id = p_user_id and re.source_user_id = m.id
          and re.level = m.level and re.season_id = v_season_id
      ), 0) as earned_from
    from members m
    join users u on u.id = m.id
  ),
  member_ranked as (
    select *, row_number() over (partition by level order by joined_at desc) as rn
    from member_stats
  ),
  level_summary as (
    select
      level,
      count(*) as referred_count,
      coalesce(sum(deposited), 0) as total_deposits,
      coalesce(sum(earned_from), 0) as earned_total
    from member_stats
    group by level
  ),
  level_lists as (
    select
      level,
      jsonb_agg(jsonb_build_object(
        'user_id', user_id,
        'display_name', coalesce(username, first_name, 'Игрок'),
        'photo_url', photo_url,
        'joined_at', joined_at,
        'total_deposited', deposited,
        'earned_from', earned_from
      ) order by joined_at desc) as referrals
    from member_ranked
    where rn <= v_list_cap
    group by level
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'level', gs.lvl,
    'percent', case when v_is_ambassador then (array[8, 5, 3])[gs.lvl] else (array[5, 3, 1])[gs.lvl] end,
    'referred_count', coalesce(ls.referred_count, 0),
    'total_deposits', coalesce(ls.total_deposits, 0),
    'earned_total', coalesce(ls.earned_total, 0),
    'referrals', coalesce(ll.referrals, '[]'::jsonb),
    'truncated', coalesce(ls.referred_count, 0) > v_list_cap
  ) order by gs.lvl), '[]'::jsonb)
  into v_result
  from generate_series(1, 3) as gs(lvl)
  left join level_summary ls on ls.level = gs.lvl
  left join level_lists ll on ll.level = gs.lvl;

  return v_result;
end;
$$;
