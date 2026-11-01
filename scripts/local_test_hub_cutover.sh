#!/usr/bin/env bash
# LOCAL ONLY. Tests the one-time hub cutover import (scripts/hub_cutover.py) against throwaway databases built fresh from
# this tree's migrations (slices 1-3 + Q30) on a local Postgres with the Supabase stub. Never points at the real project.
# Usage: PGHOST=/tmp PGPORT=54329 PGUSER=postgres scripts/local_test_hub_cutover.sh [REAL_IMPORT_CSV]
#   REAL_IMPORT_CSV (optional, outside the repo): also dry-runs the real Paid Lock file on a fresh build + the mock seed.
set -uo pipefail
cd "$(dirname "$0")/.."
REAL=${1:-}
PY="python3 scripts/hub_cutover.py --today 2026-11-01"
FX=supabase/tests/fixtures/hub_paid_lock_mock.csv
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
res(){ if [ "$2" = PASS ]; then pass=$((pass+1)); else fail=$((fail+1)); fi; printf '%-4s | %s | %s\n' "$2" "$1" "$3"; }
ok(){ [ "$1" = 0 ] && echo PASS || echo FAIL; }
q(){ psql -X -At -v ON_ERROR_STOP=1 -d "$@" 2>/dev/null; }
fresh(){ psql -q -d postgres -c "drop database if exists $1" -c "create database $1" >/dev/null 2>&1
  psql -q -v ON_ERROR_STOP=1 -d $1 -f supabase/tests/local_supabase_stub.sql >/dev/null 2>&1
  psql -q -d $1 -c "insert into auth.users(email) values ('admin.test@example.com'),('agent.test@example.com'),('agent2.test@example.com')" >/dev/null
  for f in supabase/migrations/*.sql; do psql -X -q -v ON_ERROR_STOP=1 -d $1 -f $f >/dev/null 2>&1 || echo "FAIL migration $f"; done
  psql -X -q -v ON_ERROR_STOP=1 -d $1 -f supabase/seed.sql >/dev/null 2>&1 || echo "FAIL seed.sql"; }
run(){ psql -X -q -v ON_ERROR_STOP=1 -d "$1" -f "$2" >"$T/out" 2>&1; echo $?; }
err(){ grep -oE '(ERROR|NOTICE): +.*' "$T/out" | head -1 | cut -c1-150; }
mkcsv(){ printf 'Pay Friday,Agent,Paid Total,System Total,Locked At (ET),Note\n%s\n' "$2" > "$T/$1.csv"; echo "$T/$1.csv"; }
refuse(){ # name csv expected-substring
  $PY sql --csv "$2" --dry-run --out "$T/x.sql" 2>"$T/e"; rc=$?
  res "$1" "$([ $rc != 0 ] && grep -q -- "$3" "$T/e" && echo PASS || echo FAIL)" "$(grep -o 'REFUSED.*' "$T/e" | cut -c1-120)"; }

# ---------- L. file loader refusals (no DB) ----------
refuse "L1 header must be the exact 6-column Kyle layout" "$(printf 'Pay Friday,Agent,Paid Total,Locked At (ET),Note\n2026-10-30,A,1,2026-10-29 16:40,x\n' > $T/h.csv; echo $T/h.csv)" "header must be exactly"
refuse "L2 Pay Friday not a Friday" "$(mkcsv l2 '2026-10-29,A,1.00,1.00,2026-10-29 16:40,x')" "not a Friday"
refuse "L3 Pay Friday after today ET" "$(mkcsv l3 '2026-11-06,A,1.00,1.00,2026-11-01 10:00,x')" "after today ET"
refuse "L4 blank Paid Total" "$(mkcsv l4 '2026-10-30,A,,1.00,2026-10-29 16:40,x')" "amount is blank"
refuse "L5 blank Locked At" "$(mkcsv l5 '2026-10-30,A,1.00,1.00,,x')" "Locked At"
refuse "L6 duplicate Pay Friday + Agent (case / space-insensitive)" "$(mkcsv l6 $'2026-10-30,Jim  Smith,1.00,1.00,2026-10-29 16:40,x\n2026-10-30,jim smith,2.00,2.00,2026-10-29 16:40,y')" "duplicate Pay Friday + Agent"
refuse "L7 money with fractions of a cent" "$(mkcsv l7 '2026-10-30,A,1.005,1.00,2026-10-29 16:40,x')" "fractions of a cent"
refuse "L8 non-money text" "$(mkcsv l8 '2026-10-30,A,abc,1.00,2026-10-29 16:40,x')" "not a money value"
refuse "L9 Locked At outside Pay Friday-7 .. today" "$(mkcsv l9 '2026-10-30,A,1.00,1.00,2026-10-01 10:00,x')" "not between"
refuse "L10 impossible date" "$(mkcsv l10 '2026-02-30,A,1.00,1.00,2026-02-27 10:00,x')" "not a real date"
refuse "L11 blank row inside the file" "$(mkcsv l11 $'2026-10-30,A,1.00,1.00,2026-10-29 16:40,x\n,,,,,\n2026-10-30,B,1.00,1.00,2026-10-29 16:40,x')" "blank row"
refuse "L12 blank agent" "$(mkcsv l12 '2026-10-30, ,1.00,1.00,2026-10-29 16:40,x')" "Agent is blank"
$PY sql --csv $FX --dry-run --out supabase/x_hub.sql 2>"$T/e"; rc=$?
res "L13 generated SQL can't be written inside the git tree" "$([ $rc != 0 ] && [ ! -e supabase/x_hub.sql ] && grep -q 'inside the git tree' "$T/e" && echo PASS || echo FAIL)" ""
$PY sql --csv $FX --out "$T/x.sql" 2>"$T/e"; rc=$?
res "L14 sql needs exactly one of --dry-run / --confirm-hub" "$([ $rc != 0 ] && grep -q 'exactly one' "$T/e" && echo PASS || echo FAIL)" ""
# build: unformatted (serials) vs formatted reads must agree
printf 'Pay Friday,Agent,Paid Total,System Total,Locked At (ET),Note\n46325,A Test,170,170,46324.694444444445,n\n46318,A Test,425.59000000000003,,46318.47430555556,n\n' > $T/u.csv
printf 'Pay Friday,Agent,Paid Total,System Total,Locked At (ET),Note\n2026-10-30,A Test,$170.00,$170.00,2026-10-29 16:40,n\n2026-10-23,A Test,$425.59,,10/23/2026,n\n' > $T/f.csv
$PY build --unformatted $T/u.csv --formatted $T/f.csv --out $T/b.csv >/dev/null 2>&1; rc=$?
res "B1 build: serials -> ISO dates, cents, Locked At time recovered from the serial (display showed date only)" "$([ $rc = 0 ] && grep -q '^2026-10-23,A Test,425.59,,2026-10-23 11:23,n$' $T/b.csv && grep -q '^2026-10-30,A Test,170.00,170.00,2026-10-29 16:40,n$' $T/b.csv && [ "$(stat -c %a $T/b.csv)" = 600 ] && echo PASS || echo FAIL)" "$(sed -n 3p $T/b.csv)"
sed -i 's/\$425.59/$425.60/' $T/f.csv
$PY build --unformatted $T/u.csv --formatted $T/f.csv --out $T/b2.csv >/dev/null 2>"$T/e"; rc=$?
res "B2 build refuses when the two reads disagree (money)" "$([ $rc != 0 ] && [ ! -e $T/b2.csv ] && grep -q 'money differs' "$T/e" && echo PASS || echo FAIL)" ""
$PY check --csv $FX > "$T/chk"; rc=$?
res "C1 check on the mock file: per-payday rows / sums / variances / ET times" "$([ $rc = 0 ] && grep -q '| 2026-10-23 | 3 | 404.45 | 369.45 | +35.00 |' $T/chk && grep -q '| 2026-10-16 | 2 | 36.50 | — | n/a | 2026-10-19 00:00, 2026-10-19 15:58 |' $T/chk && grep -q '2 different Locked At values' $T/chk && grep -q '2026-10-16 → locked 2026-10-19 00:00 ET = 2026-10-19 04:00 UTC' $T/chk && echo PASS || echo FAIL)" "$(grep -c '' $T/chk) lines"

printf 'Agent (standard name)\nAlex Testagent (fake)\n' > $T/roster.csv
printf 'BOARD NAME ALIASES,,,DIALER\nAlias,Standard Name,,x,y\nBlair Sample (fake),Blair Sample (fake)\n' > $T/alias.csv
$PY check --csv $FX --roster $T/roster.csv --aliases $T/alias.csv > "$T/chk2"; rc=$?
res "C2 mapping with roster + aliases: both mock agents mapped, UNKNOWN (\$0) only a warning" "$([ $rc = 0 ] && grep -q '| Blair Sample (fake) | alias → Blair Sample (fake) |' $T/chk2 && grep -q "agent 'UNKNOWN' is not on the hub roster (\$0.00 only" $T/chk2 && echo PASS || echo FAIL)" ""
$PY check --csv $FX --roster $T/roster.csv > "$T/chk3"; rc=$?
res "C3 an agent carrying dollars who is not on the roster is a HARD error (exit 1)" "$([ $rc = 1 ] && grep -q "agent 'Blair Sample (fake)' is not on the hub roster and carries 1286.16" $T/chk3 && echo PASS || echo FAIL)" ""
# ---------- D. database: fresh build of this tree ----------
D=hubcut_t1; fresh $D
$PY sql --csv $FX --dry-run --out $T/dry.sql 2>/dev/null; $PY sql --csv $FX --confirm-hub --out $T/apply.sql 2>/dev/null
EV0=$(q $D -c "select count(*) from event_log")
rc=$(run $D $T/dry.sql)
res "D1 dry run: raises 'DRY RUN OK' with the plan; nothing written (hub rows 0, cutover 0, event_log unchanged)" "$([ $rc != 0 ] && grep -q 'HUB CUTOVER DRY RUN OK' $T/out && [ "$(q $D -c 'select (select count(*) from hub_paid_lock)+(select count(*) from hub_cutover)')" = 0 ] && [ "$(q $D -c 'select count(*) from event_log')" = $EV0 ] && echo PASS || echo FAIL)" "$(err)"
res "D2 dry run lists agent names with no backend agent id (fake roster maps both mock agents; UNKNOWN unmapped)" "$(grep -q 'no backend agent id: UNKNOWN$' $T/out && echo PASS || echo FAIL)" ""
q $D -c "set role service_role; select 1" >/dev/null
{ echo "set role service_role;"; cat $T/apply.sql; } > $T/sr.sql; rc=$(run $D $T/sr.sql)
res "D3 service_role (admin key) refused" "$([ $rc != 0 ] && grep -q 'service_role' $T/out && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 0 ] && echo PASS || echo FAIL)" "$(err)"
A=$(q $D -c "select id from auth.users where email='admin.test@example.com'"); G=$(q $D -c "select id from auth.users where email='agent.test@example.com'")
as(){ echo "set role authenticated; select set_config('request.jwt.claims', json_build_object('sub','$1','role','authenticated')::text, false);"; }
{ as $A; cat $T/apply.sql; } > $T/adm.sql; rc=$(run $D $T/adm.sql)
res "D4 an admin login while NO payroll owner is set is refused (fails closed: SQL Editor only)" "$([ $rc != 0 ] && grep -q 'payroll owner not set' $T/out && echo PASS || echo FAIL)" "$(err)"
q $D -c "update recon_pay_config set payroll_owner_user_id = '$G' where id" >/dev/null
rc=$(run $D $T/adm.sql)
res "D5 an admin who is not the payroll owner is refused" "$([ $rc != 0 ] && grep -q 'only the payroll owner' $T/out && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 0 ] && echo PASS || echo FAIL)" "$(err)"
q $D -c "update recon_pay_config set payroll_owner_user_id = null where id" >/dev/null
rc=$(run $D $T/apply.sql)
res "D6 APPLY as postgres (SQL Editor break-glass): 7 rows, sum 1814.36, cutover last 10/30, paydays {10/16,10/23,10/30}" "$([ $rc = 0 ] && [ "$(q $D -c 'select count(*)||'"'"'|'"'"'||sum(paid_total) from hub_paid_lock')" = '7|1814.36' ] && [ "$(q $D -c 'select last_hub_payday||'"'"'|'"'"'||paydays::text||'"'"'|'"'"'||row_count from hub_cutover')" = '2026-10-30|{2026-10-16,2026-10-23,2026-10-30}|7' ] && echo PASS || echo FAIL)" "$(err)"
res "D7 audited: payroll.hub_cutover.recorded + payroll.hub_cutover.import (path break-glass:postgres, per-payday totals)" "$([ "$(q $D -c "select count(*) from event_log where event_type='payroll.hub_cutover.recorded'")" = 1 ] && [ "$(q $D -c "select detail->>'path' from event_log where event_type='payroll.hub_cutover.import'")" = 'break-glass:postgres' ] && [ "$(q $D -c "select detail->'per_payday'->'2026-10-23'->>'paid' from event_log where event_type='payroll.hub_cutover.import'")" = 404.45 ] && echo PASS || echo FAIL)" ""
res "D8 Locked At stored in ET: 10/23 11:23 ET = 15:23 UTC; date-only 10/19 = 00:00 ET; negative paid kept" "$([ "$(q $D -c "select to_char(locked_at at time zone 'UTC','YYYY-MM-DD HH24:MI') from hub_paid_lock where row_num=4")" = '2026-10-23 15:23' ] && [ "$(q $D -c "select to_char(locked_at at time zone 'America/New_York','YYYY-MM-DD HH24:MI') from hub_paid_lock where row_num=6")" = '2026-10-19 00:00' ] && [ "$(q $D -c 'select paid_total from hub_paid_lock where row_num=7')" = -12.50 ] && echo PASS || echo FAIL)" ""
EV1=$(q $D -c "select count(*) from event_log")
rc=$(run $D $T/apply.sql)
res "D9 re-running the same APPLY is a no-op (notice; rows, cutover and event_log unchanged)" "$([ $rc = 0 ] && grep -q 'already recorded from this file' $T/out && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 7 ] && [ "$(q $D -c 'select count(*) from event_log')" = $EV1 ] && echo PASS || echo FAIL)" "$(err)"
rc=$(run $D $T/dry.sql)
res "D10 dry run after it is recorded says so (nothing to do)" "$([ $rc != 0 ] && grep -q 'DRY RUN: already recorded from this file' $T/out && echo PASS || echo FAIL)" ""
sed 's/MOCK desk submit/MOCK desk submit edited/' $FX > $T/other.csv; $PY sql --csv $T/other.csv --confirm-hub --out $T/other.sql 2>/dev/null
rc=$(run $D $T/other.sql)
res "D11 a different file after the cutover is refused (one-time, immutable)" "$([ $rc != 0 ] && grep -q 'already recorded from another file' $T/out && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 7 ] && echo PASS || echo FAIL)" "$(err)"
rc=$(q $D -c "update hub_paid_lock set paid_total = 1 where row_num = 1" >/dev/null 2>&1; echo $?); rc2=$(q $D -c "delete from hub_cutover" >/dev/null 2>&1; echo $?)
res "D12 recorded rows can't be edited or deleted, even as postgres" "$([ $rc != 0 ] && [ $rc2 != 0 ] && [ "$(q $D -c 'select count(*) from hub_cutover')" = 1 ] && echo PASS || echo FAIL)" ""

# owner login path (Kyle's login): payroll owner = admin.test (an admin)
D=hubcut_t2; fresh $D; A=$(q $D -c "select id from auth.users where email='admin.test@example.com'")
q $D -c "update recon_pay_config set payroll_owner_user_id = '$A' where id" >/dev/null
{ as $A; cat $T/apply.sql; } > $T/own.sql; rc=$(run $D $T/own.sql)
res "D13 APPLY as the payroll owner's login works (recorded_by = owner; trigger event logged; no direct event_log grant needed)" "$([ $rc = 0 ] && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 7 ] && [ "$(q $D -c "select (recorded_by = '$A')::text from hub_cutover")" = true ] && [ "$(q $D -c "select count(*) from event_log where event_type='payroll.hub_cutover.recorded'")" = 1 ] && echo PASS || echo FAIL)" "$(err)"

# locked weeks are never touched: refused when this system already locked a payday / submitted past the file
D=hubcut_t3; fresh $D
psql -X -q -d $D -c "set session_replication_role = replica; insert into pay_line_locks (line_key, component, agent_name, payday, amount) values ('L1','commission','Test','2026-11-06',10)" >/dev/null 2>"$T/e"
L0=$(q $D -c "select md5(string_agg(row(l.*)::text, '|')) from pay_line_locks l")
rc=$(run $D $T/apply.sql)
res "D14 refused once this system has locked any payday (the cutover never reopens / changes a locked week)" "$([ "$(q $D -c 'select count(*) from pay_line_locks')" = 1 ] && [ $rc != 0 ] && grep -q 'already locked payday 2026-11-06' $T/out && [ "$(q $D -c "select md5(string_agg(row(l.*)::text, '|')) from pay_line_locks l")" = "$L0" ] && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 0 ] && echo PASS || echo FAIL)" "$(err)"
D=hubcut_t4; fresh $D
q $D -c "insert into payroll_cutoffs (payday, cutoff_at, source, note) values ('2026-11-06', '2026-11-05 14:00 America/New_York', 'submit', 'test')" >/dev/null
rc=$(run $D $T/apply.sql)
res "D15 refused when a payday after the file's last one is already submitted here (would count twice)" "$([ $rc != 0 ] && grep -q 'already submitted here' $T/out && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 0 ] && echo PASS || echo FAIL)" "$(err)"
# tampering with the generated SQL is caught by the in-database checks
D=hubcut_t5; fresh $D
awk '/^      \(1, date/{print; print "      (99, date '"'"'2026-10-30'"'"', '"'"'ALEX TESTAGENT (FAKE)'"'"', 1.00, null, timestamp '"'"'2026-10-29 16:40:00'"'"' at time zone '"'"'America/New_York'"'"', null),"; next}1' $T/apply.sql > $T/dup.sql
rc=$(run $D $T/dup.sql)
res "D16 duplicate Pay Friday + Agent slipped into the SQL is refused in the DB (case-insensitive)" "$([ $rc != 0 ] && grep -q 'duplicate Pay Friday + Agent' $T/out && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 0 ] && echo PASS || echo FAIL)" "$(err)"
sed 's/1203\.41, 1203\.41/1203.42, 1203.41/' $T/apply.sql > $T/sum.sql
rc=$(run $D $T/sum.sql)
res "D17 a changed amount (per-payday sum differs from the checked file) is refused, nothing written" "$([ $rc != 0 ] && grep -q 'per-payday counts / sums differ' $T/out && [ "$(q $D -c 'select (select count(*) from hub_paid_lock)+(select count(*) from hub_cutover)')" = 0 ] && echo PASS || echo FAIL)" "$(err)"
sed "s/date '2026-10-16', 'Alex/date '2026-10-15', 'Alex/" $T/apply.sql > $T/thu.sql
rc=$(run $D $T/thu.sql)
res "D18 a non-Friday slipped into the SQL is refused" "$([ $rc != 0 ] && grep -qE 'not a past Friday|per-payday' $T/out && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 0 ] && echo PASS || echo FAIL)" "$(err)"
q $D -c "set session_replication_role = replica; insert into hub_paid_lock (file_sha256,row_num,payday,agent_name,paid_total,locked_at) values (repeat('d',64),1,'2026-10-30','x',1,now())" >/dev/null
rc=$(run $D $T/apply.sql)
res "D19 refused when hub_paid_lock already holds rows without a cutover record (orphans)" "$([ $rc != 0 ] && grep -q 'without a cutover record' $T/out && echo PASS || echo FAIL)" "$(err)"

# with the slice-three MOCK board + Premier seed (submit 10/23 + 10/30 recorded): freezes and paid_by_hub
D=hubcut_t6; fresh $D; psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed_slice3_mock.sql >/dev/null 2>&1 || echo "FAIL mock seed"
PEND0=$(q $D -c "select count(*) from premier_recon_trueup where cutover_status = 'cutover_pending_kyle'")
rc=$(run $D $T/apply.sql)
res "D20 with the mock board loaded: weeks through 10/30 frozen (reason hub_cutover); cutover_pending_kyle lines become paid_by_hub" "$([ $rc = 0 ] && [ "$(q $D -c "select count(*) from board_week_freezes where reason='hub_cutover'")" -gt 0 ] && [ "$(q $D -c "select count(*) from premier_recon_trueup where cutover_status = 'cutover_pending_kyle'")" = 0 ] && [ "$(q $D -c "select count(*) from premier_recon_trueup where cutover_status = 'paid_by_hub'")" -gt 0 ] && echo PASS || echo FAIL)" "$(grep -o 'board submissions frozen [0-9]*' $T/out) pending $PEND0 -> $(q $D -c "select count(*) from premier_recon_trueup where cutover_status = 'cutover_pending_kyle'"), paid_by_hub $(q $D -c "select count(*) from premier_recon_trueup where cutover_status = 'paid_by_hub'")"
D=hubcut_t7; fresh $D
q $D -c "insert into payroll_cutoffs (payday, cutoff_at, source, note) values ('2026-10-16', '2026-10-15 14:00 America/New_York', 'submit', 'test')" >/dev/null
rc=$(run $D $T/apply.sql)
res "D21 DB guard (hub_paid_lock_guard): a Pay Friday after the last recorded submit + 7 days is refused (typo guard)" "$([ $rc != 0 ] && grep -q 'after the last recorded submit' $T/out && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 0 ] && echo PASS || echo FAIL)" "$(err)"

# ---------- R. the real file (optional): dry run on a fresh build + the mock board, nothing written ----------
if [ -n "$REAL" ]; then
  D=hubcut_real; fresh $D; psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed_slice3_mock.sql >/dev/null 2>&1
  python3 scripts/hub_cutover.py sql --csv "$REAL" --dry-run --out $T/real_dry.sql 2>/dev/null
  rc=$(run $D $T/real_dry.sql)
  res "R1 real Paid Lock file: dry run OK on a fresh build of this tree (+ mock board), nothing written" "$([ $rc != 0 ] && grep -q 'DRY RUN OK' $T/out && [ "$(q $D -c 'select (select count(*) from hub_paid_lock)+(select count(*) from hub_cutover)')" = 0 ] && echo PASS || echo FAIL)" "$(grep -o 'DRY RUN OK.*' $T/out | cut -c1-400)"
  python3 scripts/hub_cutover.py sql --csv "$REAL" --confirm-hub --out $T/real_apply.sql 2>/dev/null
  rc=$(run $D $T/real_apply.sql)
  res "R2 real file APPLY on the LOCAL copy: rows / sum / last payday as checked" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(q $D -c "select count(*)||' rows, '||sum(paid_total)||' paid, '||(select last_hub_payday from hub_cutover)||', frozen '||(select count(*) from board_week_freezes where reason='hub_cutover') from hub_paid_lock")"
  q $D -c "select payday, count(*), sum(paid_total), sum(system_total) from hub_paid_lock group by 1 order by 1" | sed 's/^/     /'
  rc=$(run $D $T/real_apply.sql)
  res "R3 real file APPLY re-run on the local copy: no-op" "$([ $rc = 0 ] && grep -q 'already recorded from this file' $T/out && echo PASS || echo FAIL)" ""
fi
for d in hubcut_t1 hubcut_t2 hubcut_t3 hubcut_t4 hubcut_t5 hubcut_t6 hubcut_t7 hubcut_real; do psql -q -d postgres -c "drop database if exists $d" >/dev/null 2>&1; done
echo "hub cutover tests: $pass passed, $fail failed"
[ $fail = 0 ]
