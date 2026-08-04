-- 100ГРАМ: multilingual game content. Each *_i18n column holds only the
-- non-Russian translations {en, tr, id} — the existing plain column stays
-- the Russian/base text and RU source of truth. get_player_state composes
-- both into one {ru, en, tr, id} object per field so the client can switch
-- language instantly with no refetch.

alter table seasons add column if not exists title_i18n jsonb not null default '{}'::jsonb;
alter table seasons add column if not exists story_theme_i18n jsonb not null default '{}'::jsonb;
alter table product_templates add column if not exists name_i18n jsonb not null default '{}'::jsonb;
alter table product_templates add column if not exists description_i18n jsonb not null default '{}'::jsonb;
alter table ranks add column if not exists name_i18n jsonb not null default '{}'::jsonb;
alter table quest_templates add column if not exists title_i18n jsonb not null default '{}'::jsonb;
alter table quest_templates add column if not exists description_i18n jsonb not null default '{}'::jsonb;

update seasons
set title_i18n = '{"en": "🍾 The Last Bottle", "tr": "🍾 Son Şişe", "id": "🍾 Botol Terakhir"}'::jsonb,
    story_theme_i18n = '{
      "en": "Survival & Foundation — from a penniless bum to the city''s first real money.",
      "tr": "Hayatta Kalma ve Temel — meteliksiz bir serseriden şehrin ilk gerçek parasına.",
      "id": "Bertahan Hidup & Fondasi — dari gelandangan tak berduit menuju uang pertama di kota."
    }'::jsonb
where slug = 'season-1';

with s as (select id from seasons where slug = 'season-1')
update product_templates pt
set name_i18n = v.name_i18n, description_i18n = v.description_i18n
from s, (values
  (1, '{"en": "Old Bottle", "tr": "Eski Şişe", "id": "Botol Tua"}'::jsonb,
      '{"en": "Your last chance to survive one more day.", "tr": "Bir gün daha hayatta kalmak için son şansın.", "id": "Kesempatan terakhirmu untuk bertahan satu hari lagi."}'::jsonb),
  (2, '{"en": "Street Collector''s Crate", "tr": "Sokak Toplayıcısının Sandığı", "id": "Peti Pemulung Jalanan"}'::jsonb,
      '{"en": "Now you''ve got a small stash.", "tr": "Artık küçük bir stokun var.", "id": "Sekarang kamu punya sedikit simpanan."}'::jsonb),
  (3, '{"en": "Bum''s Cart", "tr": "Serserinin El Arabası", "id": "Gerobak Gelandangan"}'::jsonb,
      '{"en": "Hauling your loot just got a lot easier.", "tr": "Ganimeti taşımak artık çok daha kolay.", "id": "Membawa hasil jarahan jadi jauh lebih mudah."}'::jsonb),
  (4, '{"en": "Recycling Point", "tr": "Geri Dönüşüm Noktası", "id": "Titik Daur Ulang"}'::jsonb,
      '{"en": "Your first real deals start paying off.", "tr": "İlk ciddi anlaşmaların kâr getirmeye başlıyor.", "id": "Kesepakatan seriusmu yang pertama mulai membuahkan hasil."}'::jsonb),
  (5, '{"en": "Small Bar", "tr": "Küçük Bar", "id": "Bar Kecil"}'::jsonb,
      '{"en": "Your own corner to host guests.", "tr": "Misafir ağırlayabileceğin kendi köşen.", "id": "Sudut milikmu sendiri untuk menjamu tamu."}'::jsonb),
  (6, '{"en": "Liquor Shop", "tr": "İçki Dükkanı", "id": "Toko Minuman Keras"}'::jsonb,
      '{"en": "Regular customers and steady income.", "tr": "Düzenli müşteriler ve istikrarlı gelir.", "id": "Pelanggan tetap dan pendapatan stabil."}'::jsonb),
  (7, '{"en": "Chain of Stores", "tr": "Mağaza Zinciri", "id": "Jaringan Toko"}'::jsonb,
      '{"en": "Your name is known in every district.", "tr": "Adın her mahallede biliniyor.", "id": "Namamu dikenal di setiap distrik."}'::jsonb),
  (8, '{"en": "100GRAM Empire", "tr": "100GRAM İmparatorluğu", "id": "Kerajaan 100GRAM"}'::jsonb,
      '{"en": "You control the entire city market.", "tr": "Tüm şehir pazarını kontrol ediyorsun.", "id": "Kamu menguasai seluruh pasar kota."}'::jsonb)
) as v(tier, name_i18n, description_i18n)
where pt.season_id = s.id and pt.tier = v.tier;

