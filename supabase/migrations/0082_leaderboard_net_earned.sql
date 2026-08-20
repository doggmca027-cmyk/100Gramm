-- get_leaderboard's 'total_earned' metric currently returns
-- user_seasons.total_earned as-is, which is gross, not net: claim_cycle
-- (and every version of it across migrations 0002 onward) credits the
-- cycle's full amount_out — principal (amount_in) plus payout_percent
-- profit — onto total_earned, never subtracting amount_in anywhere. So a
-- 1 TON cycle at 15% shows up on the leaderboard as +1.15, not the +0.15
-- the player actually profited.
--
-- Per the 2026-08-20 product decision: the leaderboard should rank and
-- display *net* income — cycle profit only (amount_out - amount_in on
-- claimed cycles), leaving referral/quest/task/combo/bank rewards alone
-- since those were never principal-inflated to begin with (nothing was
-- spent to receive them, unlike a cycle). That's exactly
-- total_earned minus the sum of amount_in over that user's *claimed*
-- cycles this season — running (unclaimed) cycles never contributed
-- their amount_out to total_earned yet, so there's nothing of theirs to
-- subtract until they're claimed.
--
-- Deliberately scoped to *this RPC's output only* — user_seasons.total_earned
-- itself is left untouched, since balance-screen.tsx, player-profile-card.tsx,
-- and every claim_cycle/reconciliation RPC still rely on it meaning gross
-- lifetime earnings. Only the leaderboard's already-existing 'total_earned'
-- JSON field changes meaning (to net) and value — no frontend change needed,
-- LeaderboardEntry.total_earned just now holds a smaller, net number.
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
      coalesce(us.total_earned, 0) - coalesce(cn.claimed_amount_in, 0) as total_earned,
      coalesce(us.completed_cycles_total, 0) as completed_cycles_total,
      coalesce(cc.cycles_launched_total, 0) as cycles_launched_total
    from users u
    left join user_seasons us on us.user_id = u.id and us.season_id = v_season_id
    left join (
      select user_id, count(*) as cycles_launched_total
      from cycles
      group by user_id
    ) cc on cc.user_id = u.id
    left join (
      select user_id, sum(amount_in) as claimed_amount_in
      from cycles
      where season_id = v_season_id and status = 'claimed'
      group by user_id
    ) cn on cn.user_id = u.id
    where not u.hide_from_leaderboard
      and (us.user_id is not null or cc.cycles_launched_total > 0)
    order by
      case when p_metric = 'completed_cycles_total' then us.completed_cycles_total end desc nulls last,
      case when p_metric = 'cycles_launched_total' then cc.cycles_launched_total end desc nulls last,
      case when p_metric not in ('completed_cycles_total', 'cycles_launched_total')
        then coalesce(us.total_earned, 0) - coalesce(cn.claimed_amount_in, 0)
      end desc nulls last
    limit greatest(p_limit, 1)
  ) t;

  return v_result;
end;
$function$
;
