#!/usr/bin/env bash
# C5 agent attribution (20261101090000) local suite. LOCAL stub Postgres only; never touches live. ALL DATA FAKE.
set -u
cd "$(git rev-parse --show-toplevel)"
RES=()
res(){ RES+=("$2|$1|$3"); printf '%-5s | %s | %s\n' "$2" "$1" "${3:0:240}"; }
newdb(){ psql -q -d postgres -c "drop database if exists $1" -c "create database $1" >/dev/null 2>&1
  psql -q -v ON_ERROR_STOP=1 -d $1 -f supabase/tests/local_supabase_stub.sql >/dev/null 2>&1
  psql -q -d $1 -c "insert into auth.users(email) values ('admin.test@example.com'),('agent.test@example.com')" >/dev/null; }
q(){ psql -X -At -v ON_ERROR_STOP=1 -d "$@" 2>/dev/null; }
vf(){ psql -X -q -d $1 -f $2 2>&1; }
cnt(){ grep -cE '^ +[0-9]+ \| '"$1"; }
S3=$(ls supabase/migrations/2026103119*.sql supabase/migrations/2026103120*.sql supabase/migrations/2026103121*.sql supabase/migrations/2026103122*.sql)
M=supabase/migrations/20261101090000_agent_attribution.sql
SNAPS="select md5(string_agg(x, '|' order by x)) from (
  select 'f '||p.oid::regprocedure::text||' '||md5(pg_get_functiondef(p.oid))||' '||coalesce(array_to_string(p.proacl,','),'') x from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind in ('f','p')
  union all select 'v '||c.relname||' '||md5(pg_get_viewdef(c.oid))||' '||coalesce(array_to_string(c.relacl,','),'') from pg_class c where c.relnamespace='public'::regnamespace and c.relkind='v'
  union all select 'c '||table_name||'.'||column_name||' '||data_type||' '||coalesce(column_default,'') from information_schema.columns where table_schema='public'
  union all select 'k '||conname from pg_constraint where connamespace='public'::regnamespace
  union all select 't '||tgname||' '||tgrelid::regclass::text||' '||tgfoid::regproc::text from pg_trigger where not tgisinternal
  union all select 'm '||version from supabase_migrations.schema_migrations) z"

