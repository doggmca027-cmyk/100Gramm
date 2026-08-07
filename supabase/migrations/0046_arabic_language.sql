-- Adds Arabic ('ar') as a full 5th language across the app. The static UI
-- dictionary lives entirely client-side (src/lib/i18n/dictionaries/ar.ts) —
-- this migration is the DB half: seed 'ar' translations into every
-- existing _i18n jsonb column (season, tiers, ranks, daily quests — ru
-- stays the base/fallback column, en/tr/id/ar all live in the jsonb), and
-- add an 'ar' key to every jsonb_build_object('ru', ..., 'en', ..., 'tr',
-- ..., 'id', ...) call site inside get_player_state (the only function
-- with this pattern — confirmed via grep across all migrations).

-- ---------------------------------------------------------------------------
-- Content translations
-- ---------------------------------------------------------------------------

update seasons set
  title_i18n = title_i18n || '{"ar": "🍾 الزجاجة الأخيرة"}'::jsonb,
  story_theme_i18n = story_theme_i18n || '{"ar": "البقاء والانطلاقة — من متشرد لا يملك فلسًا واحدًا إلى أول أموال حقيقية في المدينة."}'::jsonb
where slug = 'season-1';

update product_templates pt set
  name_i18n = name_i18n || v.name_ar::jsonb,
  description_i18n = description_i18n || v.desc_ar::jsonb
from (values
  (1, '{"ar": "زجاجة قديمة"}', '{"ar": "فرصتك الأخيرة للنجاة يومًا آخر."}'),
  (2, '{"ar": "صندوق جامع الشارع"}', '{"ar": "الآن أصبح لديك مخزون صغير."}'),
  (3, '{"ar": "عربة المتشرد"}', '{"ar": "أصبح نقل الغنيمة أسهل بكثير."}'),
  (4, '{"ar": "نقطة استلام"}', '{"ar": "أول صفقاتك الجادة بدأت تُؤتي ثمارها."}'),
  (5, '{"ar": "حانة صغيرة"}', '{"ar": "زاويتك الخاصة لاستقبال الضيوف."}'),
  (6, '{"ar": "متجر الخمور"}', '{"ar": "عملاء دائمون ودخل مستقر."}'),
  (7, '{"ar": "سلسلة متاجر"}', '{"ar": "اسمك بات معروفًا في كل حي."}'),
  (8, '{"ar": "إمبراطورية 100GRAM"}', '{"ar": "أنت تسيطر على سوق المدينة بأكمله."}')
) as v(tier, name_ar, desc_ar)
join seasons s on s.slug = 'season-1'
where pt.season_id = s.id and pt.tier = v.tier;

update ranks r set
  name_i18n = name_i18n || v.name_ar::jsonb
from (values
  (1, '{"ar": "متشرد"}'),
  (2, '{"ar": "جامع الزجاجات"}'),
  (3, '{"ar": "تاجر الشارع"}'),
  (4, '{"ar": "صاحب الحانة"}'),
  (5, '{"ar": "إمبراطور 100GRAM"}')
) as v(sort_order, name_ar)
join seasons s on s.slug = 'season-1'
where r.season_id = s.id and r.sort_order = v.sort_order;

update quest_templates qt set
  title_i18n = title_i18n || v.title_ar::jsonb,
  description_i18n = description_i18n || v.desc_ar::jsonb
from (values
  ('Разгрузка', '{"ar": "تفريغ"}', '{"ar": "أكمل دورتين اليوم"}'),
  ('Срочный заказ', '{"ar": "طلب عاجل"}', '{"ar": "الحانة في الحي بحاجة عاجلة لإمدادات — أكمل 5 دورات"}')
) as v(title_ru, title_ar, desc_ar)
where qt.title = v.title_ru;

-- ---------------------------------------------------------------------------
-- get_player_state — every _i18n jsonb_build_object call site now also
-- returns 'ar'. Structurally identical to the previous version
-- (0045_system_task_delayed_reward.sql) otherwise — diffed to confirm
-- before writing this migration.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_player_state(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        'title_i18n', jsonb_build_object('ru', s.title, 'en', s.title_i18n->>'en', 'tr', s.title_i18n->>'tr', 'id', s.title_i18n->>'id', 'ar', s.title_i18n->>'ar'),
        'story_theme_i18n', jsonb_build_object('ru', s.story_theme, 'en', s.story_theme_i18n->>'en', 'tr', s.story_theme_i18n->>'tr', 'id', s.story_theme_i18n->>'id', 'ar', s.story_theme_i18n->>'ar'),
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
        'name_i18n', jsonb_build_object('ru', r.name, 'en', r.name_i18n->>'en', 'tr', r.name_i18n->>'tr', 'id', r.name_i18n->>'id', 'ar', r.name_i18n->>'ar'),
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
        'name_i18n', jsonb_build_object('ru', pt.name, 'en', pt.name_i18n->>'en', 'tr', pt.name_i18n->>'tr', 'id', pt.name_i18n->>'id', 'ar', pt.name_i18n->>'ar'),
        'description_i18n', jsonb_build_object('ru', pt.description, 'en', pt.description_i18n->>'en', 'tr', pt.description_i18n->>'tr', 'id', pt.description_i18n->>'id', 'ar', pt.description_i18n->>'ar'),
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
        'title_i18n', jsonb_build_object('ru', qt.title, 'en', qt.title_i18n->>'en', 'tr', qt.title_i18n->>'tr', 'id', qt.title_i18n->>'id', 'ar', qt.title_i18n->>'ar'),
        'description_i18n', jsonb_build_object('ru', qt.description, 'en', qt.description_i18n->>'en', 'tr', qt.description_i18n->>'tr', 'id', qt.description_i18n->>'id', 'ar', qt.description_i18n->>'ar'),
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
        'channel_username', pt.channel_username,
        'icon_url', pt.icon_url,
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
            'name_i18n', jsonb_build_object('ru', pt.name, 'en', pt.name_i18n->>'en', 'tr', pt.name_i18n->>'tr', 'id', pt.name_i18n->>'id', 'ar', pt.name_i18n->>'ar')
          ) order by pt.tier), '[]'::jsonb)
          from product_templates pt where pt.season_id = v_season_id
        ),
        'last_guess', case when ucp.last_guess_tiers is not null then (
          select coalesce(jsonb_agg(jsonb_build_object(
            'tier', g.tier, 'correct', g.correct, 'name', pt.name,
            'name_i18n', jsonb_build_object('ru', pt.name, 'en', pt.name_i18n->>'en', 'tr', pt.name_i18n->>'tr', 'id', pt.name_i18n->>'id', 'ar', pt.name_i18n->>'ar')
          ) order by g.ord), '[]'::jsonb)
          from unnest(ucp.last_guess_tiers, ucp.last_guess_correct) with ordinality as g(tier, correct, ord)
          join product_templates pt on pt.season_id = v_season_id and pt.tier = g.tier
        ) else null end,
        'revealed_tiers', case when coalesce(ucp.is_completed, false) then (
          select coalesce(jsonb_agg(jsonb_build_object(
            'tier', u.t, 'name', pt.name,
            'name_i18n', jsonb_build_object('ru', pt.name, 'en', pt.name_i18n->>'en', 'tr', pt.name_i18n->>'tr', 'id', pt.name_i18n->>'id', 'ar', pt.name_i18n->>'ar')
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
$function$
;
