-- Automatic Telegram DMs to Syndicate members 30 minutes before District
-- Wars' daily battle window opens, and 30 minutes before it closes.
--
-- Deviations from the literal spec:
--   * "УТС/MSK" resolved to UTC only, same call every other time-window
--     computation in this schema already makes (see e.g.
--     0070_syndicate_weekly_leaderboard.sql's header for the same note).
--   * The two message templates' "100 TON" prize-pool figure is stale —
--     the weekly pool is 200 TON as of 0072_double_weekly_prize_pool.sql —
--     so the actual Telegram copy (src/lib/notify-district-war.ts) says
--     200, not the spec's literal text.
--   * "Кому" for the closing reminder ("у которых зафиксирован
--     минимальный разрыв по очкам ... или активированы активные битвы")
--     isn't a crisply definable audience as written — implemented as
--     "every member of a gang currently engaged in an active battle
--     window" (target_district_id points at a district whose battle_
--     status is 'active' right now), which covers the literal "активные
--     битвы" half and is the only part of that sentence with an
--     unambiguous database meaning. The opening reminder's audience is
--     the literal "все участники Синдикатов", no such filter.
--   * "Логирование ... чтобы избежать повторных дублирующих отправок" is
--     the idempotency guard this migration's whole design centers on:
--     notification_logs has a unique (notification_type, reference_date)
--     constraint, and run_district_war_notifications() claims that slot
--     with an `on conflict do nothing` insert *before* gathering the
--     audience — a second/retried invocation on the same day for the
--     same type finds 0 rows affected and sends nothing, regardless of
--     how many times the cron (or a stray manual request) hits the route.
--   * "Пакетная отправка ... не более 30 сообщений в секунду" — same
--     sequential-send-with-40ms-sleep loop this schema's other Telegram
--     broadcasts already use (api/admin/broadcast/route.ts, lib/notify-
--     ambassadors-combo.ts); no separate queue/worker, consistent with
--     how small this app's audience still is for any one DM blast.

alter table users
  add column notifications_enabled boolean not null default true,
  add column telegram_blocked boolean not null default false;

-- ---------------------------------------------------------------------------
-- notification_logs — one row per (notification_type, day) actually sent.
-- The unique constraint IS the duplicate-send guard (see header) — rows
-- are inserted the instant a send is claimed, before any Telegram API call
-- is made, then sent_count/failed_count are filled in afterwards by the
-- caller (src/lib/notify-district-war.ts) once the batch finishes.
-- ---------------------------------------------------------------------------
create table notification_logs (
  id uuid primary key default gen_random_uuid(),
  notification_type text not null check (notification_type in ('district_war_start', 'district_war_end')),
  reference_date date not null,
  sent_count integer not null default 0,
  failed_count integer not null default 0,
  created_at timestamptz not null default now(),
  unique (notification_type, reference_date)
);

alter table notification_logs enable row level security;

-- ---------------------------------------------------------------------------
-- district_war_notification_due — 'district_war_start' when any district's
-- window opens in 25-35 minutes from p_now, 'district_war_end' when any
-- district's window closes in that same range, else null. The ±5-minute
-- band around the literal 30-minute mark tolerates ordinary cron jitter
-- (Vercel doesn't guarantee to-the-second firing) without ever risking two
-- different calendar minutes both landing inside the window and double-
-- firing — the notification_logs unique constraint is what actually
-- prevents a double-send if that ever did happen, this is just about
-- being on time in the first place.
--
-- date + time -> timestamp -> "at time zone 'utc'" is the same idiom
-- district_next_transition_at (0065_district_wars_daily_battles.sql)
-- already uses to turn a bare time-of-day into today's actual instant.
-- ---------------------------------------------------------------------------
create or replace function district_war_notification_due(p_now timestamptz default now())
returns text
language sql
stable
as $$
  select case
    when exists (
      select 1 from districts d
      where extract(epoch from (
        (((p_now at time zone 'utc')::date::timestamp + d.window_start_time) at time zone 'utc') - p_now
      )) between 25 * 60 and 35 * 60
    ) then 'district_war_start'
    when exists (
      select 1 from districts d
      where extract(epoch from (
        (((p_now at time zone 'utc')::date::timestamp + d.window_end_time) at time zone 'utc') - p_now
      )) between 25 * 60 and 35 * 60
    ) then 'district_war_end'
    else null
  end;
$$;

-- ---------------------------------------------------------------------------
-- run_district_war_notifications — the cron route's one call. Determines
-- what's due, claims today's slot for it (see notification_logs' header),
-- and returns the telegram_id audience for the caller to actually DM —
-- Postgres can't call the Telegram Bot API itself, so the send loop lives
-- in src/lib/notify-district-war.ts.
-- ---------------------------------------------------------------------------
create or replace function run_district_war_notifications()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type text;
  v_reference_date date := (now() at time zone 'utc')::date;
  v_rows integer;
  v_claimed boolean;
  v_audience jsonb;
begin
  v_type := district_war_notification_due(now());
  if v_type is null then
    return jsonb_build_object('notification_type', null, 'claimed', false, 'audience', '[]'::jsonb);
  end if;

  insert into notification_logs (notification_type, reference_date)
  values (v_type, v_reference_date)
  on conflict (notification_type, reference_date) do nothing;

  get diagnostics v_rows = row_count;
  v_claimed := v_rows > 0;

  if not v_claimed then
    return jsonb_build_object('notification_type', v_type, 'claimed', false, 'audience', '[]'::jsonb);
  end if;

  if v_type = 'district_war_start' then
    select coalesce(jsonb_agg(distinct u.telegram_id), '[]'::jsonb)
    into v_audience
    from gang_members gm
    join users u on u.id = gm.user_id
    where u.notifications_enabled and not u.telegram_blocked;
  else
    select coalesce(jsonb_agg(distinct u.telegram_id), '[]'::jsonb)
    into v_audience
    from gang_members gm
    join users u on u.id = gm.user_id
    join gangs g on g.id = gm.gang_id
    join districts d on d.id = g.target_district_id
    where u.notifications_enabled and not u.telegram_blocked
      and district_battle_status(d.window_start_time, d.window_end_time) = 'active';
  end if;

  return jsonb_build_object(
    'notification_type', v_type, 'claimed', true, 'audience', v_audience, 'reference_date', v_reference_date
  );
end;
$$;
