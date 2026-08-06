-- user_seasons.balance / total_earned were numeric(14, 2), so any addition
-- rounded to 2 decimal places at the storage layer — same class of bug as
-- 0038_partner_task_reward_precision.sql (which widened reward_amount and
-- claim_partner_task's v_reward to numeric(12, 4)), but the destination
-- columns on user_seasons were never widened, so e.g. crediting 0.003 GRAM
-- still got silently rounded away the moment it landed in the wallet.
-- Widened to numeric(14, 4) so sub-cent rewards actually persist.
alter table user_seasons alter column balance type numeric(14, 4);
alter table user_seasons alter column total_earned type numeric(14, 4);
