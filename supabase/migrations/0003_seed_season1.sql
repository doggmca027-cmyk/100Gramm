-- 100ГРАМ: Season 1 — «Последняя бутылка». Numbers match docs/GDD.md §1.
-- Adding Season 2+ later = new INSERTs here, no schema/engine changes.

insert into seasons (slug, title, story_theme, starts_at, ends_at, is_active, config)
values (
  'season-1',
  '🍾 Последняя бутылка',
  'Survival & Foundation — от бомжа без гроша до первых денег города.',
  now(),
  now() + interval '30 days',
  true,
  jsonb_build_object(
    'base_slots', 3,
    'cycles_per_slot', 5,
    'max_slots', null,
    'features', jsonb_build_object('clans', false, 'map', false, 'bank', false, 'black_market', false)
  )
);

with s as (select id from seasons where slug = 'season-1')
insert into product_templates (season_id, tier, name, price, payout_percent, cycle_hours, unlock_required_cycles, unlock_min_hours, sort_order)
select s.id, v.tier, v.name, v.price, v.payout_percent, v.cycle_hours, v.unlock_required_cycles, v.unlock_min_hours, v.tier
from s, (values
  (1, 'Старая бутылка',            1::numeric,  15::numeric,  8::numeric, 10, 80::numeric),
  (2, 'Ящик уличного собирателя',  2::numeric,  18::numeric, 12::numeric,  8, 96::numeric),
  (3, 'Тележка бомжа',             3::numeric,  22::numeric, 18::numeric,  7, 126::numeric),
  (4, 'Пункт приёма',              4::numeric,  27::numeric, 24::numeric,  5, 120::numeric),
  (5, 'Маленький бар',             5::numeric,  33::numeric, 36::numeric,  5, 180::numeric),
  (6, 'Алкогольная лавка',        10::numeric,  40::numeric, 48::numeric,  4, 192::numeric),
  (7, 'Сеть магазинов',           15::numeric,  50::numeric, 60::numeric,  4, 240::numeric),
  (8, 'Империя 100ГРАМ',          20::numeric,  60::numeric, 56::numeric,  0, 0::numeric)
) as v(tier, name, price, payout_percent, cycle_hours, unlock_required_cycles, unlock_min_hours);

with s as (select id from seasons where slug = 'season-1')
insert into ranks (season_id, min_earned, name, icon, slot_bonus, sort_order)
select s.id, v.min_earned, v.name, v.icon, v.slot_bonus, v.sort_order
from s, (values
  (0::numeric,    'Бомж',                '🥴', 0, 1),
  (50::numeric,   'Собиратель бутылок',  '🥃', 1, 2),
  (300::numeric,  'Уличный торговец',    '🍺', 0, 3),
  (1500::numeric, 'Владелец бара',       '🏪', 1, 4),
  (6000::numeric, 'Император 100ГРАМ',   '👑', 2, 5)
) as v(min_earned, name, icon, slot_bonus, sort_order);

with s as (select id from seasons where slug = 'season-1')
insert into quest_templates (season_id, code, title, description, target_count, reward_amount, is_daily)
select s.id, v.code, v.title, v.description, v.target_count, v.reward_amount, true
from s, (values
  ('daily_2_cycles', 'Разгрузка', 'Заверши 2 цикла сегодня', 2, 1::numeric),
  ('daily_5_cycles', 'Срочный заказ', 'Бар на районе срочно ищет поставку — заверши 5 циклов', 5, 3::numeric)
) as v(code, title, description, target_count, reward_amount);

with s as (select id from seasons where slug = 'season-1')
insert into container_templates (season_id, code, name, open_duration_minutes, reward_min, reward_max, drop_weight)
select s.id, v.code, v.name, 60, v.reward_min, v.reward_max, v.drop_weight
from s, (values
  ('trash',  '🗑 Мусорный контейнер',  0.1::numeric, 0.3::numeric, 50),
  ('old',    '📦 Старый контейнер',    0.3::numeric, 0.8::numeric, 30),
  ('locked', '🔒 Закрытый контейнер',  0.8::numeric, 2.0::numeric, 15),
  ('golden', '💎 Золотой контейнер',   2.0::numeric, 5.0::numeric, 5)
) as v(code, name, reward_min, reward_max, drop_weight);
