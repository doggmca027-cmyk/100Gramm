-- Requested 2026-08-20: every tier pays a flat 6% profit per cycle
-- (was 15/18/22/27/33/40/50/60% across tiers 1-8). Pure
-- product_templates.payout_percent update.
--
-- Unlike price (amount_in, locked onto the cycle row at start_cycle time),
-- payout_percent is NOT snapshotted when a cycle starts — resolve_due_cycles
-- (0066_district_wars_monetization.sql) re-reads it fresh from
-- product_templates at claim time:
--   select payout_percent into v_payout_percent from product_templates ...
--   v_amount_out := round(v_cycle.amount_in * (1 + v_payout_percent / 100), 2);
-- So this deliberately applies retroactively too: the 135 cycles already
-- running at migration time (683.50 GRAM total amount_in, tiers 1-4,
-- started under 15/18/22/27%) will resolve at 6% once they come due, same
-- as every cycle started after this lands — confirmed as the intended
-- behavior, not grandfathering the old rate.
update product_templates
set payout_percent = 6.00
where season_id in (select id from seasons where slug = 'season-1');
