-- Requested 2026-08-20: stop every currently-running cycle for every
-- user, refunding the principal (amount_in) to balance with no profit,
-- and expire every active/pending boost. One-time admin action, not a
-- config change.
--
-- Cycles never touch gang bank/XP, district points, or referral bonuses
-- until they're actually CLAIMED (see resolve_due_cycles) — since every
-- affected row here is still 'running', none of those ever fired for
-- them, so there's nothing to unwind beyond the refund itself.
--
-- Deliberately does NOT increment total_earned, completed_cycles_total,
-- or user_tier_progress.completed_cycles — this is a cancellation, not a
-- completion, so it must not count toward earnings or tier-unlock
-- progress. amount_out is still stamped (= amount_in) purely as a paper
-- trail of what was refunded.
--
-- 'cancelled' didn't exist as a cycles.status value before this — widening
-- the check constraint rather than reusing 'claimed', so a cancelled
-- cycle is never mistaken for (or counted by) anything that filters on
-- status = 'claimed', including get_leaderboard's net-earnings calc
-- (0082_leaderboard_net_earned.sql) and resolve_due_cycles itself.
alter table cycles drop constraint cycles_status_check;
alter table cycles add constraint cycles_status_check
  check (status in ('running', 'claimed', 'cancelled'));

-- Refund principal, grouped per (user, season) to collapse multiple
-- running cycles into one balance update each.
update user_seasons us
set balance = us.balance + refund.total_amount_in
from (
  select user_id, season_id, sum(amount_in) as total_amount_in
  from cycles
  where status = 'running'
  group by user_id, season_id
) refund
where us.user_id = refund.user_id and us.season_id = refund.season_id;

update cycles
set status = 'cancelled', claimed_at = now(), amount_out = amount_in
where status = 'running';

-- Boosts are never GRAM-purchased (quest/task/combo rewards only), so
-- nothing to refund — just deactivate. slots_boost (get_player_state)
-- only counts status = 'ACTIVE' boosts, so this immediately drops any
-- extra-slot bonus currently in effect.
update user_boosts
set status = 'EXPIRED'
where status in ('PENDING', 'ACTIVE');
