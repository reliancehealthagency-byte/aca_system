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
# each verify file runs ONCE per db (cached output); passes/total/fails read the cache
VC=$(mktemp -d); trap 'rm -rf "$VC"' EXIT
vout(){ local k="$VC/$1_$(basename $2)"; [ -f "$k" ] || psql -X -q -d $1 -f $2 > "$k" 2>&1; cat "$k"; }
vreset(){ rm -f "$VC/$1_"*; }
passes(){ vout $1 $2 | grep -cE '^ +[0-9]+ \| PASS'; }
total(){ vout $1 $2 | grep -cE '^ +[0-9]+ \| (PASS|FAIL)'; }
fails(){ vout $1 $2 | grep -E '\| FAIL|ERROR' | tr -s ' ' | cut -c1-140 | paste -sd';'; }
S3=$(ls supabase/migrations/2026103119*.sql supabase/migrations/2026103120*.sql supabase/migrations/2026103121*.sql supabase/migrations/2026103122*.sql 2>/dev/null)
L1=supabase/migrations/20261101100000_actuals_ledger.sql
L2=supabase/migrations/20261101100100_closed_week_next_open_payday.sql
L3=supabase/migrations/20261101100200_closed_week_autopay_on.sql
HEALTH="select format('%s|%s|%s|%s', total::int, unbalanced, empty_transactions, unposted) from ledger_health"
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
psql -q -v ON_ERROR_STOP=1 -d $D -f $L3 >/dev/null 2>/tmp/t4u3.err; rc=$?; vreset $D
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
CH=$(git diff --name-only main -- supabase/migrations/2026103119*.sql supabase/migrations/2026103120*.sql supabase/migrations/2026103121*.sql supabase/seed*.sql supabase/rollback/slice[23]_* supabase/deploy/slice[23]_* | paste -sd,)
res "F3 slices 1-3 migrations, seeds, rollback and deploy files unchanged vs main" "$([ -z "$CH" ] && echo PASS || echo FAIL)" "${CH:-none changed}"
for d in t4_up t4_fresh; do psql -q -d postgres -c "drop database if exists $d" >/dev/null 2>&1; done
# P. SQL Editor package: preflight / depcheck / paste / re-run / rollback / autopay paste, on a live-like DB (main + mock data)
PK=$(mktemp -d); bash scripts/build_slice4a_paste.sh "$PK" >/dev/null
SNAPS="select md5(string_agg(x, '|' order by x)) from (
  select 'f '||p.oid::regprocedure::text||' '||md5(pg_get_functiondef(p.oid))||' '||coalesce(array_to_string(p.proacl,','),'') x from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind in ('f','p')
  union all select 'v '||c.relname||' '||md5(pg_get_viewdef(c.oid))||' '||coalesce(array_to_string(c.relacl,','),'')||' '||coalesce(array_to_string(c.reloptions,','),'') from pg_class c where c.relnamespace='public'::regnamespace and c.relkind='v'
  union all select 'c '||table_name||'.'||column_name||' '||data_type||' '||coalesce(column_default,'') from information_schema.columns where table_schema='public'
  union all select 't '||tgname||' '||tgrelid::regclass::text||' '||tgfoid::regproc::text from pg_trigger where not tgisinternal
  union all select 'r '||c.relname||' '||coalesce(array_to_string(c.relacl,','),'') from pg_class c where c.relnamespace='public'::regnamespace and c.relkind='r'
  union all select 'm '||version from supabase_migrations.schema_migrations) z"
