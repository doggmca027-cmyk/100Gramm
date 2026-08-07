-- Adds a second leaderboard metric: total cycles *launched* (started),
-- all-time, across every season — distinct from the existing
-- 'completed_cycles_total' metric, which is (a) scoped to the active
-- season only and (b) actually counts completed_cycles_total from
-- user_seasons, a counter that's only incremented when a cycle is
-- claimed, not when it's started. "Launched" means every row in `cycles`
-- ever created for that user regardless of status ('running' or
-- 'claimed') or season — exactly what a plain `count(*)` over the table
-- gives, no separate counter to maintain.
--
-- Switched the base table from `user_seasons` (inner join) to `users`
-- (left join) so a user with cycle history from a past season, or no row
-- in the *current* season yet, still shows up on the cycles-launched
-- leaderboard. Every registered user gets a user_seasons row for the
-- active season at auth time (see upsert_telegram_user across several
-- migrations), so this is a no-op for the existing two metrics — same
-- rows, same order, just resilient to the edge case instead of silently
-- excluding it.
CREATE OR REPLACE FUNCTION public.get_leaderboard(p_metric text DEFAULT 'total_earned'::text, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      coalesce(us.total_earned, 0) as total_earned,
      coalesce(us.completed_cycles_total, 0) as completed_cycles_total,
      coalesce(cc.cycles_launched_total, 0) as cycles_launched_total
    from users u
    left join user_seasons us on us.user_id = u.id and us.season_id = v_season_id
    left join (
      select user_id, count(*) as cycles_launched_total
      from cycles
      group by user_id
    ) cc on cc.user_id = u.id
    where not u.hide_from_leaderboard
      and (us.user_id is not null or cc.cycles_launched_total > 0)
    order by
      case when p_metric = 'completed_cycles_total' then us.completed_cycles_total end desc nulls last,
      case when p_metric = 'cycles_launched_total' then cc.cycles_launched_total end desc nulls last,
      case when p_metric not in ('completed_cycles_total', 'cycles_launched_total') then us.total_earned end desc nulls last
    limit greatest(p_limit, 1)
  ) t;

  return v_result;
end;
$function$
;
