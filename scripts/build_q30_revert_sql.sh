#!/usr/bin/env bash
# Builds the Q30-only REVERT file for the SQL Editor (outside the repo): undoes 20261031220000_q30_one_time_fee_include.
# one_time_fee_policy include -> pending_kyle, column default back to pending_kyle, the Q30 history row deleted, a
# recon.config.decision event written. One transaction; refuses unless the row exists and the value is 'include'.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-/workspace/aca_system_deploy/q30_revert.sql}"
cat > "$out" <<'SQL'
-- Q30 REVERT (undoes q30_set_one_time_fee_include.sql). SQL Editor, as postgres (break-glass, audited). Only if Kyle reverses Q30.
-- Sets recon_pay_config.one_time_fee_policy include -> pending_kyle (S18 goes back to OPEN, pay NULL), the column default
-- back to pending_kyle, deletes the Q30 migration record and writes a recon.config.decision event. One transaction.
-- Refuses (changes nothing) unless slice three is applied, the recon_pay_config row exists and the value is 'include'.
-- Expected final grid: one row: one_time_fee_policy = pending_kyle, column_default_pending = true, migration_recorded = false, revert_events = 1.
begin;
do $$
declare n int;
begin
  if to_regclass('public.recon_pay_config') is null then raise exception 'Q30 revert: slice three is not applied'; end if;
  if not exists (select 1 from public.recon_pay_config where id) then raise exception 'Q30 revert: the recon_pay_config row is missing: nothing changed'; end if;
  if (select one_time_fee_policy from public.recon_pay_config where id) <> 'include' then
    raise exception 'Q30 revert: one_time_fee_policy is %, not include: nothing changed', (select one_time_fee_policy from public.recon_pay_config where id);
  end if;
  alter table public.recon_pay_config alter column one_time_fee_policy set default 'pending_kyle';
  update public.recon_pay_config
     set one_time_fee_policy = 'pending_kyle',
         note = concat_ws(' | ', nullif(note, ''), 'one_time_fee_policy reverted to pending_kyle (Q30 revert)')
   where id and one_time_fee_policy = 'include';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'Q30 revert: expected to change 1 row, changed %', n; end if;
  insert into public.event_log (event_type, actor_uid, actor_role, table_name, row_id, action, detail)
  values ('recon.config.decision', public.audit_actor_uid(), public.audit_actor_role(), 'recon_pay_config', 'true', 'EVENT',
          jsonb_build_object('setting', 'one_time_fee_policy', 'from', 'include', 'to', 'pending_kyle',
                             'reason', 'Q30 revert (undo of Kyle direct 10/31 9:04 PM Q30)',
                             'path', case when public.audit_actor_role() in ('postgres', 'supabase_admin') then 'break-glass:' || public.audit_actor_role() else public.audit_actor_role() end));
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261031220000';
  end if;
end $$;
commit;

notify pgrst, 'reload schema';

select c.one_time_fee_policy,
       (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'recon_pay_config'
          and column_name = 'one_time_fee_policy') ~ 'pending_kyle' as column_default_pending,
       exists (select 1 from supabase_migrations.schema_migrations where version = '20261031220000') as migration_recorded,
       (select count(*) from public.event_log where event_type = 'recon.config.decision' and detail->>'setting' = 'one_time_fee_policy'
          and detail->>'to' = 'pending_kyle') as revert_events
  from public.recon_pay_config c where c.id;
SQL
sha256sum "$out"
