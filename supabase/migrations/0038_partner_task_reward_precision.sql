-- 100ГРАМ: partner_tasks.reward_amount couldn't actually hold 0.003 GRAM —
-- numeric(12, 2) rounds to 2 decimal places *at the storage layer*, so the
-- task's reward was already silently stored as 0.00 the moment it was
-- created via the admin panel, long before the "Связи на районе" list ever
-- rendered it with .toFixed(2). Widened to numeric(12, 4) and the one
-- affected row repaired back to its intended 0.003. claim_partner_task's
-- local v_reward variable had the same numeric(12, 2) declaration — even
-- with the column fixed, assigning reward_amount into that variable would
-- have silently re-truncated it right back to 0.00 at claim time, so the
-- actual GRAM credited would still have been wrong even though the table
-- and UI looked correct. Widened that too.
alter table partner_tasks alter column reward_amount type numeric(12, 4);

update partner_tasks
set reward_amount = 0.003
where id = 'be30eacf-e00e-4519-828f-07a7a5a6e540';

CREATE OR REPLACE FUNCTION public.claim_partner_task(p_user_id uuid, p_task_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_season_id uuid;
  v_reward numeric(12, 4);
  v_active boolean;
begin
  select season_id, reward_amount, is_active
  into v_season_id, v_reward, v_active
  from partner_tasks where id = p_task_id;

  if v_season_id is null or v_season_id <> active_season_id() or not v_active then
    raise exception 'unknown_task';
  end if;

  insert into user_partner_tasks (user_id, task_id, season_id)
  values (p_user_id, p_task_id, v_season_id)
  on conflict (user_id, task_id) do nothing;

  if not found then
    raise exception 'already_claimed';
  end if;

  update user_seasons set balance = balance + v_reward, total_earned = total_earned + v_reward
  where user_id = p_user_id and season_id = v_season_id;

  return v_reward;
end;
$function$

;
