-- Cross-app "Смотрящие"/"Связи на районе" tasks: verification via a signed
-- postback API instead of Telegram's getChatMember, for tasks that point at
-- another app ("подпишись/поиграй в другой игре") rather than a Telegram
-- channel. Same mechanism works in both directions:
--   OUTGOING (we send our user to a partner, they tell us it's done):
--     admin creates a task with verification_method = 'external_api',
--     target_url pointing at the partner's app + a one-time token we mint
--     (partner_task_clicks). The partner's backend calls our
--     /api/partner/callback/[slug] with {token, success}, signed with the
--     shared secret set on that partner_apps row -- that grants the reward.
--   INCOMING (a partner sends us their user, we tell them it's done):
--     the partner links their user into our Mini App via
--     ?startapp=p100_<slug>_<their token> (see bootstrap_user's caller,
--     src/app/api/auth/telegram/route.ts). The first time that user's
--     session bootstraps, we record it (partner_inbound_clicks) and POST
--     {token, success:true} to that partner_apps row's
--     outgoing_callback_url, signed the same way -- "opened the app" is the
--     target action here, there's nothing else generic to verify against
--     for a v1 that has to work for any partner without them integrating
--     anything beyond "read our token, tell us GRAM/reward status".
--
-- Both directions share one wire format (POST {token, success:boolean},
-- header X-100GRAM-Signature = hex(HMAC-SHA256(shared_secret, raw_body))) --
-- see src/lib/partner-webhook.ts. Reward-granting logic never trusts
-- anything from the request body itself beyond the token/success pair --
-- the token is an unguessable capability (uuid) minted by us and only ever
-- valid for the one (user, task) pair it was created for.

-- ---------------------------------------------------------------------------
-- partner_apps — admin-managed registry of the other apps we cross-promote
-- with. One shared secret per partner, used to sign/verify *both*
-- directions (we trust admins to configure this out-of-band with the
-- partner, same trust level as e.g. the treasury wallet mnemonic).
-- ---------------------------------------------------------------------------
create table partner_apps (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9-]{2,32}$'),
  name text not null,
  secret text not null,
  -- Where we POST {token, success:true} once a referred user opens our app
  -- via this partner's link. Null until the partner side is wired up --
  -- outgoing notification is just skipped (not retried) while it's unset.
  outgoing_callback_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table partner_apps enable row level security;
-- No public select policy on purpose -- this holds shared secrets, only
-- ever touched by admin routes / RPCs through the service-role client.

-- ---------------------------------------------------------------------------
-- partner_tasks — add the external-app verification path alongside the
-- existing Telegram-channel one. channel_username/channel_id become
-- optional (only telegram_channel tasks need them); partner_app_id/
-- target_url are required for external_api tasks instead.
-- ---------------------------------------------------------------------------
alter table partner_tasks
  alter column channel_username drop not null,
  alter column channel_id drop not null;

alter table partner_tasks
  add column verification_method text not null default 'telegram_channel'
    check (verification_method in ('telegram_channel', 'external_api')),
  add column partner_app_id uuid references partner_apps(id),
  -- Full URL the "Выполнить" button opens, already ending in whatever the
  -- partner's own tracking param needs (typically a Telegram deep link's
  -- "...?startapp=" prefix) -- our one-time click token is appended raw to
  -- the end of this string, see create_partner_task_click below.
  add column target_url text;

alter table partner_tasks
  add constraint partner_tasks_verification_shape check (
    (verification_method = 'telegram_channel'
      and channel_username is not null and channel_id is not null)
    or
    (verification_method = 'external_api'
      and partner_app_id is not null and target_url is not null)
  );

-- ---------------------------------------------------------------------------
-- partner_task_clicks — one row per "Выполнить" tap on an external_api
-- task: mints the one-time token embedded in the outbound link, and is
-- what resolve_partner_task_click looks up when the partner's callback
-- arrives. status transitions pending -> confirmed|failed exactly once
-- (the `where status = 'pending'` guard in resolve_partner_task_click is
-- what makes a retried/duplicate callback a no-op instead of a double
-- credit).
-- ---------------------------------------------------------------------------
create table partner_task_clicks (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references partner_tasks(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  token uuid not null default gen_random_uuid() unique,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'failed')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index partner_task_clicks_user_task_idx on partner_task_clicks (user_id, task_id);

-- At most one *pending* click per (user, task) — same "one active X per
-- player" idiom as withdrawal_requests_one_pending_idx
-- (0025_automatic_withdrawal_payout.sql). Without this, two near-
-- simultaneous "Выполнить" taps (or a doubled request) could each mint
-- their own pending token via create_partner_task_click's plain
-- select-then-insert, and if both later resolved with success=true the
-- reward would be credited twice — see resolve_partner_task_click's own
-- locking below for the second half of that fix.
create unique index partner_task_clicks_one_pending_idx
  on partner_task_clicks (user_id, task_id)
  where status = 'pending';

alter table partner_task_clicks enable row level security;

-- ---------------------------------------------------------------------------
-- partner_inbound_clicks — the other direction's ledger: one row per
-- distinct (partner, their token) pair a referred user arrives with. The
-- unique constraint is what makes notify-on-first-open idempotent -- see
-- the insert-and-catch-conflict pattern in api/auth/telegram/route.ts.
-- ---------------------------------------------------------------------------
create table partner_inbound_clicks (
  id uuid primary key default gen_random_uuid(),
  partner_app_id uuid not null references partner_apps(id) on delete cascade,
  partner_token text not null,
  user_id uuid references users(id) on delete set null,
  notified_at timestamptz,
  created_at timestamptz not null default now(),
  unique (partner_app_id, partner_token)
);

alter table partner_inbound_clicks enable row level security;

-- ---------------------------------------------------------------------------
-- create_partner_task_click — mints (or reuses) the token for a
-- user + external_api task pair. Refuses if the task isn't an active
-- external_api task, or the user already completed it. Reuses an existing
-- pending click instead of minting a fresh token on every re-tap of
-- "Выполнить" -- a partner's callback for an *earlier* token would
-- otherwise silently stop matching what the UI just re-opened.
--
-- Insert-first-and-catch-the-conflict (against
-- partner_task_clicks_one_pending_idx above), not select-then-insert: two
-- near-simultaneous calls (a double-tap, a doubled request) can't each
-- slip past a plain existence check and mint their own pending row —
-- whichever commits first wins the unique index, the second catches
-- unique_violation and re-selects what the first one just created. Same
-- "insert first, unique index rejects the duplicate" shape as
-- credit_ton_deposit's tx_hash guard (0024_ton_deposit_1to1.sql).
-- ---------------------------------------------------------------------------
create or replace function create_partner_task_click(p_user_id uuid, p_task_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_task partner_tasks%rowtype;
  v_token uuid;
begin
  select * into v_task from partner_tasks
  where id = p_task_id and is_active and verification_method = 'external_api';
  if not found then
    raise exception 'unknown_task';
  end if;

  if exists (
    select 1 from user_partner_tasks
    where user_id = p_user_id and task_id = p_task_id and completed_at is not null
  ) then
    raise exception 'already_claimed';
  end if;

  begin
    insert into partner_task_clicks (task_id, user_id)
    values (p_task_id, p_user_id)
    returning token into v_token;
  exception
    when unique_violation then
      select token into v_token
      from partner_task_clicks
      where user_id = p_user_id and task_id = p_task_id and status = 'pending'
      order by created_at desc
      limit 1;
      -- Vanishingly unlikely (the pending row that just caused the
      -- conflict would have to be resolved and deleted-in-spirit, i.e.
      -- transitioned to confirmed/failed, in the instant between the
      -- failed insert and this select) but never return a null token.
      if v_token is null then
        raise exception 'unknown_task';
      end if;
  end;

  return jsonb_build_object('token', v_token, 'target_url', v_task.target_url || v_token::text);
end;
$$;

-- ---------------------------------------------------------------------------
-- resolve_partner_task_click — called by /api/partner/callback/[slug]
-- *after* it has already verified the request's HMAC signature against the
-- owning partner_apps row. p_token is the capability (an unguessable
-- uuid), but the route also passes p_partner_app_id (the *verified*
-- partner_apps row the signature matched) so a token that somehow leaked
-- to the wrong partner can't be resolved through a different partner's
-- slug — defense in depth on top of the token itself being unguessable.
-- Grants the task's GRAM/item reward exactly once. Two guards, not one:
-- the `where status = 'pending'` lock on the click row means a retried
-- callback (same token, network retry on the partner's side) just returns
-- 'already_resolved' the second time. Separately, and more importantly,
-- user_partner_tasks itself — not the click row — is the actual source of
-- truth for "has this task's reward already been paid": it's
-- `select ... for update`-locked and re-checked for an existing
-- completed_at *before* crediting anything, so even two *different* click
-- tokens for the same (user, task) (which partner_task_clicks_one_pending_idx
-- shouldn't allow to coexist, but this doesn't rely on that alone) would
-- serialize on this row lock and only the first to arrive actually pays
-- out — the second sees completed_at already set and returns
-- 'already_resolved' without touching balance/inventory. Same pattern
-- claim_partner_task already uses for the Telegram-channel path. No 24h
-- hold here, unlike that path -- there's no "unsubscribe" equivalent to
-- re-check for an external target action; the partner's own callback *is*
-- the confirmation, at the moment it arrives.
-- ---------------------------------------------------------------------------
create or replace function resolve_partner_task_click(p_token uuid, p_success boolean, p_partner_app_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_click partner_task_clicks%rowtype;
  v_task partner_tasks%rowtype;
  v_season_id uuid;
  v_already_completed boolean;
  v_shelf_life_hours numeric;
  i integer;
begin
  select * into v_click from partner_task_clicks
  where token = p_token and status = 'pending'
  for update;

  if not found then
    return jsonb_build_object('status', 'already_resolved');
  end if;

  select * into v_task from partner_tasks where id = v_click.task_id;

  if v_task.partner_app_id <> p_partner_app_id then
    -- Token belongs to a different partner's task -- never resolve it
    -- (and never leak *why* beyond "not found", same shape as an unknown
    -- token so this can't be used to probe which tokens exist).
    return jsonb_build_object('status', 'already_resolved');
  end if;

  v_season_id := v_task.season_id;

  if not p_success then
    update partner_task_clicks set status = 'failed', resolved_at = now() where id = v_click.id;
    return jsonb_build_object('status', 'failed');
  end if;

  update partner_task_clicks set status = 'confirmed', resolved_at = now() where id = v_click.id;

  -- Ensure the row exists, then lock and re-check it -- this is the actual
  -- single-payment guard, not the click row above.
  insert into user_partner_tasks (user_id, task_id, season_id, verified_at, completed_at)
  values (v_click.user_id, v_click.task_id, v_season_id, now(), null)
  on conflict (user_id, task_id) do nothing;

  select completed_at is not null into v_already_completed
  from user_partner_tasks
  where user_id = v_click.user_id and task_id = v_click.task_id
  for update;

  if v_already_completed then
    return jsonb_build_object('status', 'already_resolved');
  end if;

  update user_partner_tasks
  set completed_at = now(), verified_at = coalesce(verified_at, now())
  where user_id = v_click.user_id and task_id = v_click.task_id;

  if v_task.reward_amount > 0 then
    update user_seasons
    set balance = balance + v_task.reward_amount, total_earned = total_earned + v_task.reward_amount
    where user_id = v_click.user_id and season_id = v_season_id;
  end if;

  if v_task.reward_item_type is not null then
    select shelf_life_hours into v_shelf_life_hours
    from combo_item_templates where item_type = v_task.reward_item_type;

    for i in 1..v_task.reward_item_qty loop
      insert into user_inventory (user_id, season_id, item_type, expires_at)
      values (v_click.user_id, v_season_id, v_task.reward_item_type, now() + (v_shelf_life_hours::text || ' hours')::interval);
    end loop;
  end if;

  return jsonb_build_object(
    'status', 'confirmed',
    'reward_amount', v_task.reward_amount,
    'reward_item_type', v_task.reward_item_type,
    'reward_item_qty', v_task.reward_item_qty
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- get_player_state — partner_tasks sub-block gains verification_method so
-- the client knows external_api tasks never show the Telegram-style
-- "Проверить" button (there's nothing for the player to trigger -- see
-- src/components/partner-tasks-section.tsx). Everything else unchanged
-- from 0054_partner_task_item_reward.sql.
-- ---------------------------------------------------------------------------
create or replace function get_player_state(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_season_id uuid;
  v_result jsonb;
begin
  perform resolve_due_cycles(p_user_id);
  perform expire_due_boosts(p_user_id);

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  perform ensure_daily_combo(v_season_id);
  perform process_auto_collect_cycles();

  select jsonb_build_object(
    'season', (
      select jsonb_build_object(
        'id', s.id, 'slug', s.slug, 'title', s.title, 'story_theme', s.story_theme,
        'title_i18n', jsonb_build_object('ru', s.title, 'en', s.title_i18n->>'en', 'tr', s.title_i18n->>'tr', 'id', s.title_i18n->>'id'),
        'story_theme_i18n', jsonb_build_object('ru', s.story_theme, 'en', s.story_theme_i18n->>'en', 'tr', s.story_theme_i18n->>'tr', 'id', s.story_theme_i18n->>'id'),
        'starts_at', s.starts_at, 'ends_at', s.ends_at, 'config', s.config
      ) from seasons s where s.id = v_season_id
    ),
    'profile', (
      select jsonb_build_object(
        'username', u.username, 'first_name', u.first_name, 'photo_url', u.photo_url, 'hide_from_leaderboard', u.hide_from_leaderboard
      )
      from users u where u.id = p_user_id
    ),
    'wallet', (
      select jsonb_build_object(
        'balance', us.balance,
        'total_earned', us.total_earned,
        'completed_cycles_total', us.completed_cycles_total,
        'has_seen_intro', us.has_seen_intro,
        'xp', us.xp,
        'total_slots_open', (
          select coalesce(sum(tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level)), 0)
          from user_tier_progress utp
          join product_templates pt on pt.season_id = utp.season_id and pt.tier = utp.tier
          where utp.user_id = p_user_id and utp.season_id = v_season_id
        ),
        'total_slots_used', (
          select coalesce(sum(slot_quantity), 0) from cycles
          where user_id = p_user_id and season_id = v_season_id and status = 'running'
        ),
        'pending_withdrawal', (
          select jsonb_build_object(
            'id', wr.id, 'amount', wr.amount, 'fee', wr.fee, 'net_amount', wr.net_amount,
            'created_at', wr.created_at
          )
          from withdrawal_requests wr
          where wr.user_id = p_user_id and wr.season_id = v_season_id and wr.status = 'pending'
          order by wr.created_at desc
          limit 1
        ),
        'auto_collect_until', (
          select us2.auto_collect_until from user_seasons us2
          where us2.user_id = p_user_id and us2.season_id = v_season_id
        )
      ) from user_seasons us where us.user_id = p_user_id and us.season_id = v_season_id
    ),
    'stats', jsonb_build_object(
      'profit_24h', (
        coalesce((
          select sum(amount_out) from cycles
          where user_id = p_user_id and season_id = v_season_id
            and status = 'claimed' and claimed_at >= now() - interval '24 hours'
        ), 0)
        + coalesce((
          select sum(amount) from referral_earnings
          where beneficiary_id = p_user_id and created_at >= now() - interval '24 hours'
        ), 0)
      )
    ),
    'rank', (
      select jsonb_build_object(
        'name', r.name, 'icon', r.icon, 'level', r.sort_order,
        'name_i18n', jsonb_build_object('ru', r.name, 'en', r.name_i18n->>'en', 'tr', r.name_i18n->>'tr', 'id', r.name_i18n->>'id'),
        'min_earned', r.min_earned,
        'next_min_earned', (
          select r2.min_earned from ranks r2
          where r2.season_id = v_season_id and r2.sort_order = r.sort_order + 1
        )
      )
      from ranks r
      where r.season_id = v_season_id
        and r.min_earned <= (
          select total_earned from user_seasons
          where user_id = p_user_id and season_id = v_season_id
        )
      order by r.min_earned desc limit 1
    ),
    'tiers', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'tier', pt.tier,
        'name', pt.name,
        'description', pt.description,
        'name_i18n', jsonb_build_object('ru', pt.name, 'en', pt.name_i18n->>'en', 'tr', pt.name_i18n->>'tr', 'id', pt.name_i18n->>'id'),
        'description_i18n', jsonb_build_object('ru', pt.description, 'en', pt.description_i18n->>'en', 'tr', pt.description_i18n->>'tr', 'id', pt.description_i18n->>'id'),
        'price', pt.price,
        'payout_percent', pt.payout_percent,
        'cycle_hours', pt.cycle_hours,
        'unlocked', (utp.tier is not null),
        'completed_cycles', coalesce(utp.completed_cycles, 0),
        'unlock_required_cycles', pt.unlock_required_cycles,
        'unlock_min_hours', pt.unlock_min_hours,
        'unlocked_at', utp.unlocked_at,
        'slots_open', case when utp.tier is not null
          then tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level)
          else pt.slot_base_count end,
        'slots_boost', coalesce(bc.boost_count, 0),
        'slots_total', case when utp.tier is not null
          then tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level) + coalesce(bc.boost_count, 0)
          else pt.slot_base_count end,
        'slots_used', coalesce(cyc.used_slots, 0),
        'slots_max', pt.slot_max_count,
        'cycles_to_next_slot', case
          when utp.tier is null then pt.slot_cycles_per_level
          when tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level) >= pt.slot_max_count then null
          else pt.slot_cycles_per_level - (utp.completed_cycles % pt.slot_cycles_per_level)
        end,
        'can_buy_max', (
          utp.tier is not null
          and tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level) >= pt.slot_max_count
        )
      ) order by pt.tier), '[]'::jsonb)
      from product_templates pt
      left join user_tier_progress utp
        on utp.season_id = v_season_id and utp.tier = pt.tier and utp.user_id = p_user_id
      left join (
        select tier, sum(slot_quantity) as used_slots
        from cycles
        where user_id = p_user_id and season_id = v_season_id and status = 'running'
        group by tier
      ) cyc on cyc.tier = pt.tier
      left join (
        select target_tier, count(*) as boost_count
        from user_boosts
        where user_id = p_user_id and season_id = v_season_id and status = 'ACTIVE'
        group by target_tier
      ) bc on bc.target_tier = pt.tier
      where pt.season_id = v_season_id
    ),
    'active_cycles', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'tier', c.tier, 'started_at', c.started_at, 'ends_at', c.ends_at,
        'amount_in', c.amount_in, 'slot_quantity', c.slot_quantity,
        'seconds_remaining', greatest(0, extract(epoch from (c.ends_at - now())))
      ) order by c.ends_at), '[]'::jsonb)
      from cycles c
      where c.user_id = p_user_id and c.season_id = v_season_id and c.status = 'running'
    ),
    'quests', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', qt.id, 'title', qt.title, 'description', qt.description,
        'title_i18n', jsonb_build_object('ru', qt.title, 'en', qt.title_i18n->>'en', 'tr', qt.title_i18n->>'tr', 'id', qt.title_i18n->>'id'),
        'description_i18n', jsonb_build_object('ru', qt.description, 'en', qt.description_i18n->>'en', 'tr', qt.description_i18n->>'tr', 'id', qt.description_i18n->>'id'),
        'target_count', qt.target_count,
        'progress_count', coalesce(uqp.progress_count, 0),
        'reward_amount', qt.reward_amount,
        'grants_boost', qt.grants_boost,
        'completed_at', uqp.completed_at,
        'claimed_at', uqp.claimed_at
      )), '[]'::jsonb)
      from quest_templates qt
      left join user_quest_progress uqp
        on uqp.quest_id = qt.id and uqp.user_id = p_user_id and uqp.quest_date = current_date
      where qt.season_id = v_season_id and qt.is_daily
    ),
    'containers', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', uc.id, 'code', ct.code, 'name', ct.name,
        'obtained_at', uc.obtained_at, 'opens_at', uc.opens_at,
        'opened_at', uc.opened_at, 'reward_amount', uc.reward_amount
      ) order by uc.obtained_at), '[]'::jsonb)
      from user_containers uc
      join container_templates ct on ct.id = uc.container_template_id
      where uc.user_id = p_user_id and uc.season_id = v_season_id and uc.opened_at is null
    ),
    'partner_tasks', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pt.id, 'title', pt.title, 'description', pt.description,
        'reward_amount', pt.reward_amount,
        'reward_item_type', pt.reward_item_type,
        'reward_item_qty', pt.reward_item_qty,
        'channel_username', pt.channel_username,
        'icon_url', pt.icon_url,
        'kind', pt.kind,
        'verification_method', pt.verification_method,
        -- completed now means "reward actually paid" (completed_at set),
        -- not just "subscription verified" — see verified_at/available_at
        -- below for the 24h holding period in between.
        'completed', (upt.completed_at is not null),
        'verified_at', upt.verified_at,
        'available_at', case when upt.verified_at is not null and upt.completed_at is null
          then upt.verified_at + interval '24 hours' else null end
      ) order by pt.sort_order), '[]'::jsonb)
      from partner_tasks pt
      left join user_partner_tasks upt
        on upt.task_id = pt.id and upt.user_id = p_user_id
      where pt.season_id = v_season_id and pt.is_active
    ),
    'system_tasks', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', st.id, 'slug', st.slug, 'title', st.title, 'description', st.description,
        'category', st.category, 'target_type', st.target_type, 'target_value', st.target_value,
        'required_count', st.required_count,
        'progress', case st.target_type
          when 'referrals_level_1' then (select count(*) from users where referred_by = p_user_id)
          when 'cycles_completed' then (
            select coalesce(completed_cycles_total, 0) from user_seasons
            where user_id = p_user_id and season_id = v_season_id
          )
          when 'tier_reached' then case when exists (
            select 1 from user_tier_progress
            where user_id = p_user_id and season_id = v_season_id and tier = st.target_value::smallint
          ) then st.required_count else 0 end
          else 0
        end,
        'reward_xp', st.reward_xp,
        'rewards', (
          select coalesce(jsonb_agg(jsonb_build_object('item_type', str.item_type, 'quantity', str.quantity)), '[]'::jsonb)
          from system_task_rewards str where str.task_id = st.id
        ),
        -- completed now means "reward paid" (completed_at set) — social
        -- channel_sub/chat_join tasks hold at verified-but-unpaid for 24h
        -- first, see verified_at/available_at.
        'completed', (uct.completed_at is not null),
        'verified_at', uct.verified_at,
        'available_at', case when uct.verified_at is not null and uct.completed_at is null
          then uct.verified_at + interval '24 hours' else null end
      ) order by st.sort_order), '[]'::jsonb)
      from system_tasks st
      left join user_completed_tasks uct
        on uct.task_id = st.id and uct.user_id = p_user_id and uct.season_id = v_season_id
      where st.is_active
    ),
    'squad', jsonb_build_object(
      'invite_code', (select telegram_id::text from users where id = p_user_id),
      'referred_count', (select count(*) from users where referred_by = p_user_id),
      'earned_total', (select coalesce(sum(amount), 0) from referral_earnings where beneficiary_id = p_user_id and season_id = v_season_id),
      'is_ambassador', (select coalesce(is_ambassador, false) from users where id = p_user_id)
    ),
    'daily_combo', (
      select jsonb_build_object(
        'attempts_used', coalesce(ucp.attempts_used, 0),
        'attempts_max', dc.max_attempts,
        'is_completed', coalesce(ucp.is_completed, false),
        'resets_at', ((dc.combo_date + 1)::timestamp at time zone 'utc'),
        'slot_count', array_length(dc.tiers, 1),
        'pool', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'tier', pt.tier, 'name', pt.name,
            'name_i18n', jsonb_build_object('ru', pt.name, 'en', pt.name_i18n->>'en', 'tr', pt.name_i18n->>'tr', 'id', pt.name_i18n->>'id')
          ) order by pt.tier), '[]'::jsonb)
          from product_templates pt where pt.season_id = v_season_id
        ),
        'last_guess', case when ucp.last_guess_tiers is not null then (
          select coalesce(jsonb_agg(jsonb_build_object(
            'tier', g.tier, 'correct', g.correct, 'name', pt.name,
            'name_i18n', jsonb_build_object('ru', pt.name, 'en', pt.name_i18n->>'en', 'tr', pt.name_i18n->>'tr', 'id', pt.name_i18n->>'id')
          ) order by g.ord), '[]'::jsonb)
          from unnest(ucp.last_guess_tiers, ucp.last_guess_correct) with ordinality as g(tier, correct, ord)
          join product_templates pt on pt.season_id = v_season_id and pt.tier = g.tier
        ) else null end,
        'revealed_tiers', case when coalesce(ucp.is_completed, false) then (
          select coalesce(jsonb_agg(jsonb_build_object(
            'tier', u.t, 'name', pt.name,
            'name_i18n', jsonb_build_object('ru', pt.name, 'en', pt.name_i18n->>'en', 'tr', pt.name_i18n->>'tr', 'id', pt.name_i18n->>'id')
          ) order by u.ord), '[]'::jsonb)
          from unnest(dc.tiers) with ordinality as u(t, ord)
          join product_templates pt on pt.season_id = v_season_id and pt.tier = u.t
        ) else null end,
        'possible_drops', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'item_type', item_type, 'category', category, 'drop_weight', drop_weight,
            'effect_percent', effect_percent, 'effect_hours', effect_hours
          ) order by sort_order), '[]'::jsonb)
          from combo_item_templates
        ),
        'reward_item', case when ucp.reward_item_type is not null then (
          select jsonb_build_object(
            'item_type', item_type, 'category', category,
            'effect_percent', effect_percent, 'effect_hours', effect_hours
          )
          from combo_item_templates where item_type = ucp.reward_item_type
        ) else null end
      )
      from daily_combo dc
      left join user_combo_progress ucp
        on ucp.user_id = p_user_id and ucp.season_id = v_season_id and ucp.combo_date = dc.combo_date
      where dc.season_id = v_season_id and dc.combo_date = (now() at time zone 'utc')::date
    ),
    'boosts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ub.id,
        'status', ub.status,
        'source', ub.source,
        'target_tier', ub.target_tier,
        'created_at', ub.created_at,
        'expires_at', ub.expires_at,
        'activated_at', ub.activated_at
      ) order by ub.created_at), '[]'::jsonb)
      from user_boosts ub
      where ub.user_id = p_user_id and ub.season_id = v_season_id
        and ub.status in ('PENDING', 'ACTIVE')
    ),
    'inventory', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'item_type', inv.item_type,
        'category', cit.category,
        'quantity', inv.quantity,
        'expires_at', inv.nearest_expiry,
        'effect_percent', cit.effect_percent,
        'effect_hours', cit.effect_hours
      ) order by cit.sort_order), '[]'::jsonb)
      from (
        select item_type, count(*) as quantity, min(expires_at) as nearest_expiry
        from user_inventory
        where user_id = p_user_id and season_id = v_season_id
          and status = 'active' and expires_at > now()
        group by item_type
      ) inv
      join combo_item_templates cit on cit.item_type = inv.item_type
    ),
    'exchange_rate', (
      select jsonb_build_object('pair', pair, 'rate', rate, 'updated_at', updated_at)
      from exchange_rates where pair = 'GRAM_USDT'
    )
  ) into v_result;

  return v_result;
end;
$$;
