-- Remove the "join project chat" social task (social_community_chat /
-- "Свои в чате"). Deleting the system_tasks row cascades to
-- system_task_rewards and user_completed_tasks (both declared
-- `references system_tasks(id) on delete cascade` in 0028), so no manual
-- cleanup of those tables is needed. Users who already completed it keep
-- whatever items/XP they were granted — only the task definition and its
-- completion record disappear, and get_player_state stops listing it since
-- that block is driven entirely off the system_tasks table (0045).
--
-- The channel subscription task (social_main_channel) is untouched.

delete from system_tasks where slug = 'social_community_chat';
