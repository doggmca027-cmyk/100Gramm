-- 100ГРАМ: surface each player's Telegram photo in the leaderboard, for the
-- podium-style redesign (top-3 avatars + ranked list below). Purely
-- additive to get_leaderboard's payload — no new mechanic, no payouts.
create or replace function get_leaderboard(p_metric text default 'total_earned', p_limit integer default 50)
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
    select
      coalesce(u.username, u.first_name, 'Игрок') as display_name,
      u.photo_url,
      us.total_earned,
      us.completed_cycles_total
    from user_seasons us
    join users u on u.id = us.user_id
    where us.season_id = v_season_id
    order by
      case when p_metric = 'completed_cycles_total' then us.completed_cycles_total end desc,
      case when p_metric <> 'completed_cycles_total' then us.total_earned end desc
    limit greatest(p_limit, 1)
  ) t;

  return v_result;
end;
$$;
