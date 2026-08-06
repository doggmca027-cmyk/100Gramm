-- 100ГРАМ: first official launch — resets season-1's clock to start right
-- now instead of whenever it was seeded during development. Safe: the DB
-- had zero real player progress at the time this ran (0 cycles, 0 balance,
-- 1 test user), and active_season_id() only ever checks the `is_active`
-- flag, never starts_at/ends_at — those two columns are purely the
-- "season ends in Xd" countdown shown to players, nothing gates on them.
-- Same 30-day duration as the original seed (0003_seed_season1.sql).
update seasons
set starts_at = now(), ends_at = now() + interval '30 days'
where slug = 'season-1';
