#!/usr/bin/env bash
# LOCAL ONLY. Runs every slice-three test against throwaway databases on a local Postgres with the Supabase stub.
# Usage: PGHOST=/tmp PGPORT=54329 PGUSER=postgres scripts/local_test_slice3.sh
set -uo pipefail
cd "$(dirname "$0")/.."
PASTE=${PASTE:-/workspace/aca_system_deploy/slice3_paste.sql}
PASTE2=${PASTE2:-/workspace/aca_system_deploy/slice2_paste.sql}
RB=supabase/rollback/slice3_rollback.sql
PF=supabase/deploy/slice3_preflight.sql
S1SEED=${S1SEED:-80f2572}   # the slice-one seed as applied live (main's seed.sql now carries slice-two columns)
declare -a RES
res(){ RES+=("$1|$2|$3"); printf '%-5s | %s | %s\n' "$2" "$1" "$3"; }
newdb(){ psql -q -d postgres -c "drop database if exists $1" -c "create database $1" >/dev/null 2>&1
  psql -q -v ON_ERROR_STOP=1 -d $1 -f supabase/tests/local_supabase_stub.sql >/dev/null 2>&1
  psql -q -d $1 -c "insert into auth.users(email) values ('admin.test@example.com'),('agent.test@example.com')" >/dev/null; }
liveish(){ newdb $1; for f in supabase/migrations/2026103119*.sql; do psql -q -v ON_ERROR_STOP=1 -d $1 -f $f >/dev/null 2>&1 || echo "FAIL $f"; done
  git show $S1SEED:supabase/seed.sql | psql -q -v ON_ERROR_STOP=1 -d $1 >/dev/null 2>&1 || echo "FAIL slice-one seed"
  [ "${2:-}" = noslice2 ] || psql -X -q -v ON_ERROR_STOP=1 -d $1 -f $PASTE2 >/dev/null 2>&1 || echo "FAIL slice-two paste"; }
q(){ psql -X -At -v ON_ERROR_STOP=1 -d "$@" 2>/dev/null; }
passes(){ psql -X -q -v ON_ERROR_STOP=1 -d $1 -f $2 2>/dev/null | grep -cE '\| PASS'; }
total(){ psql -X -q -d $1 -f $2 2>/dev/null | grep -cE '^ +[0-9]+ \| (PASS|FAIL)'; }
fails(){ psql -X -q -v ON_ERROR_STOP=1 -d $1 -f $2 2>/dev/null | grep -E '\| FAIL' | tr -s ' ' | cut -c1-140 | paste -sd';'; }
# Data snapshot of every pre-existing table (sales without the two new nullable columns, so it compares across apply/rollback)
SNAP="select md5(string_agg(t,'|' order by t)) from (
  select 's'||(to_jsonb(s) - 'premier_member_id' - 'lead_source')::text t from sales s union all select 'a'||row(a.*)::text from agents a
  union all select 'c'||row(c.*)::text from contacts c union all select 'p'||row(p.*)::text from applications p
  union all select 'm'||row(m.*)::text from call_metrics m union all select 'k'||row(k.*)::text from commission_config k
  union all select 'e'||row(e.*)::text from expenses e union all select 'x'||row(x.*)::text from expense_categories x
  union all select 'r'||row(r.*)::text from revenue_adjustments r) x"
SCHEMA="select md5(string_agg(x, '|' order by x)) from (
  select 'rel:'||c.relname||':'||c.relkind::text as x from pg_class c where c.relnamespace='public'::regnamespace
  union all select 'col:'||table_name||'.'||column_name||':'||data_type from information_schema.columns where table_schema='public'
  union all select 'fn:'||p.oid::regprocedure::text from pg_proc p where p.pronamespace='public'::regnamespace
  union all select 'pol:'||tablename||'.'||policyname from pg_policies where schemaname='public'
  union all select 'trg:'||tgrelid::regclass||'.'||tgname from pg_trigger t join pg_class c on c.oid=t.tgrelid where not t.tgisinternal and c.relnamespace='public'::regnamespace) z"

