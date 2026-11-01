#!/usr/bin/env bash
# Builds the one-shot SQL Editor file for Q30 (Kyle direct 10/31 9:04 PM): the migration + its history row, one
# transaction, ending with a SELECT of the new value. Output goes OUTSIDE the repo.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-/workspace/aca_system_deploy/q30_set_one_time_fee_include.sql}"
M=supabase/migrations/20261031220000_q30_one_time_fee_include.sql
{
  echo "-- Q30 (Kyle direct 10/31 9:04 PM ET): include one-time fees in the commission premium. SQL Editor, as postgres (break-glass, audited)."
  echo "-- Changes ONE setting (recon_pay_config.one_time_fee_policy pending_kyle -> include) only if it is still pending_kyle; re-running is a no-op."
  echo "-- Expected final grid: one row: one_time_fee_policy = include, column_default_include = true, migration_recorded = true, decision_events = 1."
  echo "begin;"
  echo "do \$\$ begin"
  echo "  if to_regclass('public.recon_pay_config') is null then raise exception 'Q30: slice three is not applied'; end if;"
  echo "  if (select one_time_fee_policy from public.recon_pay_config where id) not in ('pending_kyle', 'include') then"
  echo "    raise exception 'Q30: one_time_fee_policy is %, not pending_kyle: not changed (owner already chose)', (select one_time_fee_policy from public.recon_pay_config where id);"
  echo "  end if;"
  echo "end \$\$;"
  echo; echo "-- ===== $M ====="; cat "$M"
  echo
  echo "insert into supabase_migrations.schema_migrations (version, name, statements)"
  echo "values ('20261031220000', 'q30_one_time_fee_include', array['Q30 one_time_fee_policy include (Kyle direct 10/31 9:04 PM)'])"
  echo "on conflict (version) do nothing;"
  echo "commit;"
  echo
  echo "notify pgrst, 'reload schema';"
  echo
  echo "select c.one_time_fee_policy,"
  echo "       (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'recon_pay_config'"
  echo "          and column_name = 'one_time_fee_policy') ~ 'include' as column_default_include,"
  echo "       exists (select 1 from supabase_migrations.schema_migrations where version = '20261031220000') as migration_recorded,"
  echo "       (select count(*) from public.event_log where event_type = 'recon.config.decision' and detail->>'setting' = 'one_time_fee_policy'"
  echo "          and detail->>'to' = 'include') as decision_events"
  echo "  from public.recon_pay_config c where c.id;"
} > "$out"
sha256sum "$out"
