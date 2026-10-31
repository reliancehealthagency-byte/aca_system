#!/usr/bin/env bash
# LOCAL ONLY. Runs every slice-two test against throwaway databases on a local Postgres with the Supabase stub.
# Usage: PGHOST=/tmp PGPORT=54329 PGUSER=postgres scripts/local_test_slice2.sh
set -uo pipefail
cd "$(dirname "$0")/.."
PASTE=${PASTE:-/workspace/aca_system_deploy/slice2_paste.sql}
RB=supabase/rollback/slice2_rollback.sql
PF=supabase/deploy/slice2_preflight.sql
declare -a RES
res(){ RES+=("$1|$2|$3"); printf '%-5s | %s | %s\n' "$2" "$1" "$3"; }
newdb(){ psql -q -d postgres -c "drop database if exists $1" -c "create database $1" >/dev/null 2>&1
  psql -q -v ON_ERROR_STOP=1 -d $1 -f supabase/tests/local_supabase_stub.sql >/dev/null 2>&1
  psql -q -d $1 -c "insert into auth.users(email) values ('admin.test@example.com'),('agent.test@example.com')" >/dev/null; }
liveish(){ newdb $1; for f in supabase/migrations/2026103119*.sql; do psql -q -v ON_ERROR_STOP=1 -d $1 -f $f >/dev/null 2>&1 || echo "FAIL $f"; done
  git show main:supabase/seed.sql | psql -q -v ON_ERROR_STOP=1 -d $1 >/dev/null 2>&1 || echo "FAIL slice-one seed"; }
q(){ psql -X -At -v ON_ERROR_STOP=1 -d "$@" 2>/dev/null; }
passes(){ psql -X -q -v ON_ERROR_STOP=1 -d $1 -f $2 2>/dev/null | grep -cE '\| PASS'; }
fails(){ psql -X -q -v ON_ERROR_STOP=1 -d $1 -f $2 2>/dev/null | grep -E '\| FAIL' | tr -s ' ' | cut -c1-120 | paste -sd';'; }
SNAP="select md5(string_agg(t,'|' order by t)) from (
  select 's'||row(s.*)::text t from sales s union all select 'a'||row(a.*)::text from agents a
  union all select 'c'||row(c.*)::text from contacts c union all select 'p'||row(p.*)::text from applications p
  union all select 'm'||row(m.*)::text from call_metrics m union all select 'k'||row(k.*)::text from commission_config k
  union all select 'e'||concat_ws(',',e.id,e.category,e.amount,e.date,e.description,e.created_at) from expenses e) x"

# A. live-like upgrade
D=t_live; liveish $D
res "A1 standalone preflight before apply" "$( [ "$(q $D -f $PF | cut -d'|' -f1)" = PASS ] && echo PASS || echo FAIL)" "$(q $D -f $PF)"
BEFORE=$(q $D -c "$SNAP"); EV0=$(q $D -c "select count(*) from event_log")
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/dev/null 2>&1; rc=$?
EV1=$(q $D -c "select count(*) from event_log")
res "A2 paste run 1" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "exit=$rc event_log $EV0->$EV1"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/dev/null 2>&1; rc=$?
EV2=$(q $D -c "select count(*) from event_log")
res "A3 paste run 2 (no-op)" "$([ $rc = 0 ] && [ "$EV1" = "$EV2" ] && echo PASS || echo FAIL)" "exit=$rc event_log $EV1->$EV2"
res "A4 standalone preflight after apply" "$( [ "$(q $D -f $PF | cut -d'|' -f1)" = 'ALREADY APPLIED' ] && echo PASS || echo FAIL)" "$(q $D -f $PF | cut -d'|' -f1)"
MV=$(q $D -c "select string_agg(version||':'||name, ',' order by version) from supabase_migrations.schema_migrations")
res "A5 schema_migrations has 4 slice-one + 3 slice-two versions" "$([ "$(q $D -c 'select count(*) from supabase_migrations.schema_migrations')" = 7 ] && echo PASS || echo FAIL)" "$MV"
n=$(passes $D supabase/tests/verify.sql); res "A6 verify.sql (slice one) after upgrade" "$([ $n = 24 ] && echo PASS || echo FAIL)" "$n/24 $(fails $D supabase/tests/verify.sql)"
n=$(passes $D supabase/tests/verify_slice2.sql); T=$(psql -X -q -d $D -f supabase/tests/verify_slice2.sql 2>/dev/null | grep -cE '^ +[0-9]+ \|')
res "A7 verify_slice2.sql after upgrade" "$([ $n = $T ] && echo PASS || echo FAIL)" "$n/$T $(fails $D supabase/tests/verify_slice2.sql)"
EVD=$(q $D -c "select string_agg(table_name||' '||action||' '||c, ', ') from (select table_name, action, count(*) c from event_log where id > $EV0 group by 1,2 order by 1,2) x")
res "A8 event_log delta from paste" "$([ $((EV1-EV0)) = 34 ] && echo PASS || echo FAIL)" "+$((EV1-EV0)): $EVD"

