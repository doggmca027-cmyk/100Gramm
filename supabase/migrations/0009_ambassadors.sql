-- 100ГРАМ: ambassador tagging + per-level referral/deposit stats for admins.
-- "Депозит" here means GRAM committed into cycles (amount_in) — the virtual
-- game currency, same meaning as everywhere else in this schema.

alter table users add column if not exists is_ambassador boolean not null default false;

-- ---------------------------------------------------------------------------
-- get_ambassador_stats — for every tagged ambassador, referred_count and
-- total_deposited (sum of amount_in across all their cycles, any status) at
-- each of the 3 referral levels below them.
-- ---------------------------------------------------------------------------
create or replace function get_ambassador_stats()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', stats.id,
    'telegram_id', stats.telegram_id,
    'username', stats.username,
    'first_name', stats.first_name,
    'levels', jsonb_build_array(
      jsonb_build_object('level', 1, 'referred_count', stats.l1_count, 'total_deposited', stats.l1_deposit),
      jsonb_build_object('level', 2, 'referred_count', stats.l2_count, 'total_deposited', stats.l2_deposit),
      jsonb_build_object('level', 3, 'referred_count', stats.l3_count, 'total_deposited', stats.l3_deposit)
    )
  )), '[]'::jsonb)
  from (
    select
      a.id, a.telegram_id, a.username, a.first_name,
      l1.referred_count as l1_count, l1.total_deposited as l1_deposit,
      l2.referred_count as l2_count, l2.total_deposited as l2_deposit,
      l3.referred_count as l3_count, l3.total_deposited as l3_deposit
    from users a
    cross join lateral (
      select count(distinct u1.id) as referred_count, coalesce(sum(c.amount_in), 0) as total_deposited
      from users u1
      left join cycles c on c.user_id = u1.id
      where u1.referred_by = a.id
    ) l1
    cross join lateral (
      select count(distinct u2.id) as referred_count, coalesce(sum(c.amount_in), 0) as total_deposited
      from users u1
      join users u2 on u2.referred_by = u1.id
      left join cycles c on c.user_id = u2.id
      where u1.referred_by = a.id
    ) l2
    cross join lateral (
      select count(distinct u3.id) as referred_count, coalesce(sum(c.amount_in), 0) as total_deposited
      from users u1
      join users u2 on u2.referred_by = u1.id
      join users u3 on u3.referred_by = u2.id
      left join cycles c on c.user_id = u3.id
      where u1.referred_by = a.id
    ) l3
    where a.is_ambassador
  ) stats;
$$;
