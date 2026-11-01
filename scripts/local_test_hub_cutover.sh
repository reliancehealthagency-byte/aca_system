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
FO=supabase/tests/fixtures/hub_lock_open_mock.csv
FA=supabase/tests/fixtures/hub_paid_elsewhere_mock.csv
PMOCK=${PMOCK:-/workspace/artifacts/premier_mock/MOCK_PHS_Member_Products_2026-10-31.csv}
T=$(mktemp -d); export T; trap 'rm -rf "$T"' EXIT
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
# --snapshot is mandatory for sql: tests stand in for build by writing a snapshot of the exact files passed (and default to
# --no-adjustments when no --adjustments is given). The snapshot checks themselves are tested in group S with $PY sql.
mksnap(){ python3 - "$@" <<'PY'
import hashlib, json, os, sys
keys = ('paid_lock', 'lock_open', 'adjustments'); s = {'built_at_et': 'test'}
for k, f in zip(keys, sys.argv[1:4]):
    if f:
        s[k] = {'file': os.path.realpath(f), 'sha256': hashlib.sha256(open(f, 'rb').read()).hexdigest()}
if sys.argv[3]:
    s['cover_seeds'] = {'file': None, 'sha256': None, 'note': 'test'}
    m = os.path.join(os.environ['T'], 'must_none.csv')      # no rows after the last hub payday in the test files
    open(m, 'w').write('Tab Row,Payday,Agent,Amount,Covers,Note\n')
    s['must_reenter'] = {'file': m, 'sha256': hashlib.sha256(open(m, 'rb').read()).hexdigest(), 'rows': 0}
print(json.dumps(s))
PY
}
hcsql(){ local csv='' lo='' adj='' noadj='' a=("$@") i
  for ((i=0; i<${#a[@]}; i++)); do case "${a[$i]}" in --csv) csv=${a[$((i+1))]};; --lock-open) lo=${a[$((i+1))]};;
    --adjustments) adj=${a[$((i+1))]};; --no-adjustments) noadj=1;; esac; done
  mksnap "$csv" "$lo" "$adj" > $T/snap_auto.json
  if [ -z "$adj" ] && [ -z "$noadj" ]; then set -- "$@" --no-adjustments; fi
  $PY sql "$@" --snapshot $T/snap_auto.json; }
# dry run FILE-args on DB, then build the APPLY with the printed token -> $T/apply_$1.sql (token in $T/tok_$1)
mkapply(){ local db=$1; shift; hcsql "$@" --dry-run --out $T/dry_$db.sql 2>/dev/null
  psql -X -q -v ON_ERROR_STOP=1 -d $db -f $T/dry_$db.sql >$T/dryout_$db 2>&1
  grep -oE 'DRY RUN TOKEN [0-9A-F]{10}' $T/dryout_$db | awk '{print $4}' > $T/tok_$db
  hcsql "$@" --confirm-hub --dry-run-token "$(cat $T/tok_$db)" --out $T/apply_$db.sql 2>/dev/null; }
mkcsv(){ printf 'Pay Friday,Agent,Paid Total,System Total,Locked At (ET),Note\n%s\n' "$2" > "$T/$1.csv"; echo "$T/$1.csv"; }
refuse(){ # name csv expected-substring
  $PY sql --csv "$2" --dry-run --no-lock-open --no-adjustments --out "$T/x.sql" 2>"$T/e"; rc=$?
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
hcsql --csv $FX --dry-run --lock-open $FO --out supabase/x_hub.sql 2>"$T/e"; rc=$?
res "L13 generated SQL can't be written inside the git tree" "$([ $rc != 0 ] && [ ! -e supabase/x_hub.sql ] && grep -q 'inside the git tree' "$T/e" && echo PASS || echo FAIL)" ""
hcsql --csv $FX --lock-open $FO --out "$T/x.sql" 2>"$T/e"; rc=$?
res "L14 sql needs exactly one of --dry-run / --confirm-hub" "$([ $rc != 0 ] && grep -q 'exactly one' "$T/e" && echo PASS || echo FAIL)" ""
# build: unformatted (serials) vs formatted reads must agree
printf 'Pay Friday,Agent,Paid Total,System Total,Locked At (ET),Note\n46325,A Test,170,170,46324.694444444445,n\n46318,A Test,425.59000000000003,,46318.47430555556,n\n' > $T/u.csv
printf 'Pay Friday,Agent,Paid Total,System Total,Locked At (ET),Note\n2026-10-30,A Test,$170.00,$170.00,2026-10-29 16:40,n\n2026-10-23,A Test,$425.59,,10/23/2026,n\n' > $T/f.csv
$PY build --unformatted $T/u.csv --formatted $T/f.csv --out $T/b.csv --no-lock-open --no-adjustments >/dev/null 2>&1; rc=$?
res "B1 build: serials -> ISO dates, cents, Locked At time recovered from the serial (display showed date only)" "$([ $rc = 0 ] && grep -q '^2026-10-23,A Test,425.59,,2026-10-23 11:23,n$' $T/b.csv && grep -q '^2026-10-30,A Test,170.00,170.00,2026-10-29 16:40,n$' $T/b.csv && [ "$(stat -c %a $T/b.csv)" = 600 ] && echo PASS || echo FAIL)" "$(sed -n 3p $T/b.csv)"
sed -i 's/\$425.59/$425.60/' $T/f.csv
$PY build --unformatted $T/u.csv --formatted $T/f.csv --out $T/b2.csv --no-lock-open --no-adjustments >/dev/null 2>"$T/e"; rc=$?
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
hcsql --csv $FX --lock-open $FO --dry-run --out $T/dry.sql 2>/dev/null
mkapply $D --csv $FX --lock-open $FO; cp $T/apply_$D.sql $T/apply.sql
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
res "D6 APPLY as postgres (SQL Editor break-glass, with the dry run's token): 7 rows, sum 1814.36, cutover last 10/30, paydays {10/16,10/23,10/30}" "$([ $rc = 0 ] && [ "$(q $D -c 'select count(*)||'"'"'|'"'"'||sum(paid_total) from hub_paid_lock')" = '7|1814.36' ] && [ "$(q $D -c 'select last_hub_payday||'"'"'|'"'"'||paydays::text||'"'"'|'"'"'||row_count from hub_cutover')" = '2026-10-30|{2026-10-16,2026-10-23,2026-10-30}|7' ] && echo PASS || echo FAIL)" "$(err)"
res "D7 audited: payroll.hub_cutover.recorded + payroll.hub_cutover.import (path break-glass:postgres, per-payday totals)" "$([ "$(q $D -c "select count(*) from event_log where event_type='payroll.hub_cutover.recorded'")" = 1 ] && [ "$(q $D -c "select detail->>'path' from event_log where event_type='payroll.hub_cutover.import'")" = 'break-glass:postgres' ] && [ "$(q $D -c "select detail->'per_payday'->'2026-10-23'->>'paid' from event_log where event_type='payroll.hub_cutover.import'")" = 404.45 ] && echo PASS || echo FAIL)" ""
res "D8 Locked At stored in ET: 10/23 11:23 ET = 15:23 UTC; date-only 10/19 = 00:00 ET; negative paid kept" "$([ "$(q $D -c "select to_char(locked_at at time zone 'UTC','YYYY-MM-DD HH24:MI') from hub_paid_lock where row_num=4")" = '2026-10-23 15:23' ] && [ "$(q $D -c "select to_char(locked_at at time zone 'America/New_York','YYYY-MM-DD HH24:MI') from hub_paid_lock where row_num=6")" = '2026-10-19 00:00' ] && [ "$(q $D -c 'select paid_total from hub_paid_lock where row_num=7')" = -12.50 ] && echo PASS || echo FAIL)" ""
EV1=$(q $D -c "select count(*) from event_log")
rc=$(run $D $T/apply.sql)
res "D9 re-running the same APPLY is a no-op (notice; rows, cutover and event_log unchanged)" "$([ $rc = 0 ] && grep -q 'already recorded from this file' $T/out && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 7 ] && [ "$(q $D -c 'select count(*) from event_log')" = $EV1 ] && echo PASS || echo FAIL)" "$(err)"
rc=$(run $D $T/dry.sql)
res "D10 dry run after it is recorded says so (nothing to do)" "$([ $rc != 0 ] && grep -q 'DRY RUN: already recorded from this file' $T/out && echo PASS || echo FAIL)" ""
sed 's/MOCK desk submit/MOCK desk submit edited/' $FX > $T/other.csv; hcsql --csv $T/other.csv --lock-open $FO --confirm-hub --dry-run-token ABCDEF0123 --out $T/other.sql 2>/dev/null
rc=$(run $D $T/other.sql)
res "D11 a different file after the cutover is refused (one-time, immutable)" "$([ $rc != 0 ] && grep -q 'already recorded from another file' $T/out && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 7 ] && echo PASS || echo FAIL)" "$(err)"
rc=$(q $D -c "update hub_paid_lock set paid_total = 1 where row_num = 1" >/dev/null 2>&1; echo $?); rc2=$(q $D -c "delete from hub_cutover" >/dev/null 2>&1; echo $?)
res "D12 recorded rows can't be edited or deleted, even as postgres" "$([ $rc != 0 ] && [ $rc2 != 0 ] && [ "$(q $D -c 'select count(*) from hub_cutover')" = 1 ] && echo PASS || echo FAIL)" ""

# owner login path (Kyle's login): payroll owner = admin.test (an admin)
D=hubcut_t2; fresh $D; A=$(q $D -c "select id from auth.users where email='admin.test@example.com'")
q $D -c "update recon_pay_config set payroll_owner_user_id = '$A' where id" >/dev/null
mkapply $D --csv $FX --lock-open $FO; { as $A; cat $T/apply_$D.sql; } > $T/own.sql; rc=$(run $D $T/own.sql)
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
D=hubcut_t5; fresh $D; mkapply $D --csv $FX --lock-open $FO; cp $T/apply_$D.sql $T/apply.sql
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
mkapply $D --csv $FX --lock-open $FO; rc=$(run $D $T/apply_$D.sql)
res "D20 with the mock board loaded: weeks through 10/30 frozen (reason hub_cutover); cutover_pending_kyle lines become paid_by_hub" "$([ $rc = 0 ] && [ "$(q $D -c "select count(*) from board_week_freezes where reason='hub_cutover'")" -gt 0 ] && [ "$(q $D -c "select count(*) from premier_recon_trueup where cutover_status = 'cutover_pending_kyle'")" = 0 ] && [ "$(q $D -c "select count(*) from premier_recon_trueup where cutover_status = 'paid_by_hub'")" -gt 0 ] && echo PASS || echo FAIL)" "$(grep -o 'board submissions frozen [0-9]*' $T/out) pending $PEND0 -> $(q $D -c "select count(*) from premier_recon_trueup where cutover_status = 'cutover_pending_kyle'"), paid_by_hub $(q $D -c "select count(*) from premier_recon_trueup where cutover_status = 'paid_by_hub'")"
D=hubcut_t7; fresh $D
q $D -c "insert into payroll_cutoffs (payday, cutoff_at, source, note) values ('2026-10-16', '2026-10-15 14:00 America/New_York', 'submit', 'test')" >/dev/null
hcsql --csv $FX --lock-open $FO --dry-run --out $T/d21.sql 2>/dev/null; rc=$(run $D $T/d21.sql)
res "D21 DB guard (hub_paid_lock_guard): a Pay Friday after the last recorded submit + 7 days is refused (typo guard)" "$([ $rc != 0 ] && grep -q 'after the last recorded submit' $T/out && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 0 ] && echo PASS || echo FAIL)" "$(err)"


# ---------- O. Lock Open Items: file, snapshot, token, roster ----------
printf 'Line ID,Agent,Member ID,Type,Original Pay Friday,Est Commission,Status at Lock,Locked Through,Paid On,Note\n20261005101010-600000001-P,A Test,600000001,Premier,10/9/2026,98.4,Awaiting first payment,10/16/2026,,post date open at the 10/16 start line\n20261012101010-600000002-P,A Test,600000002,Premier,10/23/2026,367.65,Awaiting first payment,10/23/2026,2026-10-30,post date open at the 10/23 lock\n20261013101010-600000004-P,A Test,600000004,Premier,10/23/2026,12,Not in PHS - unconfirmed,10/23/2026,,unconfirmed at the 10/23 lock - pays on the first open payday\n' > $T/lo.csv
$PY build --unformatted $T/u.csv --formatted $T/f0.csv --out $T/b3.csv --lock-open-formatted $T/lo.csv --lock-open-out $T/lo_imp.csv >/dev/null 2>&1 || true
printf 'Pay Friday,Agent,Paid Total,System Total,Locked At (ET),Note\n2026-10-30,A Test,$170.00,$170.00,2026-10-29 16:40,n\n2026-10-23,A Test,$425.59,,10/23/2026,n\n' > $T/f0.csv
# fake Manual Adjustments tab (hub layout) + fake hub code cover seeds (one with a wrong line id is simply not listed)
printf 'Agent,Payday,Amount,Reason/Note,Member ID,Entered By,Date Entered,Covers\nA Test,10/23/2026,10,Transfers through 10/22 2:46pm ET,,Kyle,10/22/2026\nA Test,10/23/2026,-55,Fakename add-on spiff already paid,,Desk,10/22/2026\nA Test,10/30/2026,40,Fake 600000005 ABS x2 moved from 10/23,600000005,Kyle,10/23/2026,pay spiff:20261020100000-600000005-ABS\nA Test,10/23/2026,-40,Fake 600000005 ABS x2 moved to 10/30,600000005,Kyle,10/23/2026,reverse spiff:20261020100000-600000005-ABS\nA Test,10/30/2026,20,Fake 600000005 W4Y moved from 10/23,600000005,Kyle,10/29/2026,pay spiff:20261020100000-600000005-P\nA Test,10/30/2026,400,help (not line-linked),,Kyle,10/29/2026\n' > $T/ma.csv
printf 'Agent,Payday,Amount,Note Regex,Kind,Items\n*,2026-10-23,,^Transfers through 10/22 2:46pm,pay,xfer\nA Test,2026-10-23,-55,^Fakename,dup,spiff:20261012100000-600000006-PADD\n' > $T/cs.csv
$PY build --unformatted $T/u.csv --formatted $T/f0.csv --out $T/b3x.csv --lock-open-formatted $T/lo.csv --lock-open-out $T/lo_x.csv >/dev/null 2>"$T/e"; rcx=$?
res "O0 build refuses without the Manual Adjustments tab (unless --no-adjustments); no placeholder / hub-code-seed option exists" "$([ $rcx != 0 ] && grep -q 'adjustments-formatted' $T/e && ! $PY build --help | grep -q 'code-seeds' && echo PASS || echo FAIL)" ""
$PY build --unformatted $T/u.csv --formatted $T/f0.csv --out $T/b3.csv --lock-open-formatted $T/lo.csv --lock-open-out $T/lo_imp.csv --adjustments-formatted $T/ma.csv --adjustments-out $T/adj_imp.csv --cover-seeds $T/cs.csv >/dev/null 2>&1; rc=$?
res "O1 build reads Lock Open Items + Manual Adjustments in the SAME pass: tab rows only (no placeholder), snapshot.json records every sha incl. the hub code cover seeds file" "$([ $rc = 0 ] && grep -q '^20261005101010-600000001-P,A Test,600000001,Premier,2026-10-09,98.40,Awaiting first payment,2026-10-16,,.*,post_date,lock_open_items_tab$' $T/lo_imp.csv && [ "$(grep -c '' $T/lo_imp.csv)" = 4 ] && ! grep -q hub_code_seed $T/lo_imp.csv && for f in $T/lo_imp.csv $T/adj_imp.csv $T/cs.csv $T/b3.csv; do grep -q "$(sha256sum < $f | cut -d' ' -f1)" $T/snapshot.json || exit 1; done && echo PASS || echo FAIL)" "$(grep -c '' $T/lo_imp.csv) lines"
res "A1 Manual Adjustments -> paid-elsewhere markers: every line-linked cover (Covers column pay/reverse, seed dup), xfer and plain adjustments skipped" "$([ "$(cut -d, -f1-8 $T/adj_imp.csv | tail -n +2 | sort | tr '\n' ' ')" = '3,20261012100000-600000006-PADD,spiffs,dup,A Test,2026-10-23,-55.00,cover_seed 4,20261020100000-600000005-ABS,spiffs,pay,A Test,2026-10-30,40.00,covers_column 5,20261020100000-600000005-ABS,spiffs,reverse,A Test,2026-10-23,-40.00,covers_column 6,20261020100000-600000005-P,spiffs,pay,A Test,2026-10-30,20.00,covers_column ' ] && echo PASS || echo FAIL)" "$(tail -n +2 $T/adj_imp.csv | cut -d, -f1-4 | tr '\n' ' ')"
# B-3: rows dated after the last hub payday (10/30) are never imported; build refuses until each is acknowledged
mkdir -p $T/a; MAH='Agent,Payday,Amount,Reason/Note,Member ID,Entered By,Date Entered,Covers'
printf '%s\nA Test,10/30/2026,200,Spot (fake),,Kyle,10/29/2026\nA Test,11/06/2026,-200,Spot payback (fake),,Kyle,10/29/2026\nB Test,11/06/2026,-300,Payback 1 of 2 (fake),,Kyle,10/29/2026\nB Test,11/13/2026,-300,Payback 2 of 2 (fake),,Kyle,10/29/2026\nA Test,11/05/2026,20,later linked (fake),,Kyle,10/29/2026,pay spiff:20261020100000-600000005-P\n' "$MAH" > $T/a/ma.csv
abuild(){ $PY build --unformatted $T/u.csv --formatted $T/f0.csv --out $T/a/b.csv --lock-open-formatted $T/lo.csv --lock-open-out $T/a/lo.csv --adjustments-formatted $T/a/ma.csv --adjustments-out $T/a/adj.csv --no-cover-seeds "$@"; }
abuild >$T/a/o 2>"$T/e"; rc=$?
res "A2 B-3: build REFUSES when Manual Adjustments rows are dated after the last hub payday and not acknowledged; lists each (row, payday, agent, amount), linked or not; must_reenter.csv written" "$([ $rc != 0 ] && grep -q 'MUST be re-entered' $T/e && grep -q 'row 3 2026-11-06 A Test -200.00' $T/e && grep -q 'row 5 2026-11-13 B Test -300.00' $T/e && grep -q 'row 6 2026-11-06 A Test +20.00' $T/e && [ "$(tail -n +2 $T/a/must_reenter.csv | cut -d, -f1-4 | tr '\n' ' ')" = '3,2026-11-06,A Test,-200.00 4,2026-11-06,B Test,-300.00 5,2026-11-13,B Test,-300.00 6,2026-11-06,A Test,20.00 ' ] && [ ! -e $T/a/snapshot.json ] && echo PASS || echo FAIL)" "$(grep -o 'REFUSED.*' $T/e | cut -c1-140)"
AKH='Tab Row,Payday,Agent,Amount,Acknowledged By'
printf '%s\n3,2026-11-06,A Test,-200.00,Kyle\n4,2026-11-06,B Test,-300.00,Kyle\n6,2026-11-06,A Test,20.00,Kyle\n' "$AKH" > $T/a/ack_short.csv
abuild --reenter-ack $T/a/ack_short.csv >$T/a/o 2>"$T/e"; rc=$?
res "A3 an ack that misses one row (row 5, -300 on 11/13) is refused, naming it" "$([ $rc != 0 ] && grep -q 'not acknowledged: row 5 2026-11-13 B Test -300.00; not on the list: none' $T/e && [ ! -e $T/a/snapshot.json ] && echo PASS || echo FAIL)" "$(grep -o 'not acknowledged.*' $T/e | cut -c1-120)"
printf '%s\n3,2026-11-06,A Test,-200.00,Kyle\n4,2026-11-06,B Test,-300.00,Kyle\n5,2026-11-13,B Test,-300.00,Kyle\n6,2026-11-06,A Test,20.00,\n' "$AKH" > $T/a/ack_blank.csv
abuild --reenter-ack $T/a/ack_blank.csv >$T/a/o 2>"$T/e"; rc=$?
res "A4 an ack row without Acknowledged By is refused" "$([ $rc != 0 ] && grep -q 'Acknowledged By' $T/e && echo PASS || echo FAIL)" ""
printf '%s\n3,2026-11-06,A Test,-200.00,Kyle\n4,2026-11-06,B Test,-300.00,Kyle\n5,2026-11-13,B Test,-300.00,Kyle\n6,2026-11-06,A Test,20.00,Kyle\n' "$AKH" > $T/a/ack.csv
abuild --reenter-ack $T/a/ack.csv >$T/a/o 2>"$T/e"; rc=$?
res "A5 full ack: build OK; the 4 rows are NOT imported (no marker, the linked 11/06 one neither); snapshot.json hashes must_reenter.csv + the ack" "$([ $rc = 0 ] && grep -q 'MUST RE-ENTER: 4 row(s), total -780.00 (acknowledged)' $T/a/o && [ "$(grep -c '' $T/a/adj.csv)" = 1 ] && python3 -c "import json,hashlib,sys; s=json.load(open('$T/a/snapshot.json')); sys.exit(0 if s['must_reenter']['sha256']==hashlib.sha256(open('$T/a/must_reenter.csv','rb').read()).hexdigest() and s['reenter_ack']['sha256']==hashlib.sha256(open('$T/a/ack.csv','rb').read()).hexdigest() else 1)" && echo PASS || echo FAIL)" "$(grep MUST $T/a/o)"
$PY sql --csv $T/a/b.csv --lock-open $T/a/lo.csv --adjustments $T/a/adj.csv --snapshot $T/a/snapshot.json --dry-run --out $T/a/d.sql >/dev/null 2>"$T/e"; rc=$?
res "A6 sql re-checks the ack from the snapshot: dry run SQL carries 'MUST RE-ENTER 4 row(s), total -780.00 (acknowledged), not imported' + both shas in the token / event" "$([ $rc = 0 ] && grep -q "'4 row(s), total -780.00 (acknowledged), not imported'" $T/a/d.sql && grep -q "c_re_ack    constant text := '$(sha256sum < $T/a/ack.csv | cut -d' ' -f1)'" $T/a/d.sql && grep -q "coalesce(c_re_sha, '-'), coalesce(c_re_ack, '-')" $T/a/d.sql && echo PASS || echo FAIL)" "$(head -c 150 $T/e)"
cp $T/a/ack.csv $T/a/ack.bak; sed -i '$d' $T/a/ack.csv
$PY sql --csv $T/a/b.csv --lock-open $T/a/lo.csv --adjustments $T/a/adj.csv --snapshot $T/a/snapshot.json --dry-run --out $T/a/d.sql 2>"$T/e"; rc=$?; cp $T/a/ack.bak $T/a/ack.csv
res "A7 the ack edited after build (a row dropped): sql refused" "$([ $rc != 0 ] && grep -q 're-enter ack .* changed or missing' $T/e && echo PASS || echo FAIL)" ""
cp $T/a/must_reenter.csv $T/a/m.bak; sed -i '$d' $T/a/must_reenter.csv
$PY sql --csv $T/a/b.csv --lock-open $T/a/lo.csv --adjustments $T/a/adj.csv --snapshot $T/a/snapshot.json --dry-run --out $T/a/d.sql 2>"$T/e"; rc=$?; cp $T/a/m.bak $T/a/must_reenter.csv
res "A8 must_reenter.csv edited after build (a row dropped): sql refused" "$([ $rc != 0 ] && grep -q 'must_reenter .* changed or missing' $T/e && echo PASS || echo FAIL)" ""
sed 's/,Kyle$/,REHEARSAL (Systems Build)/' $T/a/ack.bak > $T/a/ack_reh.csv; abuild --reenter-ack $T/a/ack_reh.csv >$T/a/o 2>/dev/null
$PY sql --csv $T/a/b.csv --lock-open $T/a/lo.csv --adjustments $T/a/adj.csv --snapshot $T/a/snapshot.json --dry-run --out $T/a/d.sql >/dev/null 2>&1; rc1=$?
$PY sql --csv $T/a/b.csv --lock-open $T/a/lo.csv --adjustments $T/a/adj.csv --snapshot $T/a/snapshot.json --confirm-hub --dry-run-token ABCDEF0123 --out $T/a/c.sql 2>"$T/e"; rc=$?
res "A9 a REHEARSAL ack is enough for a dry run but --confirm-hub refuses it (the APPLY needs Kyle's own ack)" "$([ $rc1 = 0 ] && [ $rc != 0 ] && grep -q 'REHEARSAL ack' $T/e && [ ! -e $T/a/c.sql ] && echo PASS || echo FAIL)" ""
$PY check --csv $T/a/b.csv --adjustments $T/a/adj.csv --must-reenter $T/a/must_reenter.csv --reenter-ack $T/a/ack_reh.csv > $T/a/chk; rc1=$?
$PY check --csv $T/a/b.csv --adjustments $T/a/adj.csv --must-reenter $T/a/must_reenter.csv > $T/a/chk2; rc=$?
res "A10 check lists MUST RE-ENTER (payday, agent, amount, row, note) with the ack state; without an ack it is a HARD error" "$([ $rc1 = 0 ] && grep -q '\*\*MUST RE-ENTER\*\*.*4 row(s), total -780.00\*\* — ack: rehearsal' $T/a/chk && grep -q '| 5 | 2026-11-13 | B Test | -300.00 | no | Payback 2 of 2 (fake) |' $T/a/chk && [ $rc = 1 ] && grep -q 'MUST RE-ENTER not acknowledged' $T/a/chk2 && echo PASS || echo FAIL)" ""
# S. mandatory snapshot
$PY sql --csv $T/b3.csv --lock-open $T/lo_imp.csv --adjustments $T/adj_imp.csv --dry-run --out $T/x.sql 2>"$T/e"; rc=$?
res "S1 sql without --snapshot is refused (mandatory)" "$([ $rc != 0 ] && grep -q 'snapshot.json (written by build) is mandatory' $T/e && echo PASS || echo FAIL)" ""
$PY sql --csv $T/b3.csv --lock-open $T/lo_imp.csv --adjustments $T/adj_imp.csv --snapshot $T/snapshot.json --dry-run --out $T/x.sql >/dev/null 2>"$T/e"; rc=$?
res "S2 sql with the build's snapshot: OK" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(head -c 150 $T/e)"
$PY sql --csv $T/b3.csv --lock-open $T/lo_imp.csv --no-adjustments --snapshot $T/snapshot.json --dry-run --out $T/x.sql 2>"$T/e"; rc=$?
res "S3 leaving out a file the snapshot has (--no-adjustments) is refused" "$([ $rc != 0 ] && grep -q 'has a adjustments file but none was passed' $T/e && echo PASS || echo FAIL)" ""
cp $T/cs.csv $T/cs.bak; echo 'A Test,2026-10-23,5,^x,pay,xfer' >> $T/cs.csv
$PY sql --csv $T/b3.csv --lock-open $T/lo_imp.csv --adjustments $T/adj_imp.csv --snapshot $T/snapshot.json --dry-run --out $T/x.sql 2>"$T/e"; rc=$?; cp $T/cs.bak $T/cs.csv
res "S4 the hub code cover seeds file changed after build (its sha is in snapshot.json): refused" "$([ $rc != 0 ] && grep -q 'cover seeds .* changed or missing' $T/e && echo PASS || echo FAIL)" ""

$PY build --unformatted $T/u.csv --formatted $T/f0.csv --out $T/b4.csv >/dev/null 2>"$T/e"; rc=$?
res "O2 build refuses without the Lock Open Items tab (unless --no-lock-open)" "$([ $rc != 0 ] && grep -q 'SAME pass' $T/e && echo PASS || echo FAIL)" ""
orefuse(){ printf 'Line ID,Agent,Member ID,Type,Original Pay Friday,Est Commission,Status at Lock,Locked Through,Paid On,Note,Kind,Source\n%s\n' "$2" > $T/o.csv
  hcsql --csv $FX --lock-open $T/o.csv --dry-run --out $T/x.sql 2>"$T/e"; rc=$?
  res "$1" "$([ $rc != 0 ] && grep -q -- "$3" "$T/e" && echo PASS || echo FAIL)" "$(grep -o 'REFUSED.*' "$T/e" | cut -c1-110)"; }
orefuse "O3 open item: Line ID not <Timestamp>-<Member>-<Type>" '2026100510-600000001-P,A,600000001,Premier,2026-10-09,1.00,s,2026-10-16,,n,post_date,lock_open_items_tab' "is not <Timestamp>"
orefuse "O4 open item: Type vs Line ID suffix" '20261005101010-600000001-P,A,600000001,ABS,2026-10-09,1.00,s,2026-10-16,,n,post_date,lock_open_items_tab' "does not match the Line ID suffix"
orefuse "O5 open item: Member ID vs Line ID" '20261005101010-600000001-P,A,600000009,Premier,2026-10-09,1.00,s,2026-10-16,,n,post_date,lock_open_items_tab' "is not the one in the Line ID"
orefuse "O6 open item: duplicate Line ID" $'20261005101010-600000001-P,A,600000001,Premier,2026-10-09,1.00,s,2026-10-16,,n,post_date,lock_open_items_tab\n20261005101010-600000001-P,B,600000001,Premier,2026-10-09,1.00,s,2026-10-16,,n,post_date,lock_open_items_tab' "duplicate Line ID"
orefuse "O7 open item: Paid On not after Locked Through" '20261005101010-600000001-P,A,600000001,Premier,2026-10-09,1.00,s,2026-10-16,2026-10-16,n,post_date,lock_open_items_tab' "is not after Locked Through"
orefuse "O8 open item: Paid On after the Paid Lock file's last payday (not the same snapshot)" '20261005101010-600000001-P,A,600000001,Premier,2026-10-09,1.00,s,2026-10-30,2026-11-06,n,post_date,lock_open_items_tab' "re-read both tabs together"
hcsql --csv $FX --dry-run --out $T/x.sql 2>"$T/e"; rc=$?
res "O9 sql refuses without --lock-open (or an explicit --no-lock-open)" "$([ $rc != 0 ] && grep -q 'pass --lock-open' $T/e && echo PASS || echo FAIL)" ""
hcsql --csv $FX --lock-open $FO --confirm-hub --out $T/x.sql 2>"$T/e"; rc=$?
res "O10 --confirm-hub refuses without the dry run's token" "$([ $rc != 0 ] && grep -q 'needs --dry-run-token' $T/e && echo PASS || echo FAIL)" ""
$PY sql --csv $T/b3.csv --lock-open $FO --no-adjustments --snapshot $T/snapshot.json --dry-run --out $T/x.sql 2>"$T/e"; rc=$?
res "O11 --snapshot refuses a Lock Open file that is not from the same read as the Paid Lock file" "$([ $rc != 0 ] && grep -q 'is not the lock_open file of snapshot' $T/e && echo PASS || echo FAIL)" ""

D=hubcut_t8; fresh $D
hcsql --csv $FX --lock-open $FO --confirm-hub --dry-run-token ABCDEF0123 --out $T/badtok.sql 2>/dev/null; rc=$(run $D $T/badtok.sql)
res "T1 APPLY with a token from no dry run is refused (nothing written, DDL rolled back too)" "$([ $rc != 0 ] && grep -q 'dry-run token ABCDEF0123 does not match' $T/out && [ "$(q $D -c 'select (select count(*) from hub_paid_lock)+(select count(*) from hub_cutover)+(select count(*) from hub_lock_open_items)')" = 0 ] && echo PASS || echo FAIL)" "$(err)"
mkapply $D --csv $FX --lock-open $FO
q $D -c "insert into agent_name_aliases (alias, agent_id) select 'Alex T', id from agents where display_name = 'Alex Testagent (fake)'" >/dev/null
rc=$(run $D $T/apply_$D.sql)
res "T2 the live state changed after the dry run (an alias was added): APPLY refused, re-dry-run needed" "$([ $rc != 0 ] && grep -q 'does not match the live state' $T/out && [ "$(q $D -c 'select count(*) from hub_cutover')" = 0 ] && echo PASS || echo FAIL)" "$(err)"
mkapply $D --csv $FX --lock-open $FO; rc=$(run $D $T/apply_$D.sql)
res "T3 fresh dry run -> its token -> APPLY: 7 Paid Lock rows + 3 Lock Open Items (2 still open), event has token + open-item totals" "$([ $rc = 0 ] && [ "$(q $D -c 'select count(*)||'"'"'/'"'"'||count(*) filter (where paid_on is null) from hub_lock_open_items')" = 3/2 ] && [ "$(q $D -c "select detail->>'dry_run_token' from event_log where event_type='payroll.hub_cutover.import'")" = "$(cat $T/tok_$D)" ] && [ "$(q $D -c "select detail->'lock_open_items'->>'est_commission' from event_log where event_type='payroll.hub_cutover.import'")" = 98.40 ] && echo PASS || echo FAIL)" "token $(cat $T/tok_$D)"
rc=$(q $D -c "insert into hub_lock_open_items (file_sha256,row_num,line_id,agent_name,line_type,original_pay_friday,est_commission,locked_through,kind) values (repeat('e',64),1,'20261005101010-600000009-P','x','Premier','2026-10-09',1,'2026-10-16','post_date')" >/dev/null 2>&1; echo $?)
rc2=$(q $D -c "update hub_lock_open_items set paid_on = '2026-11-06'" >/dev/null 2>&1; echo $?)
res "T4 after the cutover no more open items can be added, and none edited (one-time, immutable)" "$([ $rc != 0 ] && [ $rc2 != 0 ] && [ "$(q $D -c 'select count(*) from hub_lock_open_items')" = 3 ] && echo PASS || echo FAIL)" ""
D=hubcut_t9; fresh $D
sed 's/^2026-10-30,Blair Sample (fake),/2026-10-30,Blair Sampel (fake),/' $FX > $T/typo.csv
hcsql --csv $T/typo.csv --lock-open $FO --dry-run --out $T/typo_dry.sql 2>/dev/null; rc=$(run $D $T/typo_dry.sql)
res "N1 roster check: a misspelled agent carrying dollars BLOCKS the dry run (no token issued)" "$([ $rc != 0 ] && grep -q 'DRY RUN BLOCKED.*Blair Sampel (fake)' $T/out && ! grep -q 'DRY RUN TOKEN' $T/out && echo PASS || echo FAIL)" "$(grep -oE 'BLOCKED[^.]*' $T/out | cut -c1-150)"
fp=$(grep -oE "fp := md5" $T/typo_dry.sql | head -1)
sed "s/c_dry    constant boolean := true/c_dry    constant boolean := false/" $T/typo_dry.sql > $T/typo_force.sql
tok=$(psql -X -At -d $D -c "select 1" >/dev/null; echo none)
rc=$(run $D $T/typo_force.sql)
res "N2 roster check in APPLY: refused (even with the dry-run switch flipped by hand, it stops at the token or the roster)" "$([ $rc != 0 ] && grep -qE 'does not match the live state|match no backend roster' $T/out && [ "$(q $D -c 'select count(*) from hub_cutover')" = 0 ] && echo PASS || echo FAIL)" "$(err)"
res "N3 UNKNOWN at \$0 is exempt from the roster check (the mock file's UNKNOWN row passes D1/D6)" "$(grep -q 'no backend agent id: UNKNOWN' $T/dryout_hubcut_t8 && grep -q 'DRY RUN TOKEN' $T/dryout_hubcut_t8 && echo PASS || echo FAIL)" ""

# ---------- X. exemption: an open item due on/before 10/30 pays once Premier confirms; one the hub paid stays $0 ----------
LINE=20261016112240-687990338-P
openfx(){ printf 'Line ID,Agent,Member ID,Type,Original Pay Friday,Est Commission,Status at Lock,Locked Through,Paid On,Note,Kind,Source\n%s,Nicholas Ziccardi,687990338,Premier,2026-10-23,119.32,Awaiting first payment,2026-10-23,%s,MOCK open item,post_date,lock_open_items_tab\n' "$LINE" "$1" > $T/$2; }
roster(){ q $1 -c "insert into agents (display_name, role) values ('Nicholas Ziccardi', 'agent') on conflict do nothing" >/dev/null; }
pv(){ q $1 -c "select coalesce(t.cutover_status,'-')||'|'||coalesce(t.pay_commission::text,'null')||'|'||coalesce(h.hub_open_pay_friday::text,'-')||'|'||l.commission_pay_friday from premier_recon_trueup t join premier_recon_lines l using (line_key) left join premier_recon_hub_open h on h.line_key = t.line_key where l.hub_line_id = '$LINE'"; }
submit(){ q $1 -c "insert into payroll_cutoffs (payday, cutoff_at, source, note) values ('$2', ('$2'::date - 1 + time '14:00') at time zone 'America/New_York', 'submit', 'test') on conflict (payday) do update set source = 'submit', cutoff_at = excluded.cutoff_at" >/dev/null; }
locks(){ q $1 -c "select coalesce(string_agg(component||'@'||payday||'='||amount, ','), 'none') from pay_line_locks where line_key = (select line_key from premier_recon_lines where hub_line_id = '$LINE')"; }
python3 supabase/tests/fixtures/premier_mock_variant.py $PMOCK $T/pv2.csv unpaid; python3 supabase/tests/fixtures/premier_mock_variant.py $PMOCK $T/pv3.csv paid2
D=hubcut_ta; fresh $D; psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed_slice3_mock.sql >/dev/null 2>&1; roster $D
python3 scripts/csv_to_recon_sql.py --mock --premier $T/pv2.csv --psql "-d $D" >/dev/null 2>&1
openfx '' open_a.csv; mkapply $D --csv $FX --lock-open $T/open_a.csv; rc=$(run $D $T/apply_$D.sql)
res "X0 cutover with Nick's open item (post date due 10/23, NOT yet confirmed by Premier): recorded, 1 open item matched to a board line" "$([ $rc = 0 ] && grep -q '1 still open, est 119.32; 1 matched' $T/out && echo PASS || echo FAIL)" "$(pv $D)"
submit $D 2026-11-06; q $D -c "select premier_lock_payday('2026-11-06')" >/dev/null 2>"$T/e"
res "X1 before Premier confirms: nothing to pay (0), nothing locked at the 11/06 lock" "$([ "$(locks $D)" = none ] && pv $D | grep -qE '\|0(\.00)?\|' && echo PASS || echo FAIL)" "$(pv $D) locks=$(locks $D) $(head -c 120 $T/e)"
python3 scripts/csv_to_recon_sql.py --mock --premier $T/pv3.csv --psql "-d $D" >/dev/null 2>&1
res "X2 (a) Premier confirms (first billing 10/16 -> due 10/23, on/before the cutover): hub_open_item, pays 119.32 on the next open payday 11/13 (not paid_by_hub)" "$([ "$(pv $D)" = 'hub_open_item|119.32|2026-11-13|2026-10-23' ] && echo PASS || echo FAIL)" "$(pv $D)"
submit $D 2026-11-13; n=$(q $D -c "select premier_lock_payday('2026-11-13')")
res "X3 (a) the 11/13 lock locks it ONCE: commission 119.32 on 11/13 (note says hub open item, due 10/23)" "$([ "$(locks $D)" = 'commission@2026-11-13=119.32' ] && [ "$(q $D -c "select note from pay_line_locks where line_key like '20261016112240-%'")" = 'locked by premier_lock_payday (hub open item, due 2026-10-23)' ] && echo PASS || echo FAIL)" "$(locks $D)"
submit $D 2026-11-20; q $D -c "select premier_lock_payday('2026-11-20')" >/dev/null; q $D -c "select premier_lock_payday('2026-11-13')" >/dev/null
res "X4 (a) never twice: re-lock 11/13 and lock 11/20 add nothing for it; true-up now shows the locked 119.32, no status" "$([ "$(locks $D)" = 'commission@2026-11-13=119.32' ] && [ "$(pv $D)" = '-|119.32|-|2026-10-23' ] && echo PASS || echo FAIL)" "$(pv $D)"
D=hubcut_tb; fresh $D; psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed_slice3_mock.sql >/dev/null 2>&1; roster $D
openfx 2026-10-30 open_b.csv; mkapply $D --csv $FX --lock-open $T/open_b.csv; rc=$(run $D $T/apply_$D.sql)
submit $D 2026-11-06; q $D -c "select premier_lock_payday('2026-11-06')" >/dev/null
res "X5 (b) an open item the hub already paid (Paid On 10/30, like the real one in the private file): stays paid_by_hub, \$0, never locked" "$([ $rc = 0 ] && [ "$(pv $D)" = 'paid_by_hub|0|-|2026-10-23' ] && [ "$(locks $D)" = none ] && echo PASS || echo FAIL)" "$(pv $D)"
D=hubcut_tc; fresh $D; psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed_slice3_mock.sql >/dev/null 2>&1; roster $D
printf 'Line ID,Agent,Member ID,Type,Original Pay Friday,Est Commission,Status at Lock,Locked Through,Paid On,Note,Kind,Source\n' > $T/open_c.csv
mkapply $D --csv $FX --lock-open $T/open_c.csv; rc=$(run $D $T/apply_$D.sql)
submit $D 2026-11-06; q $D -c "select premier_lock_payday('2026-11-06')" >/dev/null
res "X6 control: the same confirmed line with NO open item is paid_by_hub (\$0), never locked" "$([ $rc = 0 ] && [ "$(pv $D)" = 'paid_by_hub|0|-|2026-10-23' ] && [ "$(locks $D)" = none ] && echo PASS || echo FAIL)" "$(pv $D)"


# ---------- P. hub-era line-linked adjustments = paid-elsewhere markers: recomputing spiffs after the cutover pays $0 ----------
PL1=20261030132409-687990114-P; PL2=20261030121103-687990909-ABS     # mock lines, spiffs due 11/06 (after the 10/30 cutover)
spv(){ q $1 -c "select string_agg(l.hub_line_id||'='||coalesce(t.cutover_status,'-')||'/'||coalesce(t.pay_claimed_spiffs::text,'null')||'/'||coalesce(t.pay_missed_spiffs::text,'null'), ' ' order by l.hub_line_id) from premier_recon_trueup t join premier_recon_lines l using (line_key) where l.hub_line_id in ('$PL1','$PL2')"; }
slocks(){ q $1 -c "select coalesce(string_agg(l.hub_line_id||':'||k.component||'@'||k.payday||'='||k.amount, ' ' order by l.hub_line_id, k.component), 'none') from pay_line_locks k join premier_recon_lines l using (line_key) where l.hub_line_id in ('$PL1','$PL2')"; }
D=hubcut_pc; fresh $D; psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed_slice3_mock.sql >/dev/null 2>&1
mkapply $D --csv $FX --lock-open $FO --no-adjustments; rc=$(run $D $T/apply_$D.sql); submit $D 2026-11-06; q $D -c "select premier_lock_payday('2026-11-06')" >/dev/null
res "P0 control (no markers): the two mock spiffs due 11/06 lock and pay on 11/06 (75 + 80)" "$([ $rc = 0 ] && [ "$(slocks $D)" = "$PL2:claimed_spiffs@2026-11-06=80.00 $PL1:claimed_spiffs@2026-11-06=75.00 $PL1:commission@2026-11-06=$(q $D -c "select actual_commission from premier_recon_lines where hub_line_id = '$PL1'")" ] && echo PASS || echo FAIL)" "$(slocks $D)"
D=hubcut_pe; fresh $D; psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed_slice3_mock.sql >/dev/null 2>&1
mkapply $D --csv $FX --lock-open $FO --adjustments $FA; rc=$(run $D $T/apply_$D.sql)
res "P1 cutover imports the line-linked adjustments as paid-elsewhere markers (3 markers, 2 line components on loaded board lines), not as pay" "$([ $rc = 0 ] && grep -q 'paid-elsewhere markers 3 (2 matched)' $T/dryout_$D && [ "$(q $D -c 'select count(*) from hub_paid_elsewhere')" = 3 ] && [ "$(q $D -c 'select count(*) from pay_adjustments')" = "$(q hubcut_pc -c 'select count(*) from pay_adjustments')" ] && echo PASS || echo FAIL)" "$(grep -oE 'paid-elsewhere markers [0-9]+ \([0-9]+ matched\)' $T/dryout_$D)"
res "P2 true-up: both marked spiffs pay \$0 (status hub_paid_elsewhere); the line's commission is untouched" "$([ "$(spv $D)" = "$PL2=hub_paid_elsewhere/0/0 $PL1=hub_paid_elsewhere/0/0" ] && [ "$(q $D -c "select pay_commission from premier_recon_trueup t join premier_recon_lines l using (line_key) where l.hub_line_id = '$PL1'")" = "$(q hubcut_pc -c "select actual_commission from premier_recon_lines where hub_line_id = '$PL1'")" ] && echo PASS || echo FAIL)" "$(spv $D)"
python3 scripts/csv_to_recon_sql.py --mock --premier $PMOCK --psql "-d $D" >/dev/null 2>&1; q $D -c "select premier_anchor_missed_spiffs()" >/dev/null 2>&1
submit $D 2026-11-06; q $D -c "select premier_lock_payday('2026-11-06')" >/dev/null; submit $D 2026-11-13; q $D -c "select premier_lock_payday('2026-11-13')" >/dev/null
res "P3 recompute spiffs after the cutover (Premier re-import + missed-spiff anchoring) and lock 11/06 + 11/13: the marked spiffs pay \$0, never locked; the commission still locks" "$([ "$(slocks $D)" = "$PL1:commission@2026-11-06=$(q hubcut_pc -c "select amount from pay_line_locks k join premier_recon_lines l using (line_key) where l.hub_line_id = '$PL1' and component = 'commission'")" ] && [ "$(spv $D)" = "$PL2=hub_paid_elsewhere/0/0 $PL1=hub_paid_elsewhere/0/0" ] && echo PASS || echo FAIL)" "$(slocks $D) | $(spv $D)"
rc=$(q $D -c "insert into hub_paid_elsewhere (file_sha256, tab_row, line_id, component, cover_kind, agent_name, payday, amount, source) values (repeat('e',64), 9, '$PL1', 'commission', 'pay', 'x', '2026-10-30', 1, 'covers_column')" >/dev/null 2>&1; echo $?)
rc2=$(q $D -c "delete from hub_paid_elsewhere" >/dev/null 2>&1; echo $?)
res "P4 markers are one-time and immutable (no insert after the cutover, no delete)" "$([ $rc != 0 ] && [ $rc2 != 0 ] && [ "$(q $D -c 'select count(*) from hub_paid_elsewhere')" = 3 ] && echo PASS || echo FAIL)" ""
# ---------- RG. rerun guard: the 10/31 views migration re-run after 20261101120000 is caught, not silent ----------
psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/migrations/20261031210100_premier_recon_views.sql >/dev/null 2>&1; rr=$?
submit $D 2026-11-20; psql -X -At -v ON_ERROR_STOP=1 -d $D -c "select premier_lock_payday('2026-11-20')" >/dev/null 2>"$T/e"; rc=$?
res "RG1 after re-running 20261031210100 (exemption gone) locking a payday is REFUSED by the guard: re-run 20261101120000 first" "$([ $rr = 0 ] && [ $rc != 0 ] && grep -q 're-run 20261101120000 first' $T/e && [ "$(q $D -c 'select public.hub_open_items_schema_ok()')" = f ] && echo PASS || echo FAIL)" "$(grep -oE 'ERROR: .*' $T/e | cut -c1-140)"
rc=$(run $D supabase/deploy/hub_cutover_preflight.sql)
res "RG2 the read-only preflight refuses in that state too" "$([ $rc != 0 ] && grep -q 'lack the open-item exemption' $T/out && echo PASS || echo FAIL)" "$(err)"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/migrations/20261101120000_hub_lock_open_items.sql >/dev/null 2>&1; rr=$?
psql -X -At -v ON_ERROR_STOP=1 -d $D -c "select premier_lock_payday('2026-11-20')" >/dev/null 2>"$T/e"; rc=$?
res "RG3 re-running 20261101120000 restores the exemption + markers; locking works again and the marked spiffs still never lock" "$([ $rr = 0 ] && [ $rc = 0 ] && [ "$(q $D -c 'select public.hub_open_items_schema_ok()')" = t ] && [ "$(spv $D)" = "$PL2=hub_paid_elsewhere/0/0 $PL1=hub_paid_elsewhere/0/0" ] && echo PASS || echo FAIL)" "$(spv $D)"
# ---------- CB. hub-era clawbacks are 'settled by hub' (never 'needs Kyle approve', can't be approved twice) ----------
# ---------- DR. a marked part whose backend amount differs from what the hub paid is flagged (not silently lost) ----------
CL1=20261026112311-687990191-P; CL2=20261026114504-687990198-P; CL3=20261016112240-687990338-P
{ cat $FA; echo "8,$CL1,commission,claw,Alex Testagent (fake),2026-10-30,-111.37,cover_seed,MOCK void clawed by hand on 10/30"; } > $T/fa_cb.csv
python3 supabase/tests/fixtures/premier_mock_variant.py $PMOCK $T/pv_ref.csv refund338
D=hubcut_cb; fresh $D; psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed_slice3_mock.sql >/dev/null 2>&1
python3 scripts/csv_to_recon_sql.py --mock --premier $T/pv_ref.csv --psql "-d $D" >/dev/null 2>&1
cbv(){ q $1 -c "select string_agg(hub_line_id||'='||status, ' ' order by hub_line_id) from premier_recon_clawbacks where hub_line_id in ('$CL1','$CL2','$CL3')"; }
CB0=$(cbv $D)
mkapply $D --csv $FX --lock-open $FO --adjustments $T/fa_cb.csv; rc=$(run $D $T/apply_$D.sql)
res "CB1 before the cutover all three refunds/voids need Kyle; after it: the 10/23 refund (date on/before 10/30) and the void the hub clawed by hand (claw marker) are settled_by_hub, the 11/06 refund still needs Kyle" "$([ $rc = 0 ] && [ "$CB0" = "$CL3=needs_kyle_approve $CL1=needs_kyle_approve $CL2=needs_kyle_approve" ] && [ "$(cbv $D)" = "$CL3=settled_by_hub $CL1=settled_by_hub $CL2=needs_kyle_approve" ] && echo PASS || echo FAIL)" "$CB0 -> $(cbv $D)"
q $D -c "select premier_log_recon_events()" >/dev/null 2>"$T/e"
ev(){ q $D -c "select coalesce(string_agg(detail->>'status', ',' order by id), 'none') from event_log where row_id = (select line_key from premier_recon_lines where hub_line_id = '$1') and detail->>'kind' like 'clawback%'"; }
res "CB2 the event log shows 'settled by hub' for both hub-era ones (never 'needs Kyle approve'); the 11/06 one still asks Kyle" "$([ "$(ev $CL1)" = 'settled by hub' ] && [ "$(ev $CL3)" = 'settled by hub' ] && [ "$(ev $CL2)" = 'needs Kyle approve; spiffs kept' ] && [ "$(q $D -c "select count(*) from event_log where event_type = 'hub_cutover.clawback_settled_by_hub'")" = 2 ] && echo PASS || echo FAIL)" "$(ev $CL1) | $(ev $CL3) | $(ev $CL2) $(head -c 100 $T/e)"
padj(){ psql -X -At -v ON_ERROR_STOP=1 -d $D -c "insert into pay_adjustments (line_key, member_id, agent_name, payday, kind, component, amount, reason) select line_key, member_id, agent_name, '2026-11-13', 'clawback_approved', 'commission', clawback_proposed, 'test' from premier_recon_lines where hub_line_id = '$1'" >/dev/null 2>"$T/e"; echo $?; }
r1=$(padj $CL1); e1=$(grep -o 'settled by hub[^;]*' $T/e); r3=$(padj $CL3); e3=$(grep -o 'settled by hub[^;]*' $T/e); r2=$(padj $CL2)
res "CB3 approving a second clawback of a hub-settled one is REFUSED (claw marker / date); the 11/06 one can still be approved (-> approved)" "$([ $r1 != 0 ] && [ -n "$e1" ] && [ $r3 != 0 ] && [ -n "$e3" ] && [ $r2 = 0 ] && [ "$(cbv $D)" = "$CL3=settled_by_hub $CL1=settled_by_hub $CL2=approved" ] && [ "$(q $D -c "select count(*) from pay_adjustments where kind = 'clawback_approved'")" = 1 ] && echo PASS || echo FAIL)" "$e1 | $e3 | r2=$r2"
drv(){ q $D -c "select string_agg(hub_line_id||':'||component||'='||status||'/'||coalesce(hub_amount::text,'-')||'/'||coalesce(backend_amount::text,'-'), ' ' order by hub_line_id, component) from premier_recon_paid_elsewhere_drift"; }
res "DR1 drift view right after the cutover: every marked part matches what the hub paid / clawed (spiff 75, ABS 80, void claw 111.37); nothing logged" "$([ "$(drv $D)" = "$CL1:commission=matches/111.37/111.37 $PL2:spiffs=matches/80.00/80.00 $PL1:spiffs=matches/75.00/75.00" ] && [ "$(q $D -c "select count(*) from event_log where event_type = 'hub_cutover.paid_elsewhere_amount_differs'")" = 0 ] && echo PASS || echo FAIL)" "$(drv $D)"
python3 supabase/tests/fixtures/premier_mock_variant.py $PMOCK $T/pv_add.csv addon114
python3 scripts/csv_to_recon_sql.py --mock --premier $T/pv_add.csv --psql "-d $D" >/dev/null 2>&1; q $D -c "select premier_log_recon_events()" >/dev/null
res "DR2 a later add-on on the marked spiff (Premier now 95, hub paid 75): flagged 'differs' (+20.00) in the view and logged once (hub_cutover.paid_elsewhere_amount_differs), not paid automatically (true-up still \$0)" "$([ "$(drv $D)" = "$CL1:commission=matches/111.37/111.37 $PL2:spiffs=matches/80.00/80.00 $PL1:spiffs=differs/75.00/95.00" ] && [ "$(q $D -c "select string_agg(detail->>'hub_line_id'||' '||(detail->>'difference'), ',') from event_log where event_type = 'hub_cutover.paid_elsewhere_amount_differs'")" = "$PL1 20.00" ] && [ "$(q $D -c "select coalesce(pay_claimed_spiffs,0)+coalesce(pay_missed_spiffs,0) from premier_recon_trueup t join premier_recon_lines l using (line_key) where l.hub_line_id = '$PL1'")" = 0 ] && q $D -c "select premier_log_recon_events()" >/dev/null && [ "$(q $D -c "select count(*) from event_log where event_type = 'hub_cutover.paid_elsewhere_amount_differs'")" = 1 ] && echo PASS || echo FAIL)" "$(drv $D)"
# ---------- G. order guard: #7 must land before slice 4a (20261101100000 / 20261101100100) ----------
D=hubcut_g1; psql -q -d postgres -c "drop database if exists $D" -c "create database $D" >/dev/null 2>&1
psql -q -v ON_ERROR_STOP=1 -d $D -f supabase/tests/local_supabase_stub.sql >/dev/null 2>&1
psql -q -d $D -c "insert into auth.users(email) values ('admin.test@example.com'),('agent.test@example.com'),('agent2.test@example.com')" >/dev/null
for f in supabase/migrations/*.sql; do [ "$f" = supabase/migrations/20261101120000_hub_lock_open_items.sql ] && continue; psql -X -q -v ON_ERROR_STOP=1 -d $D -f $f >/dev/null 2>&1; done
psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed.sql >/dev/null 2>&1
q $D -c "create schema if not exists supabase_migrations; create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text); insert into supabase_migrations.schema_migrations (version, name) values ('20261101100100', 'closed_week_next_open_payday')" >/dev/null
rc=$(run $D supabase/migrations/20261101120000_hub_lock_open_items.sql)
res "G1 migration 20261101120000 refuses when 4a's 20261101100100 is already recorded (wrong order would drop 4a's carry); nothing created" "$([ $rc != 0 ] && grep -q 'slice 4a (20261101100000 / 20261101100100) is already applied' $T/out && [ "$(q $D -c "select to_regclass('public.hub_lock_open_items') is null")" = t ] && echo PASS || echo FAIL)" "$(err)"
rc=$(run $D supabase/deploy/hub_cutover_preflight.sql)
res "G2 the preflight refuses the wrong order too" "$([ $rc != 0 ] && grep -q 'wrong merge order' $T/out && echo PASS || echo FAIL)" "$(err)"
q $D -c "delete from supabase_migrations.schema_migrations; create table public.closed_week_carry_anchors (id int)" >/dev/null
rc=$(run $D supabase/migrations/20261101120000_hub_lock_open_items.sql)
res "G3 also refuses on 4a's objects with no version row (closed_week_carry_anchors present)" "$([ $rc != 0 ] && grep -q 'slice 4a' $T/out && echo PASS || echo FAIL)" "$(err)"
# M. the cutover paste on a build WITHOUT 20261101120000 (as live today: main + the paste) applies it in-transaction
q $D -c "drop table public.closed_week_carry_anchors" >/dev/null
mkapply $D --csv $FX --lock-open $FO --adjustments $FA
res "M1 dry run on a build without migration 20261101120000: OK + token, and the in-transaction DDL is rolled back (nothing left)" "$(grep -q 'DRY RUN OK' $T/dryout_$D && grep -q 'DRY RUN TOKEN' $T/dryout_$D && [ "$(q $D -c "select (to_regclass('public.hub_lock_open_items') is null) and (to_regclass('public.hub_paid_elsewhere') is null)")" = t ] && echo PASS || echo FAIL)" "$(grep -oE '(ERROR|NOTICE): .{0,120}' $T/dryout_$D | head -1)"
rc=$(run $D $T/apply_$D.sql)
res "M2 APPLY on that build (SQL Editor): migration applied + cutover recorded in ONE transaction; version row recorded" "$([ $rc = 0 ] && [ "$(q $D -c "select (select count(*) from hub_cutover)||'|'||(select count(*) from hub_paid_elsewhere)||'|'||public.hub_open_items_schema_ok()||'|'||(select count(*) from supabase_migrations.schema_migrations where version = '20261101120000')")" = '1|3|true|1' ] && echo PASS || echo FAIL)" "$(err)"
psql -q -d postgres -c "drop database if exists hubcut_g1" >/dev/null 2>&1

# ---------- K. rollback of migration 20261101120000_hub_lock_open_items ----------
RB=supabase/rollback/hub_lock_open_items_rollback.sql; MIG=supabase/migrations/20261101120000_hub_lock_open_items.sql
dumps(){ pg_dump -s -d $1 | grep -vE '^\\(un)?restrict ' > $2; }
D=hubcut_k1; psql -q -d postgres -c "drop database if exists $D" -c "create database $D" >/dev/null 2>&1
psql -q -v ON_ERROR_STOP=1 -d $D -f supabase/tests/local_supabase_stub.sql >/dev/null 2>&1
psql -q -d $D -c "insert into auth.users(email) values ('admin.test@example.com'),('agent.test@example.com'),('agent2.test@example.com')" >/dev/null
for f in supabase/migrations/*.sql; do [ "$f" = $MIG ] && continue; psql -X -q -v ON_ERROR_STOP=1 -d $D -f $f >/dev/null 2>&1 || echo "FAIL migration $f"; done
psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed.sql >/dev/null 2>&1
q $D -c "create schema if not exists supabase_migrations; create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text)" >/dev/null
dumps $D $T/k_before.sql
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $MIG >/dev/null 2>&1; q $D -c "insert into supabase_migrations.schema_migrations (version, name) values ('20261101120000', 'hub_lock_open_items')" >/dev/null
{ echo "set role authenticated;"; cat $RB; } > $T/k_auth.sql; rc=$(run $D $T/k_auth.sql)
res "K1 rollback refused for a non-postgres caller (SQL Editor only); nothing changed" "$([ $rc != 0 ] && grep -qE 'refused: run it in the SQL Editor|permission denied' $T/out && [ "$(q $D -c "select to_regclass('public.hub_lock_open_items') is not null")" = t ] && echo PASS || echo FAIL)" "$(err)"
rc=$(run $D $RB); dumps $D $T/k_after.sql
res "K2 rollback before any cutover: OK; pg_dump --schema-only identical to main before the migration (tables, views, functions, triggers, policies, grants); version row removed" "$([ $rc = 0 ] && grep -q 'rollback OK' $T/out && diff -q $T/k_before.sql $T/k_after.sql >/dev/null && [ "$(q $D -c "select count(*) from supabase_migrations.schema_migrations where version = '20261101120000'")" = 0 ] && echo PASS || echo FAIL)" "$(diff $T/k_before.sql $T/k_after.sql | grep -c '^[<>]') differing dump lines"
rc=$(run $D $RB)
res "K3 rollback again: refused (not applied), nothing changed" "$([ $rc != 0 ] && grep -q 'is not applied' $T/out && dumps $D $T/k_after2.sql && diff -q $T/k_before.sql $T/k_after2.sql >/dev/null && echo PASS || echo FAIL)" "$(err)"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $MIG >/dev/null 2>&1; rc1=$?; rc=$(run $D $RB); dumps $D $T/k_after3.sql
res "K4 re-apply the migration after a rollback, then roll back again: still identical (repeatable)" "$([ $rc1 = 0 ] && [ $rc = 0 ] && diff -q $T/k_before.sql $T/k_after3.sql >/dev/null && echo PASS || echo FAIL)" ""
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $MIG >/dev/null 2>&1
q $D -c "insert into hub_paid_lock (file_sha256, row_num, payday, agent_name, paid_total, system_total, locked_at, note) values (repeat('a', 64), 2, '2026-10-30', 'A Test', 1, 1, '2026-10-29 16:40 America/New_York', 'k5')" >/dev/null 2>$T/e; ins=$?
rc=$(run $D $RB)
res "K5 rollback refused when hub_paid_lock has rows (cutover started), nothing changed" "$([ $ins = 0 ] && [ $rc != 0 ] && grep -q 'cutover has been applied' $T/out && [ "$(q $D -c "select to_regclass('public.premier_recon_hub_open') is not null")" = t ] && echo PASS || echo FAIL)" "$(err) $(head -c 100 $T/e)"
rc=$(run hubcut_t8 $RB)
res "K6 rollback refused after a recorded cutover (APPLY done: hub_cutover + hub_paid_lock + open items), nothing changed" "$([ $rc != 0 ] && grep -q 'cutover has been applied' $T/out && [ "$(q hubcut_t8 -c "select (select count(*) from hub_cutover)||'|'||(select count(*) > 0 from hub_lock_open_items)||'|'||(pg_get_viewdef('premier_recon_trueup'::regclass) like '%hub_lock_open_items%')")" = '1|true|true' ] && echo PASS || echo FAIL)" "$(err) | state $(q hubcut_t8 -c "select (select count(*) from hub_cutover)||'|'||(select count(*) from hub_lock_open_items)")"
python3 - "$RB" > $T/k7 <<'PY'
import sys
rb = open(sys.argv[1]).read()
v = '\n'.join(open('supabase/migrations/20261031210100_premier_recon_views.sql').read().split('\n')[547:635])
f = '\n'.join(open('supabase/migrations/20261031210200_premier_recon_rls_events.sql').read().split('\n')[465:498])
e = '\n'.join(open('supabase/migrations/20261031210200_premier_recon_rls_events.sql').read().split('\n')[309:459])
ok = (v.startswith('create or replace view public.premier_recon_trueup') and f.startswith('create or replace function public.premier_lock_payday')
      and e.startswith('create or replace function public.premier_log_recon_events') and v in rb and f in rb and e in rb)
print('ok' if ok else 'drift')
PY
res "K7 the rollback's restored true-up / lock function / event logger are byte-copies of the slice-three migrations (drift guard)" "$([ "$(cat $T/k7)" = ok ] && echo PASS || echo FAIL)" "$(cat $T/k7)"
psql -q -d postgres -c "drop database if exists hubcut_k1" >/dev/null 2>&1

# ---------- R. the real file (optional): dry run on a fresh build + the mock board, nothing written ----------
if [ -n "$REAL" ]; then
  RO=${REAL_OPEN:-$(dirname "$REAL")/lock_open_import.csv}; RA=$(dirname "$REAL")/adjustments_import.csv; SN=$(dirname "$REAL")/snapshot.json
  # the package's ack is a REHEARSAL one (dry run only); for the LOCAL apply below, a local-test ack of the same rows
  SN0=$SN; SN=$T/real_snapshot.json
  python3 - "$SN0" "$SN" "$T/real_ack.csv" <<'PY2'
import csv, hashlib, json, sys
s = json.load(open(sys.argv[1])); m = s['must_reenter']['file']
rows = list(csv.reader(open(m)))[1:]
with open(sys.argv[3], 'w') as f:
    w = csv.writer(f, lineterminator='\n'); w.writerow(['Tab Row', 'Payday', 'Agent', 'Amount', 'Acknowledged By'])
    w.writerows([r[:4] + ['LOCAL TEST ack (not Kyle)'] for r in rows])
s['reenter_ack'] = {'file': sys.argv[3], 'sha256': hashlib.sha256(open(sys.argv[3], 'rb').read()).hexdigest(), 'status': 'local test'}
json.dump(s, open(sys.argv[2], 'w'))
PY2
  D=hubcut_real; fresh $D; psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed_slice3_mock.sql >/dev/null 2>&1
  python3 scripts/hub_cutover.py sql --csv "$REAL" --lock-open "$RO" --adjustments "$RA" --snapshot "$SN" --dry-run --out $T/real_dry.sql 2>/dev/null
  rc=$(run $D $T/real_dry.sql)
  res "R1 real files, fresh build of this tree (+ mock board), backend roster NOT loaded (as live today): dry run BLOCKED on the 10 names, no token" "$([ $rc != 0 ] && grep -q 'DRY RUN BLOCKED' $T/out && ! grep -q 'DRY RUN TOKEN' $T/out && [ "$(q $D -c 'select (select count(*) from hub_paid_lock)+(select count(*) from hub_cutover)')" = 0 ] && echo PASS || echo FAIL)" "$(grep -o 'BLOCKED.*' $T/out | cut -c1-330)"
  # local roster = the agent names in the (private) real file itself; no real names live in this public repo
  python3 -c "import csv,sys; [print(n) for n in sorted({r['Agent'] for r in csv.DictReader(open(sys.argv[1])) if r['Agent'] != 'UNKNOWN'})]" "$REAL" |
  while IFS= read -r n; do q $D -c "insert into agents (display_name, role) values (\$n\$$n\$n\$, 'agent') on conflict do nothing" >/dev/null; done
  python3 scripts/hub_cutover.py sql --csv "$REAL" --lock-open "$RO" --adjustments "$RA" --snapshot "$SN" --dry-run --out $T/real_dry.sql 2>/dev/null
  rc=$(run $D $T/real_dry.sql); tok=$(grep -oE 'DRY RUN TOKEN [0-9A-F]{10}' $T/out | awk '{print $4}')
  res "R2 same, after loading a LOCAL roster of the 10 agents: dry run OK, token issued, nothing written" "$([ $rc != 0 ] && [ -n "$tok" ] && [ "$(q $D -c 'select (select count(*) from hub_paid_lock)+(select count(*) from hub_cutover)+(select count(*) from hub_lock_open_items)')" = 0 ] && echo PASS || echo FAIL)" "$(grep -o 'DRY RUN OK.*' $T/out | cut -c1-420)"
  python3 scripts/hub_cutover.py sql --csv "$REAL" --lock-open "$RO" --adjustments "$RA" --snapshot "$SN" --confirm-hub --dry-run-token "$tok" --out $T/real_apply.sql 2>/dev/null
  rc=$(run $D $T/real_apply.sql)
  res "R3 real APPLY on the LOCAL copy: Paid Lock rows / sum / last payday + Lock Open Items as checked" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "$(q $D -c "select count(*)||' rows, '||sum(paid_total)||' paid, last '||(select last_hub_payday from hub_cutover)||', open items '||(select count(*) from hub_lock_open_items)||' ('||(select count(*) from hub_lock_open_items where paid_on is null)||' open, est '||(select sum(est_commission) from hub_lock_open_items where paid_on is null)||')' from hub_paid_lock")"
  q $D -c "select payday, count(*), sum(paid_total), sum(system_total) from hub_paid_lock group by 1 order by 1" | sed 's/^/     /'
  RP=$(python3 -c "import csv,sys; print(sorted(r['Line ID']+'|'+r['Paid On'] for r in csv.DictReader(open(sys.argv[1])) if r['Paid On'])[0])" "$RO" 2>/dev/null)
  res "R4 the open item the hub already paid (Paid On set in the file) is imported as paid by the hub, so NOT exempt" "$([ -n "$RP" ] && [ "$(q $D -c "select line_id||'|'||paid_on from hub_lock_open_items where paid_on is not null order by 1 limit 1")" = "$RP" ] && echo PASS || echo FAIL)" "$(q $D -c "select count(*)||' paid by hub, '||sum(est_commission) from hub_lock_open_items where paid_on is not null")"
  res "R6 every line-linked hub adjustment in the private file is imported as a paid-elsewhere marker (not pay); none is paid by the backend" "$([ "$(q $D -c 'select count(*) from hub_paid_elsewhere')" = "$(($(grep -c '' "$RA") - 1))" ] && [ "$(q $D -c "select count(*) from premier_recon_trueup t join premier_recon_lines l using (line_key) join hub_paid_elsewhere p on p.line_id = l.hub_line_id where (p.component = 'spiffs' and (coalesce(t.pay_claimed_spiffs, 0) <> 0 or coalesce(t.pay_missed_spiffs, 0) <> 0)) or (p.component = 'commission' and coalesce(t.pay_commission, 0) <> 0)")" = 0 ] && echo PASS || echo FAIL)" "$(q $D -c "select count(*)||' markers on '||count(distinct line_id||component)||' line components' from hub_paid_elsewhere")"
  MR=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['must_reenter']['file'])" "$SN0")
  MN=$(($(grep -c '' "$MR") - 1)); MT=$(python3 -c "import csv,sys; from decimal import Decimal; print(f\"{sum(Decimal(r['Amount']) for r in csv.DictReader(open(sys.argv[1]))):+.2f}\")" "$MR")
  res "R7 MUST RE-ENTER (B-3): the package's rows after the last hub payday are in the APPLY summary + event, and none is imported (no pay_adjustments, no marker)" "$(grep -q "MUST RE-ENTER $MN row(s), total $MT (acknowledged), not imported" $T/out && [ "$(q $D -c "select (detail->'must_reenter'->>'rows')||'|'||(detail->'must_reenter'->>'total') from event_log where event_type='payroll.hub_cutover.import'")" = "$MN|${MT#+}" ] && ! grep -qi 'insert into public.pay_adjustments' $T/real_apply.sql && [ "$(q $D -c "select count(*) from hub_paid_elsewhere where payday > (select last_hub_payday from hub_cutover)")" = 0 ] && echo PASS || echo FAIL)" "$MN rows, total $MT"
  python3 scripts/hub_cutover.py sql --csv "$REAL" --lock-open "$RO" --adjustments "$RA" --snapshot "$SN0" --confirm-hub --dry-run-token "$tok" --out $T/real_reh.sql 2>"$T/e"; rc=$?
  res "R8 the package itself (REHEARSAL ack): --confirm-hub is refused until Kyle's own ack replaces it" "$([ $rc != 0 ] && grep -q 'REHEARSAL ack' $T/e && echo PASS || echo FAIL)" ""
  rc=$(run $D $T/real_apply.sql)
  res "R5 real APPLY re-run on the local copy: no-op" "$([ $rc = 0 ] && grep -q 'already recorded from this file' $T/out && echo PASS || echo FAIL)" ""
fi
for d in hubcut_t1 hubcut_t2 hubcut_t3 hubcut_t4 hubcut_t5 hubcut_t6 hubcut_t7 hubcut_t8 hubcut_t9 hubcut_ta hubcut_tb hubcut_tc hubcut_pc hubcut_pe hubcut_cb hubcut_real; do psql -q -d postgres -c "drop database if exists $d" >/dev/null 2>&1; done
echo "hub cutover tests: $pass passed, $fail failed"
[ $fail = 0 ]