# B. rollback guards + md5
q $D -c "insert into expenses(date,category,amount,description,vendor) values ('2026-10-31','other',5,'manual w/ vendor','Fake Vendor')" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $RB >/tmp/rb.out 2>&1; rc=$?
res "B1 rollback refuses: non-seed expense with vendor" "$([ $rc != 0 ] && grep -q 'non-seed expense' /tmp/rb.out && [ -n "$(q $D -c "select to_regclass('public.pl_daily')")" ] && echo PASS || echo FAIL)" "$(grep -o 'ERROR: .*' /tmp/rb.out | head -1 | cut -c1-110)"
q $D -c "delete from expenses where description='manual w/ vendor'" >/dev/null
q $D -c "insert into revenue_adjustments(date,category,amount,description) values ('2026-10-31','carrier_bonus',5,'VERIFY guard')" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $RB >/tmp/rb.out 2>&1; rc=$?
res "B2 rollback refuses: revenue_adjustments not empty" "$([ $rc != 0 ] && grep -q 'revenue_adjustments has' /tmp/rb.out && echo PASS || echo FAIL)" "$(grep -o 'ERROR: .*' /tmp/rb.out | head -1 | cut -c1-110)"
q $D -c "delete from revenue_adjustments" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $RB >/dev/null 2>&1; rc=$?
AFTER=$(q $D -c "$SNAP")
res "B3 rollback: slice-one data md5 identical to pre-apply (incl. expenses)" "$([ $rc = 0 ] && [ "$BEFORE" = "$AFTER" ] && echo PASS || echo FAIL)" "before=${BEFORE:0:12} after=${AFTER:0:12}"
LEFT=$(q $D -c "select concat_ws(',', to_regclass('public.pl_line_items'), to_regclass('public.pl_unpriced_sales'), to_regclass('public.expense_categories'), to_regclass('public.revenue_adjustments'), to_regclass('public.pl_daily'))")
COLS=$(q $D -c "select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_schema='public' and table_name='expenses'")
VERS=$(q $D -c "select count(*) from supabase_migrations.schema_migrations")
res "B4 rollback removed slice-two objects/columns/versions" "$([ -z "$LEFT" ] && [ "$COLS" = 'id,category,amount,date,description,created_at' ] && [ "$VERS" = 4 ] && echo PASS || echo FAIL)" "left=[$LEFT] cols=$COLS versions=$VERS"
n=$(passes $D supabase/tests/verify.sql); res "B5 verify.sql after rollback" "$([ $n = 24 ] && echo PASS || echo FAIL)" "$n/24"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $RB >/dev/null 2>&1; rc=$?; res "B6 rollback re-run is a no-op" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "exit=$rc"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/dev/null 2>&1; rc=$?
n=$(passes $D supabase/tests/verify_slice2.sql); res "B7 re-apply after rollback" "$([ $rc = 0 ] && [ $n = $T ] && echo PASS || echo FAIL)" "exit=$rc verify_slice2 $n/$T"

# C. preflight abort with a mutated category
D=t_mut; liveish $D
q $D -c "update expenses set category='Lead' where amount=175.00" >/dev/null
EVa=$(q $D -c "select count(*) from event_log"); Ha=$(q $D -c "$SNAP")
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/tmp/pf.out 2>&1; rc=$?
EVb=$(q $D -c "select count(*) from event_log"); Hb=$(q $D -c "$SNAP")
S2=$(q $D -c "select concat_ws(',', to_regclass('public.expense_categories'), to_regclass('supabase_migrations.schema_migrations'))")
res "C1 paste aborts on mutated category, changes nothing" "$([ $rc != 0 ] && grep -q 'preflight failed' /tmp/pf.out && [ "$EVa" = "$EVb" ] && [ "$Ha" = "$Hb" ] && [ -z "$S2" ] && echo PASS || echo FAIL)" "$(grep -o 'ERROR: .*' /tmp/pf.out | head -1 | cut -c1-120)"
res "C2 standalone preflight reports FAIL" "$( [ "$(q $D -f $PF | cut -d'|' -f1)" = FAIL ] && echo PASS || echo FAIL)" "$(q $D -f $PF)"
q $D -c "update expenses set category='Leads' where amount=175.00" >/dev/null
q $D -c "insert into expenses(category,amount,date,description) values ('Leads',1,'2026-10-31','extra')" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/tmp/pf.out 2>&1; rc=$?
res "C3 paste aborts on a 5th expense row" "$([ $rc != 0 ] && grep -q 'preflight failed' /tmp/pf.out && echo PASS || echo FAIL)" "$(grep -o 'ERROR: .*' /tmp/pf.out | head -1 | cut -c1-120)"

# D. fresh build from the repo
D=t_fresh; newdb $D
for f in supabase/migrations/*.sql supabase/seed.sql supabase/seed_slice2.sql; do psql -q -v ON_ERROR_STOP=1 -d $D -f $f >/dev/null 2>&1 || echo "FAIL $f"; done
n1=$(passes $D supabase/tests/verify.sql); n2=$(passes $D supabase/tests/verify_slice2.sql)
res "D1 fresh build: verify.sql + verify_slice2.sql" "$([ $n1 = 24 ] && [ $n2 = $T ] && echo PASS || echo FAIL)" "$n1/24, $n2/$T $(fails $D supabase/tests/verify_slice2.sql)"
q $D -f supabase/seed.sql >/dev/null; q $D -f supabase/seed_slice2.sql >/dev/null 2>&1
res "D2 slice-two seed re-run adds nothing" "$([ "$(q $D -c 'select count(*) from expenses')" = 24 ] && echo PASS || echo FAIL)" "expenses=$(q $D -c 'select count(*) from expenses')"

echo; echo "$(printf '%s\n' "${RES[@]}" | grep -c '|PASS|')/${#RES[@]} passed"
