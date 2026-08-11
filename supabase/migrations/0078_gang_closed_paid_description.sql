-- Syndicate settings: leader-toggleable closed (application-only)
-- membership, an optional paid entry price, and a free-text description.
-- All three ship together since they land on the same three new `gangs`
-- columns and the same new leader-only "Settings" tab client-side.
--
-- Where money and consent sit, since two of these three features can move
-- a player's GRAM balance without them having explicitly clicked "confirm
-- this exact price" in the moment:
--   * join_gang (existing) is also the function
--     api/auth/telegram/route.ts's tryJoinGangFromStartParam calls SILENTLY
--     on every app launch for a gang invite link — it already swallows
--     every error from that call and just lands the user in the app
--     normally. So join_gang now REFUSES anything that would either need
--     leader approval or move money: gang_closed if is_closed,
--     gang_requires_payment if entry_price_gram > 0. This guarantees an
--     invite-link open (or a stray retry) can never auto-charge or
--     auto-request on someone's behalf without an explicit tap. Same
--     open+free-only shape as before this migration, just with two new
--     named rejections instead of silently joining.
--   * pay_and_join_gang (new) is the explicit-confirm path for an open
--     but paid gang: same checks as join_gang, but requires
--     entry_price_gram > 0 and actually charges. The client only calls
--     this from a confirm modal that shows the exact price first — same
--     posture as DonateModal / buy_direct_influence.
--   * request_join_gang (new) is for closed gangs. No money moves at
--     request time. One pending request per user at a time regardless of
--     which gang (partial unique index below), matching the existing
--     "one gang membership at a time" rule gang_members.user_id being
--     unique already enforces.
--   * respond_gang_join_request (new, leader-only — same "not_gang_leader"
--     gate as set_gang_member_role/kick_gang_member) is where a closed+
--     paid gang's charge actually happens, against the requester's
--     balance AT APPROVAL TIME, which can be well after the request was
--     filed. If the leader raised the price or the requester spent their
--     balance in the meantime, approval fails with
--     requester_insufficient_balance and the pending row is left for the
--     leader to retry or reject. Accepted trade-off: escrowing the price
--     at request time would mean charging someone before any human on the
--     gang's side agreed to let them in, which is worse.
--   * Both payment paths record an ordinary gang_bank_transactions row —
--     the same table bank_top_donors/bank_transactions already read — so
--     a paid join shows up in the treasury tab exactly like a donation,
--     which is what it economically is.

alter table gangs
  add column is_closed boolean not null default false,
  add column entry_price_gram numeric(14, 2) not null default 0 check (entry_price_gram >= 0),
  add column description text check (description is null or char_length(description) <= 200);