# A. live-like upgrade (slice one + slice-one seed + slice-two paste, as live is today)
D=t3_live; liveish $D
res "A1 standalone preflight before apply" "$( [ "$(q $D -f $PF | cut -d'|' -f1)" = PASS ] && echo PASS || echo FAIL)" "$(q $D -f $PF)"
BEFORE=$(q $D -c "$SNAP"); SCH0=$(q $D -c "$SCHEMA"); EV0=$(q $D -c "select count(*) from event_log"); EVMAX0=$(q $D -c "select coalesce(max(id),0) from event_log")
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/tmp/s3a2.out 2>&1; rc=$?
EV1=$(q $D -c "select count(*) from event_log")
res "A2 paste run 1" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "exit=$rc event_log $EV0->$EV1 $(grep -o 'preflight OK.*' /tmp/s3a2.out | head -1)"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/tmp/s3a3.out 2>&1; rc=$?
EV2=$(q $D -c "select count(*) from event_log")
res "A3 paste run 2 (no-op)" "$([ $rc = 0 ] && [ "$EV1" = "$EV2" ] && grep -q 'already applied' /tmp/s3a3.out && echo PASS || echo FAIL)" "exit=$rc event_log $EV1->$EV2"
res "A4 standalone preflight after apply" "$( [ "$(q $D -f $PF | cut -d'|' -f1)" = 'ALREADY APPLIED' ] && echo PASS || echo FAIL)" "$(q $D -f $PF | cut -d'|' -f1)"
res "A5 schema_migrations has 4 + 3 + 3 = 10 versions" "$([ "$(q $D -c 'select count(*) from supabase_migrations.schema_migrations')" = 10 ] && echo PASS || echo FAIL)" "$(q $D -c "select string_agg(version, ',' order by version) from supabase_migrations.schema_migrations where version like '2026103121%'")"
AFTER=$(q $D -c "$SNAP")
res "A6 existing data unchanged by the paste (sales/agents/contacts/applications/call_metrics/commission_config/expenses/categories/revenue_adjustments)" "$([ "$BEFORE" = "$AFTER" ] && echo PASS || echo FAIL)" "$BEFORE"
res "A7 paste loads no Premier/board/mock data (config rows only)" "$([ "$(q $D -c 'select (select count(*) from recon_imports)+(select count(*) from premier_member_products)+(select count(*) from board_submissions)+(select count(*) from pay_adjustments)+(select count(*) from payroll_cutoffs)')" = 0 ] && echo PASS || echo FAIL)" "config: $(q $D -c "select (select count(*) from recon_pay_config)||' pay config, '||(select count(*) from agent_pay_rules)||' agent rules, '||(select count(*) from premier_addon_map)||' add-on map rows ('||(select count(*) from premier_addon_map where status='proposed')||' proposed)'")"
n=$(passes $D supabase/tests/verify.sql); res "A8 verify.sql (slice one) after upgrade" "$([ $n = 24 ] && echo PASS || echo FAIL)" "$n/24 $(fails $D supabase/tests/verify.sql)"
n=$(passes $D supabase/tests/verify_slice2.sql); T2=$(total $D supabase/tests/verify_slice2.sql)
res "A9 verify_slice2.sql after upgrade" "$([ $T2 -gt 0 ] && [ $n = $T2 ] && echo PASS || echo FAIL)" "$n/$T2 $(fails $D supabase/tests/verify_slice2.sql)"
n=$(passes $D supabase/tests/verify_slice3.sql); T3=$(total $D supabase/tests/verify_slice3.sql)
res "A10 verify_slice3.sql (all scenarios + structure) after upgrade" "$([ $T3 -gt 0 ] && [ $n = $T3 ] && echo PASS || echo FAIL)" "$n/$T3 $(fails $D supabase/tests/verify_slice3.sql)"
res "A11 verify_slice3 left nothing behind (rolled back)" "$([ "$(q $D -c 'select count(*) from recon_imports')" = 0 ] && [ "$(q $D -c 'select count(*) from event_log')" = "$EV2" ] && echo PASS || echo FAIL)" "event_log=$(q $D -c 'select count(*) from event_log')"
EVD=$(q $D -c "select string_agg(table_name||' '||action||' '||c, ', ') from (select table_name, action, count(*) c from event_log where id > $EVMAX0 group by 1,2 order by 1,2) x")
res "A12 event_log delta from paste (config-row audit only)" "$([ $((EV1-EV0)) -gt 0 ] && echo PASS || echo FAIL)" "+$((EV1-EV0)): $EVD"

# B. rollback: guards, then exact revert
for g in "update sales set lead_source='web' where ctid=(select ctid from sales limit 1)|lead_source" \
         "insert into pay_adjustments(agent_name,payday,kind,amount,reason,entered_by) values ('Test Agent','2026-11-06','manual',5,'real adj','Kyle')|non-mock pay adjustment" \
         "insert into recon_imports(kind,file_name,file_sha256,encoding,line_ending,header,row_count,is_mock) values ('sales_board','real.csv',repeat('b',64),'utf-8','CRLF','{A}',0,false)|non-mock import"; do
  G=t3_guard; psql -q -d postgres -c "drop database if exists $G" -c "create database $G template $D" >/dev/null 2>&1
  q $G -c "${g%%|*}" >/dev/null
  psql -X -q -v ON_ERROR_STOP=1 -d $G -f $RB >/tmp/rb.out 2>&1; rc=$?
  res "B1 rollback refuses with ${g##*|}" "$([ $rc != 0 ] && grep -q 'rollback refused' /tmp/rb.out && [ -n "$(q $G -c "select to_regclass('public.recon_imports')")" ] && echo PASS || echo FAIL)" "$(grep -o 'ERROR: .*' /tmp/rb.out | head -1 | cut -c1-110)"
