-- Shave another cycle off every tier's unlock_required_cycles (season-1
-- pacing tweak, requested directly), same rule/formula as
-- 0049_reduce_unlock_cycles.sql: unlock_min_hours is recomputed as
-- (new unlock_required_cycles) * cycle_hours, keeping the "time floor
-- equals nominal time for the new cycle count" invariant every prior
-- tweak (0049, 0050) has used. Tier 8's row (unlock_required_cycles = 0,
-- last tier, nothing past it to unlock) is excluded via the same
-- `where unlock_required_cycles > 0` guard 0049 used.
--
--   tier  cycles(old->new)  min_hours(old->new)
--   1     9 -> 8            72  -> 64
--   2     5 -> 4            60  -> 48
--   3     5 -> 4            90  -> 72
--   4     4 -> 3             96 -> 72
--   5     4 -> 3            144 -> 108
--   6     3 -> 2            144 -> 96
--   7     3 -> 2            180 -> 120
--   8     0 (unchanged, last tier)
--
-- resolve_due_cycles' unlock rule is unchanged (0035_security_audit_fixes.sql):
-- a tier unlocks once BOTH completed_cycles >= unlock_required_cycles AND
-- real elapsed time since the previous tier unlocked >= unlock_min_hours.
-- Pure product_templates config update -- no user_tier_progress /
-- user_seasons rows touched, so nobody's completed_cycles count or
-- unlocked_at timestamps change. Unlocking is monotonic (the cycle-count
-- condition only gets easier to satisfy), so this can only newly satisfy
-- the condition for people close to the old threshold, never revoke an
-- already-unlocked tier.
update product_templates
set
  unlock_min_hours = (unlock_required_cycles - 1) * cycle_hours,
  unlock_required_cycles = unlock_required_cycles - 1
where unlock_required_cycles > 0
  and season_id in (select id from seasons where slug = 'season-1');