with s as (select id from seasons where slug = 'season-1')
update ranks r
set name_i18n = v.name_i18n
from s, (values
  (1, '{"en": "Bum", "tr": "Serseri", "id": "Gelandangan"}'::jsonb),
  (2, '{"en": "Bottle Collector", "tr": "Şişe Toplayıcısı", "id": "Pengumpul Botol"}'::jsonb),
  (3, '{"en": "Street Dealer", "tr": "Sokak Satıcısı", "id": "Pedagang Jalanan"}'::jsonb),
  (4, '{"en": "Bar Owner", "tr": "Bar Sahibi", "id": "Pemilik Bar"}'::jsonb),
  (5, '{"en": "Emperor of 100GRAM", "tr": "100GRAM İmparatoru", "id": "Kaisar 100GRAM"}'::jsonb)
) as v(sort_order, name_i18n)
where r.season_id = s.id and r.sort_order = v.sort_order;

with s as (select id from seasons where slug = 'season-1')
update quest_templates qt
set title_i18n = v.title_i18n, description_i18n = v.description_i18n
from s, (values
  ('daily_2_cycles',
   '{"en": "Unloading", "tr": "Boşaltma", "id": "Bongkar Muat"}'::jsonb,
   '{"en": "Complete 2 cycles today", "tr": "Bugün 2 döngü tamamla", "id": "Selesaikan 2 siklus hari ini"}'::jsonb),
  ('daily_5_cycles',
   '{"en": "Urgent order", "tr": "Acil sipariş", "id": "Pesanan mendesak"}'::jsonb,
   '{"en": "The neighborhood bar urgently needs supplies — complete 5 cycles", "tr": "Mahalledeki bar acilen mal arıyor — 5 döngü tamamla", "id": "Bar di lingkungan butuh pasokan segera — selesaikan 5 siklus"}'::jsonb)
) as v(code, title_i18n, description_i18n)
where qt.season_id = s.id and qt.code = v.code;

-- ---------------------------------------------------------------------------
-- get_player_state — every translatable field now ships as {ru, en, tr, id}
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

  v_season_id := active_season_id();
  if v_season_id is null then
    raise exception 'no_active_season';
  end if;

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
        'username', u.username, 'first_name', u.first_name, 'photo_url', u.photo_url
      )
      from users u where u.id = p_user_id
    ),
    'wallet', (
      select jsonb_build_object(
        'balance', us.balance,
        'total_earned', us.total_earned,
        'slots_count', us.slots_count,
        'completed_cycles_total', us.completed_cycles_total,
        'has_seen_intro', us.has_seen_intro
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
        'unlocked_at', utp.unlocked_at
      ) order by pt.tier), '[]'::jsonb)
      from product_templates pt
      left join user_tier_progress utp
        on utp.season_id = v_season_id and utp.tier = pt.tier and utp.user_id = p_user_id
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
        'channel_username', pt.channel_username,
        'icon_url', pt.icon_url,
        'completed', (upt.task_id is not null)
      ) order by pt.sort_order), '[]'::jsonb)
      from partner_tasks pt
      left join user_partner_tasks upt
        on upt.task_id = pt.id and upt.user_id = p_user_id
      where pt.season_id = v_season_id and pt.is_active
    ),
    'squad', jsonb_build_object(
      'invite_code', (select telegram_id::text from users where id = p_user_id),
      'referred_count', (select count(*) from users where referred_by = p_user_id),
      'earned_total', (select coalesce(sum(amount), 0) from referral_earnings where beneficiary_id = p_user_id)
    )
  ) into v_result;

  return v_result;
end;
$$;