D=t4_pkg; newdb $D
for f in $S3 supabase/seed.sql supabase/seed_slice2.sql supabase/seed_slice3_mock.sql; do psql -q -v ON_ERROR_STOP=1 -d $D -f $f >/dev/null 2>&1 || echo "FAIL $f"; done
q $D -c "create schema if not exists supabase_migrations; create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text)" >/dev/null
q $D -c "insert into supabase_migrations.schema_migrations(version) select v from (values ('20261031190000'),('20261031190100'),('20261031190200'),('20261031190300'),('20261031200000'),('20261031200100'),('20261031200200'),('20261031210000'),('20261031210100'),('20261031210200'),('20261031210300'),('20261031210400'),('20261031220000')) x(v) on conflict do nothing" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -d $D -c "insert into manual_entries (kind, source, entry_date, period, amount, note) values ('credit',null,'2026-10-20','day',1234.56,'PKG backfill'),('lead_spend','keystone_data','2026-10-20','day',500,'PKG backfill')" >/dev/null 2>/tmp/t4me.err || echo "FAIL backfill rows: $(head -c 200 /tmp/t4me.err)"
S0=$(q $D -c "$SNAPS")
v=$(q $D -f supabase/deploy/slice4a_preflight.sql | head -1 | cut -d'|' -f1)
res "P1 standalone preflight on a live-like DB = PASS" "$([ "$v" = PASS ] && echo PASS || echo FAIL)" "$(q $D -f supabase/deploy/slice4a_preflight.sql | head -1)"
dc=$(q $D -f supabase/deploy/slice4a_depcheck.sql)
res "P2 depcheck: no dependent view/function and no collision (only the payroll_cutoffs_guard trigger, kept by create or replace); backfill rows listed" "$(echo "$dc" | grep -E '^(dependent|collision)\|' | grep -v 'trigger calls payroll_cutoffs_guard' | grep -q . && echo FAIL || echo PASS)" "$(echo "$dc" | tr '\n' ';' | cut -c1-230)"
EV0=$(q $D -c "select count(*) from event_log")
psql -X -q -v ON_ERROR_STOP=1 -d $D -f "$PK/slice4a_paste.sql" >/tmp/t4p1.out 2>&1; rc=$?
res "P3 paste run 1: applies; policy hold; backfill posted the 2 confirmed rows, ledger balanced" "$([ $rc = 0 ] && [ "$(q $D -c 'select closed_week_policy from recon_pay_config where id')" = hold ] && [ "$(q $D -c "$HEALTH")" = '0|0|0|0' ] && [ "$(q $D -c 'select count(*) from ledger_transactions')" = 2 ] && [ "$(q $D -c "select sum(amount) from ledger_lines where account in ('rev_premier_credits','exp_lead_spend') and amount > 0")" = 500.00 ] && echo PASS || echo FAIL)" "rc=$rc txns=$(q $D -c 'select count(*) from ledger_transactions') health=$(q $D -c "$HEALTH") $(grep -o 'preflight OK.*' /tmp/t4p1.out | head -1) $(grep -m1 ERROR /tmp/t4p1.out)"
EV1=$(q $D -c "select count(*) from event_log")
psql -X -q -v ON_ERROR_STOP=1 -d $D -f "$PK/slice4a_paste.sql" >/tmp/t4p2.out 2>&1; rc=$?
res "P4 paste run 2 = no-op (already applied; no new events, no new ledger rows)" "$([ $rc = 0 ] && grep -q 'already applied' /tmp/t4p2.out && [ "$(q $D -c 'select count(*) from event_log')" = $EV1 ] && echo PASS || echo FAIL)" "rc=$rc events $EV1->$(q $D -c 'select count(*) from event_log')"
v=$(q $D -f supabase/deploy/slice4a_preflight.sql | head -1 | cut -d'|' -f1-2)
res "P5 preflight after apply = ALREADY APPLIED, autopay READY" "$(echo "$v" | grep -q '^ALREADY APPLIED|READY' && echo PASS || echo FAIL)" "$v"
vreset $D; n=$(passes $D supabase/tests/verify_slice4a.sql); t=$(total $D supabase/tests/verify_slice4a.sql)
res "P6 verify_slice4a.sql all pass on the pasted DB" "$([ $t -gt 0 ] && [ $n = $t ] && echo PASS || echo FAIL)" "$n/$t $(fails $D supabase/tests/verify_slice4a.sql)"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/rollback/slice4a_rollback.sql >/tmp/t4r1.out 2>&1; rc=$?
S1=$(q $D -c "$SNAPS")
res "P7 rollback (policy hold): schema, grants, triggers and migration history identical to before the paste" "$([ $rc = 0 ] && [ "$S0" = "$S1" ] && echo PASS || echo FAIL)" "rc=$rc ${S0:0:8}/${S1:0:8} $(grep -m1 ERROR /tmp/t4r1.out)"
vreset $D; n=$(passes $D supabase/tests/verify_slice3.sql); t=$(total $D supabase/tests/verify_slice3.sql)
res "P8 verify_slice3.sql all pass after rollback; preflight PASS again; source rows kept" "$([ $t -gt 0 ] && [ $n = $t ] && [ "$(q $D -f supabase/deploy/slice4a_preflight.sql | head -1 | cut -d'|' -f1)" = PASS ] && [ "$(q $D -c "select count(*) from manual_entries where note='PKG backfill'")" = 2 ] && echo PASS || echo FAIL)" "$n/$t"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f "$PK/slice4a_paste.sql" >/dev/null 2>&1; rc1=$?
psql -X -q -v ON_ERROR_STOP=1 -d $D -f "$PK/slice4a_autopay_on.sql" >/tmp/t4a1.out 2>&1; rc=$?
EVa=$(q $D -c "select count(*) from event_log where event_type='recon.config.decision'")
psql -X -q -v ON_ERROR_STOP=1 -d $D -f "$PK/slice4a_autopay_on.sql" >/tmp/t4a2.out 2>&1; rc2=$?
res "P9 re-apply after rollback, then autopay paste: policy next_open_payday; its re-run is a no-op (no second decision event)" "$([ $rc1 = 0 ] && [ $rc = 0 ] && [ $rc2 = 0 ] && [ "$(q $D -c 'select closed_week_policy from recon_pay_config where id')" = next_open_payday ] && grep -q 'already ON' /tmp/t4a2.out && [ "$(q $D -c "select count(*) from event_log where event_type='recon.config.decision'")" = $EVa ] && echo PASS || echo FAIL)" "rc=$rc1/$rc/$rc2 $(grep -m1 ERROR /tmp/t4a1.out)"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f supabase/rollback/slice4a_rollback.sql >/tmp/t4r2.out 2>&1; rc=$?
res "P10 rollback REFUSED while autopay is ON (no change)" "$([ $rc != 0 ] && grep -q 'rollback refused: closed-week autopay is ON' /tmp/t4r2.out && [ -n "$(q $D -c "select to_regclass('public.ledger_accounts')")" ] && echo PASS || echo FAIL)" "$(grep -o 'ERROR.*' /tmp/t4r2.out | head -1 | cut -c1-150)"
cp supabase/rollback/slice4a_rollback.sql "$PK/rb_before"; python3 scripts/build_slice4a_rollback.py >/dev/null
res "P11 slice4a_rollback.sql is current (regenerated from origin/main's slice-three files = committed copy)" "$(cmp -s "$PK/rb_before" supabase/rollback/slice4a_rollback.sql && echo PASS || echo FAIL)" ""
psql -q -d postgres -c "drop database if exists $D" >/dev/null 2>&1; rm -rf "$PK"

echo; echo "$(printf '%s\n' "${RES[@]}" | grep -c '^PASS|')/${#RES[@]} passed"
