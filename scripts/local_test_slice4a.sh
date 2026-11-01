#!/usr/bin/env bash
# Slice 4a local suite (actuals ledger + closed-week next-open-payday). LOCAL stub Postgres only; never touches live.
# Run from the repo root with PGHOST/PGPORT/PGUSER pointing at the local stub server.
set -u
cd "$(git rev-parse --show-toplevel)"
RES=()
res(){ RES+=("$2|$1|$3"); printf '%-5s | %s | %s\n' "$2" "$1" "${3:0:240}"; }
newdb(){ psql -q -d postgres -c "drop database if exists $1" -c "create database $1" >/dev/null 2>&1
  psql -q -v ON_ERROR_STOP=1 -d $1 -f supabase/tests/local_supabase_stub.sql >/dev/null 2>&1
  psql -q -d $1 -c "insert into auth.users(email) values ('admin.test@example.com'),('agent.test@example.com')" >/dev/null; }
q(){ psql -X -At -v ON_ERROR_STOP=1 -d "$@" 2>/dev/null; }
run(){ psql -X -q -v ON_ERROR_STOP=1 -d $1 -f $2 2>/dev/null; }
passes(){ run $1 $2 | grep -cE '\| PASS'; }
total(){ psql -X -q -d $1 -f $2 2>/dev/null | grep -cE '^ +[0-9]+ \| (PASS|FAIL)'; }
fails(){ run $1 $2 | grep -E '\| FAIL' | tr -s ' ' | cut -c1-140 | paste -sd';'; }
S3=$(ls supabase/migrations/2026103119*.sql supabase/migrations/2026103120*.sql supabase/migrations/2026103121*.sql supabase/migrations/2026103122*.sql 2>/dev/null)
L1=supabase/migrations/20261101100000_actuals_ledger.sql
L2=supabase/migrations/20261101100100_closed_week_next_open_payday.sql
L3=supabase/migrations/20261101100200_closed_week_autopay_on.sql
HEALTH="select format('%s|%s|%s|%s', total, unbalanced, empty_transactions, unposted) from ledger_health"
TRUE="select md5(string_agg(row(t.*)::text, '|' order by line_key)) from premier_recon_trueup t"

# U. live-like upgrade: everything live has today (slices 1-3) + mock data, then the slice-4a migrations one at a time
D=t4_up; newdb $D
for f in $S3 supabase/seed.sql supabase/seed_slice2.sql supabase/seed_slice3_mock.sql; do psql -q -v ON_ERROR_STOP=1 -d $D -f $f >/dev/null 2>&1 || echo "FAIL $f"; done
psql -q -v ON_ERROR_STOP=1 -d $D -f $L1 >/dev/null 2>/tmp/t4u1.err; rc=$?
res "U1 ledger migration applies on a loaded slice-3 DB; backfill balances with nothing unposted (total|unbalanced|empty|unposted)" "$([ $rc = 0 ] && [ "$(q $D -c "$HEALTH")" = '0|0|0|0' ] && echo PASS || echo FAIL)" "rc=$rc $(q $D -c "$HEALTH") txns=$(q $D -c 'select count(*) from ledger_transactions') $(head -c 200 /tmp/t4u1.err)"
psql -q -v ON_ERROR_STOP=1 -d $D -f $L2 >/dev/null 2>/tmp/t4u2.err; rc=$?
res "U2 closed-week migration applies; policy stays 'hold' (live behavior unchanged until 100200)" "$([ $rc = 0 ] && [ "$(q $D -c 'select closed_week_policy from recon_pay_config where id')" = hold ] && echo PASS || echo FAIL)" "rc=$rc policy=$(q $D -c 'select closed_week_policy from recon_pay_config where id') $(head -c 200 /tmp/t4u2.err)"
n=$(passes $D supabase/tests/verify_slice3.sql); T3=$(total $D supabase/tests/verify_slice3.sql)
res "U4 verify_slice3.sql all pass after 100000+100100 (policy hold)" "$([ $T3 -gt 0 ] && [ $n = $T3 ] && echo PASS || echo FAIL)" "$n/$T3 $(fails $D supabase/tests/verify_slice3.sql)"
EV0=$(q $D -c "select count(*) from event_log where event_type = 'recon.config.decision'")
psql -q -v ON_ERROR_STOP=1 -d $D -f $L3 >/dev/null 2>/tmp/t4u3.err; rc=$?
res "U5 autopay-on migration: policy next_open_payday + one recon.config.decision event" "$([ $rc = 0 ] && [ "$(q $D -c 'select closed_week_policy from recon_pay_config where id')" = next_open_payday ] && [ "$(q $D -c "select count(*) from event_log where event_type = 'recon.config.decision'")" = $((EV0+1)) ] && echo PASS || echo FAIL)" "rc=$rc $(head -c 200 /tmp/t4u3.err)"
n=$(passes $D supabase/tests/verify_slice4a.sql); T4=$(total $D supabase/tests/verify_slice4a.sql)
res "U6 verify_slice4a.sql all pass after upgrade (slice-3 scenario + LG + CW)" "$([ $T4 -gt 0 ] && [ $n = $T4 ] && echo PASS || echo FAIL)" "$n/$T4 $(fails $D supabase/tests/verify_slice4a.sql)"
TX0=$(q $D -c 'select count(*) from ledger_transactions')
ok=1; for m in $L1 $L2 $L3; do psql -q -v ON_ERROR_STOP=1 -d $D -f $m >/dev/null 2>&1 || { ok=0; echo "FAIL rerun $m"; }; done
res "U7 slice-4a migrations re-run (idempotent): no error, no new ledger rows, still balanced" "$([ $ok = 1 ] && [ "$(q $D -c 'select count(*) from ledger_transactions')" = $TX0 ] && [ "$(q $D -c "$HEALTH")" = '0|0|0|0' ] && echo PASS || echo FAIL)" "txns $TX0->$(q $D -c 'select count(*) from ledger_transactions')"

