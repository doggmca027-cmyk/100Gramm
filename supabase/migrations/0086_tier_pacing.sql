-- Requested 2026-08-20, two changes together:
--
-- 1. cycle_hours per tier: 9/13/17/21/27/31/40/48 (was 8/12/18/24/36/48/60/56).
--    start_cycle stamps ends_at = now() + cycle_hours onto the cycle row
--    itself at creation time (0058_gangs.sql), so — same guarantee as every
--    price/pacing migration before this — only cycles started after this
--    lands run on the new duration; already-running cycles keep the
--    ends_at they were already given.
--
-- 2. unlock_required_cycles = 5 for tiers 1-7 (each tier's row governs
--    unlocking the *next* tier, see 0079_restore_unlock_pacing_and_tier2_to_6.sql) —
--    "every tier opens after 5 completed cycles, never earlier" (was
--    6/4/4/3/3/2/2). Tier 8 is untouched (0 — top tier, nothing further to
--    unlock). unlock_min_hours recomputed as unlock_required_cycles *
--    (this tier's own new cycle_hours) — same formula every prior tweak
--    (0049/0050/0067/0079) has used.
update product_templates pt
set
  cycle_hours = v.cycle_hours,
  unlock_required_cycles = coalesce(v.unlock_required_cycles, pt.unlock_required_cycles),
  unlock_min_hours = coalesce(v.unlock_required_cycles, pt.unlock_required_cycles) * v.cycle_hours
from (values
  (1, 9, 5),
  (2, 13, 5),
  (3, 17, 5),
  (4, 21, 5),
  (5, 27, 5),
  (6, 31, 5),
  (7, 40, 5),
  (8, 48, null)
) as v(tier, cycle_hours, unlock_required_cycles)
where pt.tier = v.tier
  and pt.season_id in (select id from seasons where slug = 'season-1');
