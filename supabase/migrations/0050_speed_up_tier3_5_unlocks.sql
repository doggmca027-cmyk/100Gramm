-- Season-1 pacing tweak: shorten the unlock requirement for tiers 3-5 only.
-- Reminder of the row convention (see 0049_reduce_unlock_cycles.sql): tier
-- T's row stores the requirement to unlock tier T+1, so tier 1's row (reach
-- tier 2) and tiers 5-7's rows (reach tier 6/7/8) are deliberately left
-- alone here — only the reach-tier-3, reach-tier-4 and reach-tier-5 rows
-- (tier 2, 3, 4) change. cycle_hours (a tier's own cycle length) is not
-- touched; unlock_min_hours is recomputed as unlock_required_cycles *
-- cycle_hours to keep the same "time floor equals nominal time for the new
-- cycle count" invariant used everywhere else.
--
-- New targets: reach tier 3 -> 5 cycles / 60h, reach tier 4 -> 5 cycles /
-- 90h, reach tier 5 -> 4 cycles / 96h (this last one already matched, kept
-- here for explicitness/idempotency).
--
-- Pure product_templates config update — no user_tier_progress /
-- user_seasons rows touched. Unlocking is monotonic (cycle-count condition
-- only gets easier to satisfy), so nobody who already unlocked a tier is
-- affected; nobody's progress is revoked.
update product_templates pt
set
  unlock_required_cycles = v.cycles,
  unlock_min_hours = v.cycles * pt.cycle_hours
from (values
  (2, 5),
  (3, 5),
  (4, 4)
) as v(tier, cycles)
where pt.tier = v.tier
  and pt.season_id in (select id from seasons where slug = 'season-1');