# N. behavior-neutral check, directly: same DB state with/without 100100 (both 'hold')
A=t4_a; B=t4_b; newdb $A; newdb $B
for f in $S3 supabase/seed.sql supabase/seed_slice2.sql supabase/seed_slice3_mock.sql; do psql -q -d $A -f $f >/dev/null 2>&1; psql -q -d $B -f $f >/dev/null 2>&1; done
psql -q -v ON_ERROR_STOP=1 -d $B -f $L1 >/dev/null 2>&1; psql -q -v ON_ERROR_STOP=1 -d $B -f $L2 >/dev/null 2>&1
COLS="line_key, hold_status, pay_commission, final_payable"
ha=$(q $A -c "select md5(string_agg(row($COLS)::text,'|' order by line_key)) from premier_recon_trueup"); hb=$(q $B -c "select md5(string_agg(row($COLS)::text,'|' order by line_key)) from premier_recon_trueup")
pa=$(q $A -c "select md5(string_agg(row(w.*)::text,'|' order by week_start)) from pl_weekly_walk w"); pb=$(q $B -c "select md5(string_agg(row(w.*)::text,'|' order by week_start)) from pl_weekly_walk w")
res "N1 under 'hold', 100100 changes no pay result (premier_recon_trueup key columns) and no projected P&L week" "$([ -n "$ha" ] && [ "$ha" = "$hb" ] && [ "$pa" = "$pb" ] && echo PASS || echo FAIL)" "trueup ${ha:0:8}/${hb:0:8} weekly ${pa:0:8}/${pb:0:8}"
psql -q -d postgres -c "drop database if exists $A" -c "drop database if exists $B" >/dev/null 2>&1

# F. fresh build from the repo (all migrations; autopay on by default)
D=t4_fresh; newdb $D
for f in supabase/migrations/*.sql supabase/seed.sql supabase/seed_slice2.sql; do psql -q -v ON_ERROR_STOP=1 -d $D -f $f >/dev/null 2>&1 || echo "FAIL $f"; done
n1=$(passes $D supabase/tests/verify.sql); n2=$(passes $D supabase/tests/verify_slice2_slice3era.sql); t2=$(total $D supabase/tests/verify_slice2_slice3era.sql)
n3=$(passes $D supabase/tests/verify_slice3.sql); t3=$(total $D supabase/tests/verify_slice3.sql); n4=$(passes $D supabase/tests/verify_slice4a.sql); t4=$(total $D supabase/tests/verify_slice4a.sql)
res "F1 fresh build: verify 24/24, slice2era, verify_slice3, verify_slice4a all pass" "$([ $n1 = 24 ] && [ $n2 = $t2 ] && [ $t3 -gt 0 ] && [ $n3 = $t3 ] && [ $t4 -gt 0 ] && [ $n4 = $t4 ] && echo PASS || echo FAIL)" "$n1/24, $n2/$t2, $n3/$t3, $n4/$t4 $(fails $D supabase/tests/verify_slice4a.sql)"
res "F2 fresh build ledger empty + healthy (no confirmed sources yet)" "$([ "$(q $D -c "$HEALTH")" = '0|0|0|0' ] && echo PASS || echo FAIL)" "$(q $D -c "$HEALTH")"
CH=$(git diff --name-only main -- supabase/migrations/2026103119*.sql supabase/migrations/2026103120*.sql supabase/migrations/2026103121*.sql supabase/seed*.sql supabase/rollback supabase/deploy | paste -sd,)
res "F3 slices 1-3 migrations, seeds, rollback and deploy files unchanged vs main" "$([ -z "$CH" ] && echo PASS || echo FAIL)" "${CH:-none changed}"
for d in t4_up t4_fresh; do psql -q -d postgres -c "drop database if exists $d" >/dev/null 2>&1; done
echo; echo "$(printf '%s\n' "${RES[@]}" | grep -c '^PASS|')/${#RES[@]} passed"
