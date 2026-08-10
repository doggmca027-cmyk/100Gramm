-- Gangs launched with max_members default 20 (0058_gangs.sql); spec calls
-- for a starting capacity of 10, not 20. Change the column default for
-- gangs founded from now on, and backfill every already-existing gang that
-- is still sitting at the untouched default of 20 (there's no per-gang
-- capacity-upgrade feature yet, so "still 20" and "never customized" are
-- the same set of rows -- safe to backfill unconditionally).
alter table gangs alter column max_members set default 10;

update gangs set max_members = 10 where max_members = 20;
