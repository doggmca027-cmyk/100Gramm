-- Price update requested 2026-08-20: 0.5 / 1 / 2 / 3 / 5 / 10 / 15 / 25
-- GRAM for tiers 1-8 (was 1 / 2 / 3 / 4 / 5 / 10 / 15 / 20). Pure
-- product_templates config — start_cycle/buy-max read pt.price fresh at
-- purchase time and stamp it onto cycles.amount_in, so this only affects
-- cycles started after this migration lands; every already-running or
-- already-claimed cycle keeps the amount_in it was actually charged.
update product_templates pt
set price = v.price
from (values
  (1, 0.50),
  (2, 1.00),
  (3, 2.00),
  (4, 3.00),
  (5, 5.00),
  (6, 10.00),
  (7, 15.00),
  (8, 25.00)
) as v(tier, price)
where pt.tier = v.tier
  and pt.season_id in (select id from seasons where slug = 'season-1');
