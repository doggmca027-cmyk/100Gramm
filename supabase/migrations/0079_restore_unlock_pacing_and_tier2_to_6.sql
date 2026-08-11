-- Investigated a report that "players lost their tier-unlock progress
-- after yesterday's cycles change". Findings, confirmed directly against
-- the live database before writing this migration:
--
--   * supabase_migrations.schema_migrations shows 0049, 0050, and
--     0067_reduce_unlock_cycles_again.sql all applied, and 0067's commit
--     documents its intended final state as (tier -> unlock_required_cycles):
--       1->8, 2->4, 3->4, 4->3, 5->3, 6->2, 7->2
--   * The LIVE product_templates values were instead:
--       1->7, 2->5, 3->5, 4->4, 5->2, 6->1, 7->1
--     — which matches NEITHER 0067's committed end-state NOR any other
--     committed migration's output. Someone applied an undocumented
--     direct edit on top of 0067 (not captured in any migration file in
--     this repo). For tiers 2/3/4 that edit moved the requirement UP
--     (harder than 0067 intended: 5/5/4 instead of 4/4/3) — this is the
--     real "lost progression": a player who had exactly 4 completed
--     cycles on tier 2's row (the documented, intended threshold to reach
--     tier 3) found themselves needing a 5th, with nothing about their
--     own progress actually having changed. Tiers 1/5/6/7 drifted the
--     other way (easier than 0067), which never revokes anything (see
--     below) so isn't part of the reported problem, but is restored too
--     for the same reason: the live config should match what's actually
--     committed and reviewed, not a stray unrecorded edit.
--   * user_tier_progress.completed_cycles itself was cross-checked
--     against actual claimed-cycle counts in the `cycles` table for every
--     user: zero mismatches. Nobody's own progress counter was reset or
--     corrupted — only the thresholds it's compared against had drifted.
--     So there is no per-user data to repair here; restoring
--     product_templates is the entire fix. The very next resolve_due_
--     cycles call for each affected player (already invoked at the top
--     of every get_player_state) inserts their now-earned
--     user_tier_progress row for the next tier — confirmed 4 players
--     immediately qualify for tier 2 and 9 for tier 3 once this lands.
--
-- On top of the restore, tier 1's row (governs unlocking tier 2) is set
-- to the specific new value requested: 6 cycles (was 8 under 0067,
-- drifted to 7 live) — lower than 0067's own number, a deliberate further
-- loosening beyond just restoring the old pacing.
--
-- Same "unlock_min_hours = unlock_required_cycles * cycle_hours" formula
-- every prior tweak (0049/0050/0067) has used, and the same guarantee:
-- pure product_templates config, no user_tier_progress/user_seasons rows
-- touched, unlocking stays monotonic (only gets easier for tiers 1-4,
-- and tiers 5-7 tightening back up can only affect people who haven't
-- unlocked the next tier yet — never revokes an already-granted one, since
-- the check only gates inserting a new row, never deletes an existing one).
update product_templates pt
set
  unlock_required_cycles = v.cycles,
  unlock_min_hours = v.cycles * pt.cycle_hours
from (values
  (1, 6),
  (2, 4),
  (3, 4),
  (4, 3),
  (5, 3),
  (6, 2),
  (7, 2)
) as v(tier, cycles)
where pt.tier = v.tier
  and pt.season_id in (select id from seasons where slug = 'season-1');
