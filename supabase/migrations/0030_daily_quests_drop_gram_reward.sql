-- 100ГРАМ: drop the direct GRAM payout from the two daily "Срочные заказы"
-- quests (daily_2_cycles/daily_5_cycles) — they keep their +1 boost
-- (grants_boost was already true for both, see 0018_boost_inventory.sql),
-- they just no longer also mint GRAM on claim. claim_quest itself needs no
-- change: `balance + reward_amount` with reward_amount = 0 is already a
-- no-op, and it still reports reward_amount back to the client so the UI
-- can simply stop rendering the GRAM line when it's zero.
update quest_templates
set reward_amount = 0
where code in ('daily_2_cycles', 'daily_5_cycles');
