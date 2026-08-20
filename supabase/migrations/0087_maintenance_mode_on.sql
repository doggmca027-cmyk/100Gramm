-- Maintenance mode ON for the active season — blocks non-admin logins
-- while tier pacing (0086) and any further changes land. Gated in
-- /api/auth/telegram's POST handler (src/app/api/auth/telegram/route.ts):
-- checked before bootstrap_user or anything else runs, so a non-admin
-- can't even create their user_seasons row while this is on. Admins
-- (NEXT_PUBLIC_ADMIN_TELEGRAM_IDS) pass straight through, same allowlist
-- requireAdminUserId already uses.
--
-- Deliberately scoped to *new logins only* (not every API call via
-- requireUserId) — a session that was already open when this flipped on
-- keeps working until the Mini App is closed and reopened, which in
-- practice is every time someone taps the bot again in Telegram. Turn it
-- back off with:
--   update seasons set config = jsonb_set(config, '{features,maintenance}', 'false', true) where is_active;
update seasons
set config = jsonb_set(config, '{features,maintenance}', 'true', true)
where is_active;
