-- Fix: migration 0011 added p_photo_url to bootstrap_user via CREATE OR
-- REPLACE, but that only replaces a function with the IDENTICAL parameter
-- signature — adding a parameter instead created a second overload
-- alongside the original 4-arg one. PostgREST then can't disambiguate a
-- call that omits p_photo_url (its default), and errors with PGRST203.
--
-- Production was never actually affected — the one real caller
-- (api/auth/telegram/route.ts) always sends all 5 args — but the stale
-- overload is real and must go.
drop function if exists bootstrap_user(bigint, text, text, text);
