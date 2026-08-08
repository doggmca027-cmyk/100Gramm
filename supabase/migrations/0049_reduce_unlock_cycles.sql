-- Shave 1 cycle off every tier's unlock_required_cycles (season 1 balance
-- tweak), and rescale unlock_min_hours to match — same rule structure as
-- always (see resolve_due_cycles in 0035_security_audit_fixes.sql: a tier
-- unlocks once BOTH completed_cycles >= unlock_required_cycles AND real
-- elapsed time since the previous tier unlocked >= unlock_min_hours, the
-- latter deliberately independent of slot count so buying slots can't skip
-- the intended pacing). unlock_min_hours is recomputed as
-- (unlock_required_cycles - 1) * cycle_hours, i.e. exactly what the new,
-- one-cycle-shorter requirement takes at the tier's nominal cycle length —
-- same formula the original seed data (0003_seed_season1.sql) used, just
-- with the new cycle count. Tier 8 (the last one) has
-- unlock_required_cycles = 0 already — nothing to unlock past it, left as
-- is via the `where unlock_required_cycles > 0` guard.
--
-- Pure product_templates config update — no user_tier_progress /
-- user_seasons rows are touched, so nobody's completed_cycles count or
-- unlocked_at timestamps change. Whoever already met the *old* (higher)
-- cycle requirement stays unlocked (unlocking is monotonic — this can only
-- newly satisfy the cycle-count condition for more people, never revoke
-- it); whoever hasn't just needs 1 fewer cycle and gets the matching
-- shorter time floor from this point on.
update product_templates
set
  unlock_min_hours = (unlock_required_cycles - 1) * cycle_hours,
  unlock_required_cycles = unlock_required_cycles - 1
where unlock_required_cycles > 0
  and season_id in (select id from seasons where slug = 'season-1');