done
psql -q -d postgres -c "drop database if exists t3_guard" >/dev/null 2>&1
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $RB >/dev/null 2>&1; rc=$?
res "B2 rollback runs" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "exit=$rc"
res "B3 data md5 after rollback == before apply" "$([ "$(q $D -c "$SNAP")" = "$BEFORE" ] && echo PASS || echo FAIL)" "$(q $D -c "$SNAP")"
[ -n "$SCH0" ] || echo "SCHEMA query failed"
res "B4 schema md5 (tables, columns, functions, policies, triggers) after rollback == before apply" "$([ -n "$SCH0" ] && [ "$(q $D -c "$SCHEMA")" = "$SCH0" ] && echo PASS || echo FAIL)" "$(q $D -c "$SCHEMA")"
res "B5 schema_migrations back to 7" "$([ "$(q $D -c 'select count(*) from supabase_migrations.schema_migrations')" = 7 ] && echo PASS || echo FAIL)" ""
n1=$(passes $D supabase/tests/verify.sql); n2=$(passes $D supabase/tests/verify_slice2.sql)
res "B6 verify.sql + verify_slice2.sql after rollback" "$([ $n1 = 24 ] && [ $n2 = $T2 ] && echo PASS || echo FAIL)" "$n1/24, $n2/$T2"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $RB >/dev/null 2>&1; rc=$?; res "B7 rollback re-run is a no-op" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "exit=$rc"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/dev/null 2>&1; rc=$?
n=$(passes $D supabase/tests/verify_slice3.sql); res "B8 re-apply after rollback" "$([ $rc = 0 ] && [ $n = $T3 ] && echo PASS || echo FAIL)" "exit=$rc verify_slice3 $n/$T3"

# C. preflight aborts change nothing
abort_case(){ # $1 name, $2 db, $3 mutate SQL
  local D=$2; [ -n "$3" ] && q $D -c "$3" >/dev/null
  local ea=$(q $D -c "select count(*) from event_log") ha=$(q $D -c "$SCHEMA"); [ -n "$ha" ] || echo "SCHEMA query failed"
  psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/tmp/pf.out 2>&1; local rc=$?
  local eb=$(q $D -c "select count(*) from event_log") hb=$(q $D -c "$SCHEMA") pf=$(q $D -f $PF | cut -d'|' -f1)
  res "$1" "$([ $rc != 0 ] && grep -q 'preflight failed' /tmp/pf.out && [ "$ea" = "$eb" ] && [ "$ha" = "$hb" ] && [ "$pf" = FAIL ] && echo PASS || echo FAIL)" "standalone=$pf; $(grep -o 'ERROR: .*' /tmp/pf.out | head -1 | cut -c1-120)"; }
D=t3_mut; liveish $D
abort_case "C1 paste aborts when commission_config is not 0.38/0.05" $D "update commission_config set addon_bonus_rate=0.06 where id"
q $D -c "update commission_config set addon_bonus_rate=0.05 where id" >/dev/null
abort_case "C2 paste aborts when sales already has a slice-three column" $D "alter table sales add column lead_source text"
q $D -c "alter table sales drop column lead_source" >/dev/null
res "C3 after undoing, standalone preflight is PASS again" "$( [ "$(q $D -f $PF | cut -d'|' -f1)" = PASS ] && echo PASS || echo FAIL)" "$(q $D -f $PF | cut -d'|' -f1)"
D=t3_noslice2; liveish $D noslice2
abort_case "C4 paste aborts when slice two is not applied" $D ""

# D. fresh build from the repo
D=t3_fresh; newdb $D
for f in supabase/migrations/*.sql supabase/seed.sql supabase/seed_slice2.sql; do psql -q -v ON_ERROR_STOP=1 -d $D -f $f >/dev/null 2>&1 || echo "FAIL $f"; done
n1=$(passes $D supabase/tests/verify.sql); n2=$(passes $D supabase/tests/verify_slice2.sql); n3=$(passes $D supabase/tests/verify_slice3.sql)
res "D1 fresh build: verify.sql + verify_slice2.sql + verify_slice3.sql" "$([ $n1 = 24 ] && [ $n2 = $T2 ] && [ $n3 = $T3 ] && echo PASS || echo FAIL)" "$n1/24, $n2/$T2, $n3/$T3 $(fails $D supabase/tests/verify_slice3.sql)"
psql -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed_slice3_mock.sql >/dev/null 2>&1; psql -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed_slice3_mock.sql >/dev/null 2>&1; rc=$?
res "D2 mock seed loads and re-runs without duplicates" "$([ $rc = 0 ] && [ "$(q $D -c 'select count(*) from premier_member_products')" = 66 ] && [ "$(q $D -c 'select count(*) from board_submissions')" = 35 ] && echo PASS || echo FAIL)" "premier=$(q $D -c 'select count(*) from premier_member_products') board=$(q $D -c 'select count(*) from board_submissions')"
for m in supabase/migrations/2026103121*.sql; do psql -q -v ON_ERROR_STOP=1 -d $D -f $m >/dev/null 2>&1 || echo "FAIL rerun $m"; done
res "D3 slice-three migrations re-run on a loaded DB (idempotent, data kept)" "$([ "$(q $D -c 'select count(*) from premier_member_products')" = 66 ] && [ "$(q $D -c 'select count(*) from premier_addon_map')" = "$(q t3_live -c 'select count(*) from premier_addon_map')" ] && echo PASS || echo FAIL)" ""

echo; echo "$(printf '%s\n' "${RES[@]}" | grep -c '|PASS|')/${#RES[@]} passed"
