-- 100ГРАМ: remove the first-login GRAM reward — new players now bootstrap
-- with a balance of 0 instead of the 3 GRAM starting_balance introduced in
-- 0005_batched_cycles_and_starting_balance.sql.
--
-- bootstrap_user() already reads starting_balance out of seasons.config
-- (falling back to 0 if the key is absent), so this is a pure data change —
-- no function needs editing. Only affects users who register from here on;
-- existing players' balances are untouched.
update seasons
set config = jsonb_set(config, '{starting_balance}', '0')
where config ? 'starting_balance';