-- ---------------------------------------------------------------------------
-- gang_join_requests — one row per application to a closed gang. The
-- partial unique index is the actual "one pending application at a time"
-- guard (mirrors gang_members.user_id's plain unique for "one gang at a
-- time") — older resolved rows (approved/rejected) never block a fresh one.
-- ---------------------------------------------------------------------------
create table gang_join_requests (
  id uuid primary key default gen_random_uuid(),
  gang_id uuid not null references gangs(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references users(id)
);

create unique index gang_join_requests_one_pending_idx on gang_join_requests (user_id) where status = 'pending';
create index gang_join_requests_gang_idx on gang_join_requests (gang_id, status);

alter table gang_join_requests enable row level security;

-- ---------------------------------------------------------------------------
-- is_gang_description_clean — blacklist-only sibling of is_gang_name_clean
-- (0058_gangs.sql): a description needs punctuation/emoji/newlines that
-- name's strict alnum-only charset would reject, so this only screens the
-- same slur list, no charset restriction. Length is capped separately by
-- the gangs.description CHECK constraint above.
-- ---------------------------------------------------------------------------
create or replace function is_gang_description_clean(p_text text)
returns boolean
language sql
immutable
as $$
  select not exists (
    select 1 from unnest(array[
      'хуй', 'хуе', 'хуё', 'пизд', 'ебан', 'ебал', 'ебуч', 'сука', 'блять', 'бляд',
      'мудак', 'долбоеб', 'долбоёб', 'залуп', 'пидор', 'пидар',
      'fuck', 'shit', 'bitch', 'cunt', 'nigger', 'nigga', 'asshole'
    ]) as bad
    where lower(p_text) like '%' || bad || '%'
  );
$$;

-- ---------------------------------------------------------------------------
-- join_gang — now the open+free path only (see header). Byte-for-byte the
-- same race-condition-safe shape as 0058_gangs.sql's original (lock the
-- target gang row before counting members), with the is_closed /
-- entry_price_gram checks slotted in right after the row lock.
-- ---------------------------------------------------------------------------
create or replace function join_gang(p_user_id uuid, p_gang_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max_members integer;
  v_member_count integer;
  v_is_closed boolean;
  v_entry_price numeric(14, 2);
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  if exists (select 1 from gang_members where user_id = p_user_id) then
    raise exception 'already_in_gang';
  end if;

  select max_members, is_closed, entry_price_gram
  into v_max_members, v_is_closed, v_entry_price
  from gangs
  where id = p_gang_id
  for update;

  if not found then
    raise exception 'gang_not_found';
  end if;
  if v_is_closed then
    raise exception 'gang_closed';
  end if;
  if v_entry_price > 0 then
    raise exception 'gang_requires_payment';
  end if;

  select count(*) into v_member_count from gang_members where gang_id = p_gang_id;
  if v_member_count >= v_max_members then
    raise exception 'gang_full';
  end if;

  insert into gang_members (gang_id, user_id, role)
  values (p_gang_id, p_user_id, 'member');

  return jsonb_build_object('gang_id', p_gang_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- pay_and_join_gang — explicit-confirm join for an OPEN gang with
-- entry_price_gram > 0. Same balance-lock-then-check order every other
-- balance-deducting RPC in this schema uses; the charge lands in the
-- gang's bank via the same gang_bank_transactions insert donate_to_gang_
-- bank (0061_gang_donate_roles_kick.sql) uses, so it shows up in
-- bank_top_donors / bank_transactions like any other donation.
-- ---------------------------------------------------------------------------
create or replace function pay_and_join_gang(p_user_id uuid, p_gang_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max_members integer;
  v_member_count integer;
  v_is_closed boolean;
  v_entry_price numeric(14, 2);
  v_season_id uuid;
  v_balance numeric(14, 2);
  v_display_name text;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  if exists (select 1 from gang_members where user_id = p_user_id) then
    raise exception 'already_in_gang';
  end if;

  select max_members, is_closed, entry_price_gram
  into v_max_members, v_is_closed, v_entry_price
  from gangs
  where id = p_gang_id
  for update;

  if not found then
    raise exception 'gang_not_found';
  end if;
  if v_is_closed then
    raise exception 'gang_closed';
  end if;
  if v_entry_price <= 0 then
    raise exception 'gang_not_paid';
  end if;

  select count(*) into v_member_count from gang_members where gang_id = p_gang_id;
  if v_member_count >= v_max_members then
    raise exception 'gang_full';
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  select balance into v_balance
  from user_seasons
  where user_id = p_user_id and season_id = v_season_id
  for update;
  if v_balance is null then
    raise exception 'no_active_season';
  end if;
  if v_balance < v_entry_price then
    raise exception 'insufficient_balance';
  end if;

  update user_seasons set balance = balance - v_entry_price
  where user_id = p_user_id and season_id = v_season_id;

  update gangs
  set bank_balance_gram = bank_balance_gram + v_entry_price,
      bank_balance_ton = bank_balance_ton + v_entry_price
  where id = p_gang_id;

  insert into gang_members (gang_id, user_id, role)
  values (p_gang_id, p_user_id, 'member');

  insert into gang_bank_transactions (gang_id, from_user_id, amount_gram, amount_ton)
  values (p_gang_id, p_user_id, v_entry_price, v_entry_price);

  select coalesce(username, first_name, 'Боец') into v_display_name from users where id = p_user_id;
  insert into gang_activity_log (gang_id, user_id, message)
  values (p_gang_id, p_user_id, '🚪 ' || v_display_name || ' вступил(а) в Синдикат за ' || v_entry_price || ' GRAM!');

  return jsonb_build_object('gang_id', p_gang_id, 'paid', v_entry_price);
end;
$$;

-- ---------------------------------------------------------------------------
-- request_join_gang — files an application to a CLOSED gang. No balance
-- touched here (see header). The full-capacity check here is informational
-- only (saves the applicant a pointless wait) — respond_gang_join_request
-- re-checks it authoritatively at approval time under a row lock.
-- ---------------------------------------------------------------------------
create or replace function request_join_gang(p_user_id uuid, p_gang_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gang gangs%rowtype;
  v_member_count integer;
  v_request_id uuid;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  if exists (select 1 from gang_members where user_id = p_user_id) then
    raise exception 'already_in_gang';
  end if;
  if exists (select 1 from gang_join_requests where user_id = p_user_id and status = 'pending') then
    raise exception 'request_already_pending';
  end if;

  select * into v_gang from gangs where id = p_gang_id;
  if not found then
    raise exception 'gang_not_found';
  end if;
  if not v_gang.is_closed then
    raise exception 'gang_not_closed';
  end if;

  select count(*) into v_member_count from gang_members where gang_id = p_gang_id;
  if v_member_count >= v_gang.max_members then
    raise exception 'gang_full';
  end if;

  insert into gang_join_requests (gang_id, user_id)
  values (p_gang_id, p_user_id)
  returning id into v_request_id;

  return jsonb_build_object('request_id', v_request_id, 'gang_id', p_gang_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- respond_gang_join_request — leader-only approve/reject of a pending
-- application. Approval performs the actual join (and, for a paid gang,
-- the actual charge) atomically with resolving the request row, so a
-- request can never end up "approved" without the member actually being
-- seated, or vice versa.
-- ---------------------------------------------------------------------------
create or replace function respond_gang_join_request(p_user_id uuid, p_request_id uuid, p_approve boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_gang_id uuid;
  v_caller_role text;
  v_request gang_join_requests%rowtype;
  v_gang gangs%rowtype;
  v_member_count integer;
  v_season_id uuid;
  v_balance numeric(14, 2);
  v_display_name text;
begin
  perform pg_advisory_xact_lock(hashtext(p_user_id::text));

  select gang_id, role into v_caller_gang_id, v_caller_role
  from gang_members where user_id = p_user_id;
  if v_caller_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_caller_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  select * into v_request from gang_join_requests where id = p_request_id for update;
  if not found or v_request.gang_id <> v_caller_gang_id then
    raise exception 'request_not_found';
  end if;
  if v_request.status <> 'pending' then
    raise exception 'request_already_resolved';
  end if;

  if not p_approve then
    update gang_join_requests
    set status = 'rejected', resolved_at = now(), resolved_by = p_user_id
    where id = p_request_id;
    return jsonb_build_object('request_id', p_request_id, 'approved', false);
  end if;

  if exists (select 1 from gang_members where user_id = v_request.user_id) then
    raise exception 'requester_already_in_gang';
  end if;

  select * into v_gang from gangs where id = v_caller_gang_id for update;
  select count(*) into v_member_count from gang_members where gang_id = v_caller_gang_id;
  if v_member_count >= v_gang.max_members then
    raise exception 'gang_full';
  end if;

  if v_gang.entry_price_gram > 0 then
    v_season_id := active_season_id();
    if v_season_id is null then
      raise exception 'no_active_season';
    end if;

    select balance into v_balance
    from user_seasons
    where user_id = v_request.user_id and season_id = v_season_id
    for update;
    if v_balance is null or v_balance < v_gang.entry_price_gram then
      raise exception 'requester_insufficient_balance';
    end if;

    update user_seasons set balance = balance - v_gang.entry_price_gram
    where user_id = v_request.user_id and season_id = v_season_id;

    update gangs
    set bank_balance_gram = bank_balance_gram + v_gang.entry_price_gram,
        bank_balance_ton = bank_balance_ton + v_gang.entry_price_gram
    where id = v_caller_gang_id;

    insert into gang_bank_transactions (gang_id, from_user_id, amount_gram, amount_ton)
    values (v_caller_gang_id, v_request.user_id, v_gang.entry_price_gram, v_gang.entry_price_gram);
  end if;

  insert into gang_members (gang_id, user_id, role)
  values (v_caller_gang_id, v_request.user_id, 'member');

  update gang_join_requests
  set status = 'approved', resolved_at = now(), resolved_by = p_user_id
  where id = p_request_id;

  select coalesce(username, first_name, 'Боец') into v_display_name from users where id = v_request.user_id;
  insert into gang_activity_log (gang_id, user_id, message)
  values (v_caller_gang_id, v_request.user_id, '✅ ' || v_display_name || ' принят(а) в Синдикат по заявке!');

  return jsonb_build_object('request_id', p_request_id, 'approved', true, 'user_id', v_request.user_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- update_gang_settings — leader-only. p_description of '' (after trim) is
-- stored as null (same "empty means unset" convention the rest of this
-- schema uses for optional text). p_entry_price_gram rounds to 2dp before
-- the >= 0 check so a negative-after-rounding edge case can't slip past it.
-- ---------------------------------------------------------------------------
create or replace function update_gang_settings(
  p_user_id uuid,
  p_is_closed boolean,
  p_entry_price_gram numeric,
  p_description text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gang_id uuid;
  v_role text;
  v_price numeric(14, 2);
  v_description text;
begin
  select gang_id, role into v_gang_id, v_role from gang_members where user_id = p_user_id;
  if v_gang_id is null then
    raise exception 'not_in_gang';
  end if;
  if v_role <> 'leader' then
    raise exception 'not_gang_leader';
  end if;

  v_price := round(coalesce(p_entry_price_gram, 0), 2);
  if v_price < 0 then
    raise exception 'invalid_price';
  end if;

  v_description := nullif(trim(coalesce(p_description, '')), '');
  if v_description is not null then
    if char_length(v_description) > 200 then
      raise exception 'description_too_long';
    end if;
    if not is_gang_description_clean(v_description) then
      raise exception 'invalid_description_chars';
    end if;
  end if;

  update gangs
  set is_closed = coalesce(p_is_closed, false),
      entry_price_gram = v_price,
      description = v_description
  where id = v_gang_id;

  return jsonb_build_object(
    'gang_id', v_gang_id, 'is_closed', coalesce(p_is_closed, false),
    'entry_price_gram', v_price, 'description', v_description
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- get_gangs — adds is_closed / entry_price_gram (so the browse list can
-- show a lock/price badge and pick the right join button) and
-- my_pending_request (so an applicant sees "заявка отправлена" instead of
-- being able to spam requests — request_join_gang's partial unique index
-- is the actual guard, this is just the UI reading its own state back).
-- Otherwise byte-for-byte identical to 0066_district_wars_monetization.sql.
-- ---------------------------------------------------------------------------
create or replace function get_gangs(p_user_id uuid, p_search text default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', g.id,
    'name', g.name,
    'avatar_id', g.avatar_id,
    'premium_avatar_id', g.premium_avatar_id,
    'frame_id', g.frame_id,
    'level', g.level,
    'experience', g.experience,
    'max_members', g.max_members,
    'member_count', coalesce(mc.member_count, 0),
    'leader_name', coalesce(u.username, u.first_name, 'Игрок'),
    'is_mine', exists (select 1 from gang_members where user_id = p_user_id and gang_id = g.id),
    'is_closed', g.is_closed,
    'entry_price_gram', g.entry_price_gram,
    'description', g.description,
    'my_pending_request', exists (
      select 1 from gang_join_requests
      where user_id = p_user_id and gang_id = g.id and status = 'pending'
    )
  ) order by g.level desc, g.experience desc, g.name asc), '[]'::jsonb)
  from gangs g
  join users u on u.id = g.leader_id
  left join (
    select gang_id, count(*) as member_count from gang_members group by gang_id
  ) mc on mc.gang_id = g.id
  where p_search is null or p_search = '' or g.name ilike '%' || p_search || '%'
  limit 100;
$$;

-- ---------------------------------------------------------------------------
-- get_player_state — adds is_closed / entry_price_gram / description to
-- state.gang, plus join_requests (pending applicants, newest first) but
-- ONLY when the caller is that gang's leader — same "leader sees more"
-- posture as the management buttons in the members list already have
-- client-side. Byte-for-byte identical to 0077_gang_member_effectiveness.sql
-- otherwise.
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
  v_bank_slot_bonus integer;
  v_my_gang_id uuid;
begin
  perform resolve_due_cycles(p_user_id);
  perform expire_due_boosts(p_user_id);
  perform resolve_due_bank_payouts(p_user_id);

  select gang_id into v_my_gang_id from gang_members where user_id = p_user_id;
  if v_my_gang_id is not null then
    perform resolve_due_gang_bank_interest(v_my_gang_id);
  end if;

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

  perform ensure_daily_combo(v_season_id);
  perform resolve_due_district_battles();
  perform resolve_due_mercenary_bots();
  perform finalize_weekly_leaderboard_season();
  perform process_auto_collect_cycles();

  select case when exists (
    select 1 from bank_deposits
    where user_id = p_user_id and season_id = v_season_id
      and status = 'active' and ends_at > now() and bonus_slot
  ) then 1 else 0 end into v_bank_slot_bonus;

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
        'slots_bank_bonus', case when utp.tier is not null then v_bank_slot_bonus else 0 end,
        'slots_total', case when utp.tier is not null
          then tier_slots_open(utp.completed_cycles, pt.slot_base_count, pt.slot_max_count, pt.slot_cycles_per_level)
            + coalesce(bc.boost_count, 0) + v_bank_slot_bonus
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
    ),
    'bank_deposits', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', bd.id,
        'amount', bd.amount,
        'plan_days', bd.plan_days,
        'yield_percent', bd.yield_percent,
        'expected_reward', bd.expected_reward,
        'bonus_speed', bd.bonus_speed,
        'bonus_slot', bd.bonus_slot,
        'status', bd.status,
        'starts_at', bd.starts_at,
        'ends_at', bd.ends_at,
        'days_paid', bd.days_paid,
        'principal_paid', bd.principal_paid,
        'reward_paid', bd.reward_paid
      ) order by (bd.status = 'active') desc, bd.ends_at), '[]'::jsonb)
      from bank_deposits bd
      where bd.user_id = p_user_id and bd.season_id = v_season_id
    ),
    'bank_buffs', jsonb_build_object(
      'speed_boost', exists (
        select 1 from bank_deposits
        where user_id = p_user_id and season_id = v_season_id
          and status = 'active' and ends_at > now() and bonus_speed
      ),
      'slot_boost', v_bank_slot_bonus > 0
    ),
    'gang', (
      select jsonb_build_object(
        'id', g.id,
        'name', g.name,
        'avatar_id', g.avatar_id,
        'premium_avatar_id', g.premium_avatar_id,
        'frame_id', g.frame_id,
        'level', g.level,
        'experience', g.experience,
        'exp_into_level', g.experience % 100,
        'exp_per_level', 100,
        'max_members', g.max_members,
        'co_leader_slots', g.co_leader_slots,
        'vip_treasury', g.vip_treasury,
        'weekly_influence_points', g.weekly_influence_points,
        'leader_name', coalesce(lu.username, lu.first_name, 'Игрок'),
        'my_role', gm_self.role,
        'target_district_id', g.target_district_id,
        'target_district_name', td.name,
        'is_closed', g.is_closed,
        'entry_price_gram', g.entry_price_gram,
        'description', g.description,
        'members', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'user_id', gm.user_id,
            'display_name', coalesce(mu.username, mu.first_name, 'Игрок'),
            'photo_url', mu.photo_url,
            'role', gm.role,
            'joined_at', gm.joined_at,
            'completed_cycles', coalesce(mus.completed_cycles_total, 0),
            'donated_gram', coalesce(donated.total_amount, 0),
            'last_active_at', greatest(last_cycle.last_started_at, donated.last_donated_at)
          ) order by
            case gm.role when 'leader' then 0 when 'co_leader' then 1 else 2 end,
            gm.joined_at
          ), '[]'::jsonb)
          from gang_members gm
          join users mu on mu.id = gm.user_id
          left join user_seasons mus on mus.user_id = gm.user_id and mus.season_id = v_season_id
          left join lateral (
            select sum(gb.amount_gram) as total_amount, max(gb.created_at) as last_donated_at
            from gang_bank_transactions gb
            where gb.gang_id = g.id and gb.from_user_id = gm.user_id
          ) donated on true
          left join lateral (
            select max(c.started_at) as last_started_at
            from cycles c
            where c.user_id = gm.user_id and c.season_id = v_season_id
          ) last_cycle on true
          where gm.gang_id = g.id
        ),
      'join_requests', case when gm_self.role = 'leader' then (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', jr.id,
          'user_id', jr.user_id,
          'display_name', coalesce(ju.username, ju.first_name, 'Игрок'),
          'photo_url', ju.photo_url,
          'created_at', jr.created_at
        ) order by jr.created_at), '[]'::jsonb)
        from gang_join_requests jr
        join users ju on ju.id = jr.user_id
        where jr.gang_id = g.id and jr.status = 'pending'
      ) else '[]'::jsonb end,
      'bank_balance_gram', g.bank_balance_gram,
      'bank_balance_ton', g.bank_balance_ton,
      'bank_top_donors', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'user_id', donors.from_user_id,
          'display_name', coalesce(du.username, du.first_name, 'Игрок'),
          'photo_url', du.photo_url,
          'amount', donors.total_amount
        ) order by donors.total_amount desc, donors.from_user_id), '[]'::jsonb)
        from (
          select gb.from_user_id, sum(gb.amount_gram) as total_amount
          from gang_bank_transactions gb
          where gb.gang_id = g.id
          group by gb.from_user_id
          order by total_amount desc
          limit 20
        ) donors
        join users du on du.id = donors.from_user_id
      ),
      'bank_transactions', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', gb.id,
          'from_user_id', gb.from_user_id,
          'display_name', coalesce(du.username, du.first_name, 'Игрок'),
          'photo_url', du.photo_url,
          'amount_gram', gb.amount_gram,
          'created_at', gb.created_at
        ) order by gb.created_at desc), '[]'::jsonb)
        from (
          select * from gang_bank_transactions
          where gang_id = g.id
          order by created_at desc
          limit 20
        ) gb
        join users du on du.id = gb.from_user_id
      ),
      'activity_feed', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', al.id, 'message', al.message, 'created_at', al.created_at
        ) order by al.created_at desc), '[]'::jsonb)
        from (
          select * from gang_activity_log
          where gang_id = g.id
          order by created_at desc
          limit 10
        ) al
      )
      )
      from gang_members gm_self
      join gangs g on g.id = gm_self.gang_id
      join users lu on lu.id = g.leader_id
      left join districts td on td.id = g.target_district_id
      where gm_self.user_id = p_user_id
    )
  ) into v_result;

  return v_result;
end;
$$;