# A. fresh build of every migration: attribution checks + the slice-3 and slice-4a suites
D=ta_fresh; newdb $D
for f in supabase/migrations/*.sql supabase/seed.sql supabase/seed_slice2.sql; do psql -q -v ON_ERROR_STOP=1 -d $D -f $f >/dev/null 2>&1 || echo "FAIL $f"; done
o=$(vf $D supabase/tests/verify_agent_attribution.sql); p=$(echo "$o" | cnt PASS); t=$(echo "$o" | cnt '(PASS|FAIL)')
res "A1 verify_agent_attribution.sql all pass (case/space match, F/S/AP/row-scan order, ABS Only = ABS spiff only, Unknown-agent High flag)" "$([ $t -gt 0 ] && [ $p = $t ] && echo PASS || echo FAIL)" "$p/$t $(echo "$o" | grep -E 'FAIL|ERROR' | head -3 | tr -s ' ')"
o=$(vf $D supabase/tests/verify_slice3.sql); p=$(echo "$o" | cnt PASS); t=$(echo "$o" | cnt '(PASS|FAIL)')
res "A2 verify_slice3.sql all pass with the new attribution (mock board: S30 AP, S31 ABS Only via S)" "$([ $t -gt 0 ] && [ $p = $t ] && echo PASS || echo FAIL)" "$p/$t $(echo "$o" | grep -E '\| FAIL|ERROR' | head -3 | tr -s ' ')"

# B. roster + alias seed script on FAKE CSVs (two-block hub tab layout; code defaults; roster)
FX="--tab supabase/tests/fixtures/agent_aliases_mock.csv --defaults supabase/tests/fixtures/agent_alias_defaults_mock.csv --roster supabase/tests/fixtures/agent_roster_mock.csv"
q $D -c "insert into agents (display_name, role) values ('Jamie Mockford','agent'),('pat  exampleton','agent')" >/dev/null
out=$(python3 scripts/agent_aliases_sql.py $FX --psql "-At -d $D" 2>&1)
ok=$( [ "$(q $D -c "select count(*) from agent_name_aliases where kind='board'")" = 7 ] \
   && [ "$(q $D -c "select count(*) from agent_name_aliases where kind='dialer'")" = 4 ] \
   && [ "$(q $D -c "select a.display_name from agent_name_aliases x join agents a on a.id=x.agent_id where x.alias='jimmy mockford'")" = 'pat  exampleton' ] \
   && [ "$(q $D -c "select string_agg(display_name, ',' order by display_name collate \"C\") from agents where display_name in ('Chris Testwell','Riley Newhire','Pat Exampleton')")" = 'Chris Testwell,Riley Newhire' ] \
   && echo "$out" | grep -q 'skipped: standard name not on the roster|board|Old Timer' && echo PASS || echo FAIL)
res "B1 roster + alias seed: missing roster agents added (existing 'pat  exampleton' kept, not duplicated); tab board+dialer rows load; the tab wins over a code default; non-roster names skipped and listed" "$ok" "$(q $D -c "select string_agg(kind||':'||alias, ', ' order by kind, alias collate \"C\") from agent_name_aliases")"
n0=$(q $D -c "select count(*) from agent_name_aliases"); a0=$(q $D -c "select count(*) from agents"); ev0=$(q $D -c "select count(*) from event_log")
python3 scripts/agent_aliases_sql.py $FX --psql "-At -d $D" >/dev/null 2>&1; rc=$?
res "B2 seed re-run = no-op (no new aliases, agents or audit events)" "$([ $rc = 0 ] && [ "$(q $D -c "select count(*) from agent_name_aliases")" = $n0 ] && [ "$(q $D -c "select count(*) from agents")" = $a0 ] && [ "$(q $D -c "select count(*) from event_log")" = $ev0 ] && echo PASS || echo FAIL)" "aliases $n0 agents $a0 events $ev0"
res "B3 code-only defaults fill only names the tab does not map" "$( [ "$(q $D -c "select string_agg(x.alias||'>'||a.display_name, ',' order by x.alias collate \"C\") from agent_name_aliases x join agents a on a.id=x.agent_id where x.note like 'hub code-only%'")" = 'Chris Testwell>Chris Testwell,Christopher Testwell>Chris Testwell,Jim>Jamie Mockford,Jim 901>Jamie Mockford' ] && echo PASS || echo FAIL)" "$(q $D -c "select string_agg(x.alias||'>'||a.display_name, ',' order by x.alias collate \"C\") from agent_name_aliases x join agents a on a.id=x.agent_id where x.note like 'hub code-only%'")"
res "B4 a CSV with a name mapped twice to different agents is refused (nothing written)" "$(printf 'x\nAlias,Standard Name,,Dialer Agent Name,Standard Name\nA B,Jamie Mockford,,,\na  b,Pat Exampleton,,,\n' > /tmp/ta_dup.csv; python3 scripts/agent_aliases_sql.py --tab /tmp/ta_dup.csv --out /tmp/ta_dup.sql >/dev/null 2>&1 && echo FAIL || echo PASS)" ""
psql -q -d postgres -c "drop database if exists $D" >/dev/null 2>&1

# P. package on a live-like DB (slices 1-3 + Q30 + mock data, recorded like live)
PK=$(mktemp -d); bash scripts/build_agent_attribution_paste.sh "$PK" >/dev/null
D=ta_pkg; newdb $D
for f in $S3 supabase/seed.sql supabase/seed_slice2.sql supabase/seed_slice3_mock.sql; do psql -q -v ON_ERROR_STOP=1 -d $D -f $f >/dev/null 2>&1 || echo "FAIL $f"; done
q $D -c "create schema if not exists supabase_migrations; create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text)" >/dev/null
q $D -c "insert into supabase_migrations.schema_migrations(version) select v from (values ('20261031190000'),('20261031190100'),('20261031190200'),('20261031190300'),('20261031200000'),('20261031200100'),('20261031200200'),('20261031210000'),('20261031210100'),('20261031210200'),('20261031210300'),('20261031210400'),('20261031220000')) x(v) on conflict do nothing" >/dev/null
S0=$(q $D -c "$SNAPS"); L0=$(q $D -c "select md5(string_agg(row(line_key, agent_name, actual_total)::text, '|' order by line_key)) from premier_recon_lines")
psql -X -q -v ON_ERROR_STOP=1 -d $D -f "$PK/agent_attribution_paste.sql" >/tmp/ta1.out 2>&1; rc=$?
L1=$(q $D -c "select md5(string_agg(row(line_key, agent_name, actual_total)::text, '|' order by line_key)) from premier_recon_lines")
res "P1 paste applies on a live-like DB; existing board rows and pay lines unchanged (attribution changes future imports only)" "$([ $rc = 0 ] && grep -q 'preflight OK' /tmp/ta1.out && [ "$L0" = "$L1" ] && [ "$(q $D -c "select count(*) from supabase_migrations.schema_migrations where version='20261101090000'")" = 1 ] && echo PASS || echo FAIL)" "rc=$rc lines ${L0:0:8}/${L1:0:8} $(grep -m1 ERROR /tmp/ta1.out)"
S1=$(q $D -c "$SNAPS")
psql -X -q -v ON_ERROR_STOP=1 -d $D -f "$PK/agent_attribution_paste.sql" >/tmp/ta2.out 2>&1; rc=$?
res "P2 paste re-run = no-op (already applied; schema unchanged)" "$([ $rc = 0 ] && grep -q 'already applied' /tmp/ta2.out && [ "$(q $D -c "$SNAPS")" = "$S1" ] && echo PASS || echo FAIL)" "rc=$rc"
o=$(vf $D supabase/tests/verify_agent_attribution.sql); p=$(echo "$o" | cnt PASS); t=$(echo "$o" | cnt '(PASS|FAIL)')
res "P3 verify_agent_attribution.sql all pass on the pasted DB" "$([ $t -gt 0 ] && [ $p = $t ] && echo PASS || echo FAIL)" "$p/$t"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f "$PK/agent_attribution_rollback.sql" >/tmp/ta3.out 2>&1; rc=$?
S2=$(q $D -c "$SNAPS")
res "P4 rollback: schema, grants, triggers, constraints and migration history identical to before the paste" "$([ $rc = 0 ] && [ "$S0" = "$S2" ] && echo PASS || echo FAIL)" "rc=$rc ${S0:0:8}/${S2:0:8} $(grep -m1 ERROR /tmp/ta3.out)"
o=$(vf $D supabase/tests/verify_slice3.sql); p=$(echo "$o" | cnt PASS); t=$(echo "$o" | cnt '(PASS|FAIL)')
res "P5 verify_slice3.sql all pass after rollback" "$([ $t -gt 0 ] && [ $p = $t ] && echo PASS || echo FAIL)" "$p/$t"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f "$PK/agent_attribution_paste.sql" >/dev/null 2>&1
q $D -c "insert into agents (display_name, role) values ('Jamie Mockford','agent')" >/dev/null
q $D -c "insert into agent_name_aliases (alias, agent_id) select 'Jim Mockford', id from agents where display_name='Jamie Mockford'" >/dev/null
q $D -c "insert into recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, hash_scheme, note) select kind, 'PKG alias row', repeat('b',64), encoding, line_ending, header, 1, true, 'sha256', 'PKG' from recon_imports where kind='sales_board' limit 1" >/dev/null
q $D -c "insert into board_submissions (import_id, row_num, raw_fields) select (select id from recon_imports where file_name='PKG alias row'), 1, array['10/31/2026 08:00:00','687000099','10/31/2026','','','Jim Mockford','99','','','','','','','','','','','','','','','','','','','','','','','','','','','','','','','','','','','']::text[]" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -d $D -f "$PK/agent_attribution_rollback.sql" >/tmp/ta4.out 2>&1; rc=$?
res "P6 rollback REFUSED (no change) once a row stores a standard name that differs from the typed one" "$([ $rc != 0 ] && grep -q 'rollback refused' /tmp/ta4.out && [ -n "$(q $D -c "select to_regclass('public.board_unknown_agents')")" ] && echo PASS || echo FAIL)" "$(grep -o 'ERROR.*' /tmp/ta4.out | head -1 | cut -c1-150)"
cp supabase/rollback/agent_attribution_rollback.sql "$PK/rb_before"; python3 scripts/build_agent_attribution_rollback.py >/dev/null
res "P7 agent_attribution_rollback.sql is current (regenerated from origin/main = committed copy)" "$(cmp -s "$PK/rb_before" supabase/rollback/agent_attribution_rollback.sql && echo PASS || echo FAIL)" ""
psql -q -d postgres -c "drop database if exists $D" >/dev/null 2>&1; rm -rf "$PK"
echo; echo "$(printf '%s\n' "${RES[@]}" | grep -c '^PASS|')/${#RES[@]} passed"
