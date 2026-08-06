-- 100ГРАМ: launch prep — real channel/chat usernames are in now, so the
-- two social tasks that need one go live. "Разведка на районе"
-- (social_intel_post) still has no post link, so it stays inactive until
-- one's provided — see 0028_system_tasks.sql's header for why these
-- shipped inactive in the first place.
update system_tasks
set target_value = 'GRam100_NEWS', is_active = true
where slug = 'social_main_channel';

update system_tasks
set target_value = 'Gram100Syndicate', is_active = true
where slug = 'social_community_chat';
