-- Requested 2026-08-20: each tier card should only ever have 1 slot,
-- without touching the slot system's logic. tier_slots_open (0016_per_item_slots.sql)
-- computes least(slot_max_count, slot_base_count + floor(completed_cycles /
-- slot_cycles_per_level)) — untouched here. Setting both base and max to 1
-- makes that formula always resolve to 1 regardless of completed_cycles,
-- so the progression mechanic, boost/bank slot bonuses (added on top,
-- separately, in get_player_state), and buy-max all keep working exactly
-- as before, just capped at a ceiling of 1 base slot per tier instead of 5.
--
-- slot_cycles_per_level is left as-is (irrelevant once base == max — the
-- floor(...) term can never matter) rather than zeroed out, so re-raising
-- slot_max_count later restores the original pacing with no further edits.
--
-- Already-running cycles are unaffected: active_cycles (and therefore the
-- slot tiles/timers shown) always come straight from the `cycles` table,
-- never from slots_total. A handful of players currently sitting on 2-3
-- concurrent cycles on one tier (grown before this change) keep seeing
-- and collecting all of them; they just can't start a *new* one on that
-- tier until they're back under the new cap of 1.
update product_templates
set slot_base_count = 1,
    slot_max_count = 1
where season_id in (select id from seasons where slug = 'season-1');
