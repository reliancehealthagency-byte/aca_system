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
# rev 4: exact identity of slice two's five P&L views (retired by slice three, recreated by its rollback)
V5="select string_agg(format('%s|%s|%s|%s|%s|%s', c.relname, md5(pg_get_viewdef(c.oid, true)), coalesce(array_to_string(c.relacl, ' '), '-'),
  pg_get_userbyid(c.relowner), coalesce(array_to_string(c.reloptions, ','), '-'), md5(coalesce(obj_description(c.oid, 'pg_class'), ''))), E'\n' order by c.relname)
  from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname in ('pl_line_items','pl_daily','pl_weekly','pl_monthly','pl_unpriced_sales')"
V5FN="select md5(string_agg(pg_get_functiondef(p.oid), E'\n' order by p.oid::regprocedure::text)) from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.oid::regprocedure::text not like '%recon%' and p.proname in
  ('touch_updated_at','commission_rates','is_admin','current_agent_id','sale_qualifies_for_addon','log_premium_mismatch')"
SCHEMA="select md5(string_agg(x, '|' order by x)) from (
  select 'rel:'||c.relname||':'||c.relkind::text as x from pg_class c where c.relnamespace='public'::regnamespace
  union all select 'col:'||table_name||'.'||column_name||':'||data_type from information_schema.columns where table_schema='public'
  union all select 'fn:'||p.oid::regprocedure::text from pg_proc p where p.pronamespace='public'::regnamespace
  union all select 'pol:'||tablename||'.'||policyname from pg_policies where schemaname='public'
  union all select 'trg:'||tgrelid::regclass||'.'||tgname from pg_trigger t join pg_class c on c.oid=t.tgrelid where not t.tgisinternal and c.relnamespace='public'::regnamespace) z"

# P. the deploy package is the one built from this tree (rev 4: package copies were stale in rev 3)
PKG=$(dirname "$PASTE"); T0=$(mktemp -d); bash scripts/build_slice3_paste.sh "$T0/paste.sql" >/dev/null
res "P0 package paste == paste rebuilt from this tree" "$(cmp -s "$T0/paste.sql" "$PASTE" && echo PASS || echo FAIL)" "$(sha256sum < "$PASTE" | cut -c1-16)"
pk=""; for f in $RB $PF supabase/deploy/slice3_retire_depcheck.sql; do cmp -s "$f" "$PKG/$(basename $f)" || pk="$pk $(basename $f)"; done
res "P1 package rollback / preflight / depcheck == repo files" "$([ -z "$pk" ] && echo PASS || echo FAIL)" "${pk:-all equal}"
dirty=$(git status --porcelain -- supabase scripts web | grep -v '^??' | head -3 | tr '\n' ' ')
mf="$PKG/slice3_package_manifest.txt"; mh=$(sed -n 's/^head //p' "$mf" 2>/dev/null)
mok=PASS; [ "$mh" = "$(git rev-parse HEAD)" ] || mok=FAIL
while read -r sha name; do [ "$(sha256sum < "$PKG/$name" | cut -d' ' -f1)" = "$sha" ] || mok=FAIL; done < <(sed -n 's/^sha256 //p' "$mf" 2>/dev/null)
res "P2 package manifest: head = HEAD, every package sha matches, tree clean" "$([ $mok = PASS ] && [ -z "$dirty" ] && echo PASS || echo FAIL)" "manifest head=${mh:0:7} HEAD=$(git rev-parse --short HEAD) dirty=${dirty:-no}"
nt=""; for f in "$PASTE" $RB "$PKG/slice3_rollback.sql"; do [ "$(grep -v '^[[:space:]]*$' "$f" | tail -1)" = "notify pgrst, 'reload schema';" ] || nt="$nt $(basename $f)"; done
res "P3 paste and rollback (repo + package) end with: notify pgrst, 'reload schema';" "$([ -z "$nt" ] && echo PASS || echo FAIL)" "${nt:-all end with it}"
rm -rf "$T0"

# G. repo hygiene (rev 4): scratch SQL ignored, migrations/seeds not; no secret in tracked files or the package
gi=""; for f in supabase/owner.sql supabase/x.sql supabase/scratch.sql owner.sql x.sql; do git check-ignore -q "$f" || gi="$gi $f"; done
for f in supabase/migrations/20261031210400_retire_slice2_pl_views.sql supabase/seed.sql supabase/seed_slice2.sql supabase/seed_slice3_mock.sql supabase/tests/verify_slice3.sql; do git check-ignore -q "$f" && gi="$gi !$f"; done
tr=$(git ls-files | grep -E '(^|/)(owner|x)\.sql$' | paste -sd' ')
res "G1 .gitignore: supabase/*.sql scratch (owner.sql, x.sql) ignored; migrations + seeds still tracked; owner.sql / x.sql not tracked" "$([ -z "$gi$tr" ] && echo PASS || echo FAIL)" "${gi:-ok} ${tr:+tracked:$tr}"
hits=0; for sf in /workspace/secrets/payroll_owner_user_id.txt /workspace/secrets/recon_hash_salt.txt; do
  [ -s "$sf" ] || continue; v=$(tr -d '[:space:]' < "$sf")
  n=$(git ls-files -z | xargs -0 grep -lF -- "$v" 2>/dev/null | wc -l); n2=$(grep -rlF -- "$v" "$(dirname "$PASTE")" --include='slice3*' 2>/dev/null | wc -l)
  hits=$((hits + n + n2)); done
jw=$(git ls-files -z | xargs -0 grep -lE 'eyJ[A-Za-z0-9_-]{20,}\.eyJ[A-Za-z0-9_-]{20,}|sb_secret_[A-Za-z0-9]{10,}|SUPABASE_SERVICE_ROLE_KEY *= *[^ <]{20,}' 2>/dev/null | paste -sd' ')
res "G2 secrets scan: owner id + salt in no tracked file or package file; no JWT / service key in tracked files (values not printed)" "$([ $hits = 0 ] && [ -z "$jw" ] && echo PASS || echo FAIL)" "secret hits=$hits jwt/key files=${jw:-none}"

# A. live-like upgrade (slice one + slice-one seed + slice-two paste, as live is today)
D=t3_live; liveish $D
res "A1 standalone preflight before apply" "$( [ "$(q $D -f $PF | head -1 | cut -d'|' -f1)" = PASS ] && echo PASS || echo FAIL)" "$(q $D -f $PF | head -1)"
BEFORE=$(q $D -c "$SNAP"); SCH0=$(q $D -c "$SCHEMA"); V50=$(q $D -c "$V5"); V5FN0=$(q $D -c "$V5FN"); DEP0=$(q $D -f supabase/deploy/slice3_retire_depcheck.sql) EV0=$(q $D -c "select count(*) from event_log"); EVMAX0=$(q $D -c "select coalesce(max(id),0) from event_log")
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/tmp/s3a2.out 2>&1; rc=$?
EV1=$(q $D -c "select count(*) from event_log")
res "A2 paste run 1" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "exit=$rc event_log $EV0->$EV1 $(grep -o 'preflight OK.*' /tmp/s3a2.out | head -1)"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/tmp/s3a3.out 2>&1; rc=$?
EV2=$(q $D -c "select count(*) from event_log")
res "A3 paste run 2 (no-op)" "$([ $rc = 0 ] && [ "$EV1" = "$EV2" ] && grep -q 'already applied' /tmp/s3a3.out && echo PASS || echo FAIL)" "exit=$rc event_log $EV1->$EV2"
res "A4 standalone preflight after apply" "$( [ "$(q $D -f $PF | head -1 | cut -d'|' -f1)" = 'ALREADY APPLIED' ] && echo PASS || echo FAIL)" "$(q $D -f $PF | head -1 | cut -d'|' -f1)"
res "A5 schema_migrations has 4 + 3 + 5 = 12 versions" "$([ "$(q $D -c 'select count(*) from supabase_migrations.schema_migrations')" = 12 ] && echo PASS || echo FAIL)" "$(q $D -c "select string_agg(version, ',' order by version) from supabase_migrations.schema_migrations where version like '2026103121%'")"
AFTER=$(q $D -c "$SNAP")
res "A6 existing data unchanged by the paste (sales/agents/contacts/applications/call_metrics/commission_config/expenses/categories/revenue_adjustments)" "$([ "$BEFORE" = "$AFTER" ] && echo PASS || echo FAIL)" "$BEFORE"
res "A7 paste loads no Premier/board/mock data (config rows only)" "$([ "$(q $D -c 'select (select count(*) from recon_imports)+(select count(*) from premier_member_products)+(select count(*) from board_submissions)+(select count(*) from pay_adjustments)+(select count(*) from payroll_cutoffs)')" = 0 ] && echo PASS || echo FAIL)" "config: $(q $D -c "select (select count(*) from recon_pay_config)||' pay config, '||(select count(*) from agent_pay_rules)||' agent rules, '||(select count(*) from premier_addon_map)||' add-on map rows ('||(select count(*) from premier_addon_map where status='proposed')||' proposed)'")"
n=$(passes $D supabase/tests/verify.sql); res "A8 verify.sql (slice one) after upgrade" "$([ $n = 24 ] && echo PASS || echo FAIL)" "$n/24 $(fails $D supabase/tests/verify.sql)"
res "A0b retire dependency check before apply: only the five views' own grants / internal rows" "$(echo "$DEP0" | grep -qvE '^(grant|internal)\|' && echo FAIL || echo PASS)" "$(echo "$DEP0" | cut -d'|' -f1 | sort | uniq -c | tr -s ' ' | paste -sd',')"
T2=29; n=$(passes $D supabase/tests/verify_slice2_slice3era.sql); T2X=$(total $D supabase/tests/verify_slice2_slice3era.sql)
res "A9 verify_slice2_slice3era.sql after upgrade (slice two's 29 minus the 10 retired-view checks)" "$([ $T2X = 19 ] && [ $n = $T2X ] && echo PASS || echo FAIL)" "$n/$T2X $(fails $D supabase/tests/verify_slice2_slice3era.sql)"
res "A9b original verify_slice2.sql can no longer run after upgrade (it reads the retired views)" "$([ "$(passes $D supabase/tests/verify_slice2.sql)" = 0 ] && echo PASS || echo FAIL)" "passes=$(passes $D supabase/tests/verify_slice2.sql)"
res "A13 the five slice-two P&L views are gone after upgrade" "$([ -z "$(q $D -c "$V5")" ] && echo PASS || echo FAIL)" ""
n=$(passes $D supabase/tests/verify_slice3.sql); T3=$(total $D supabase/tests/verify_slice3.sql)
res "A10 verify_slice3.sql (all scenarios + structure) after upgrade" "$([ $T3 -gt 0 ] && [ $n = $T3 ] && echo PASS || echo FAIL)" "$n/$T3 $(fails $D supabase/tests/verify_slice3.sql)"
res "A11 verify_slice3 left nothing behind (rolled back)" "$([ "$(q $D -c 'select count(*) from recon_imports')" = 0 ] && [ "$(q $D -c 'select count(*) from event_log')" = "$EV2" ] && echo PASS || echo FAIL)" "event_log=$(q $D -c 'select count(*) from event_log')"
EVD=$(q $D -c "select string_agg(table_name||' '||action||' '||c, ', ') from (select table_name, action, count(*) c from event_log where id > $EVMAX0 group by 1,2 order by 1,2) x")
res "A12 event_log delta from paste (config-row audit only)" "$([ $((EV1-EV0)) -gt 0 ] && echo PASS || echo FAIL)" "+$((EV1-EV0)): $EVD"

# B. rollback: guards, then exact revert
for g in "update sales set lead_source='web' where ctid=(select ctid from sales limit 1)|lead_source" \
         "insert into pay_adjustments(agent_name,payday,kind,amount,reason,entered_by) values ('Test Agent','2026-11-06','manual',5,'real adj','Kyle')|non-mock pay adjustment" \
         "insert into recon_imports(kind,file_name,file_sha256,encoding,line_ending,header,row_count,is_mock,hash_scheme) select kind,'real.csv',repeat('b',64),encoding,line_ending,header,0,false,'hmac-sha256' from (values ('sales_board','utf-8','CRLF',(select header from (select array['Timestamp','Member ID','Date Booked','x','Active Date','Agent','Premium','Customer Name','Customer Email','Customer Phone','x','x','Post Date','Email','x','ABS Addon?','x','Deal Type','Agent','x','FFM','Client Name','x','x','Date Booked','x','x','x','Income','x','x','Premier/Neo Addon?','Premier/Neo Member ID','Premier/Neo Premium','ABS Addon?','ABS Member ID','ABS Premium','x','Phone Number','x','Increased Comm/Spiff Product?','Agent']::text[] header) h))) v(kind,encoding,line_ending,header)|non-mock import" \
         "insert into hub_paid_lock(file_sha256,row_num,payday,agent_name,paid_total,locked_at) values (repeat('c',64),1,'2026-10-30','Test Agent',10,'2026-10-29 14:07'); insert into hub_cutover(file_name,file_sha256,note) values ('hub.csv',repeat('c',64),'hub')|hub cutover recorded (clock started)" \
         "update recon_pay_config set adjustment_server_path='off' where id|changed recon_pay_config (break-glass setting)" \
         "insert into agent_name_aliases(alias,agent_id) select 'Alias Test',id from agents limit 1|agent alias rows" \
         "update recon_pay_config set payroll_owner_user_id=gen_random_uuid() where id|payroll owner set" \
         "insert into payroll_cutoffs(payday,cutoff_at,source,note) values ('2026-11-06','2026-11-05 14:10 America/New_York','submit','Kyle submit')|real payroll cutoff" \
         "update premier_addon_map set active=false where ctid=(select ctid from premier_addon_map order by pattern limit 1)|edited add-on map" \
         "update agent_pay_rules set no_spiff=false where agent_name='Loreidy Martinez'|edited agent_pay_rules" \
         "insert into manual_entries(kind,entry_date,period,amount) values ('credit','2026-10-30','day',5)|a manual entry" \
         "insert into overhead_entries(month,source_name,amount) values ('2026-10-01','Rent',5)|an overhead entry" \
         "update manual_entry_sources set label='Ringba (renamed)' where code='ringba'|edited manual_entry_sources"; do
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
res "B9 rollback restores the five slice-two P&L views EXACTLY (view definition, grants, owner, options, comment) and the kept functions' definitions" "$([ -n "$V50" ] && [ "$(q $D -c "$V5")" = "$V50" ] && [ "$(q $D -c "$V5FN")" = "$V5FN0" ] && echo PASS || echo FAIL)" "$(q $D -c "$V5" | cut -d'|' -f1,2 | paste -sd' ')"
res "B5 schema_migrations back to 7" "$([ "$(q $D -c 'select count(*) from supabase_migrations.schema_migrations')" = 7 ] && echo PASS || echo FAIL)" ""
n1=$(passes $D supabase/tests/verify.sql); n2=$(passes $D supabase/tests/verify_slice2.sql)
res "B6 verify.sql + the ORIGINAL verify_slice2.sql after rollback (retired views back)" "$([ $n1 = 24 ] && [ $n2 = $T2 ] && echo PASS || echo FAIL)" "$n1/24, $n2/$T2"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $RB >/dev/null 2>&1; rc=$?; res "B7 rollback re-run is a no-op" "$([ $rc = 0 ] && echo PASS || echo FAIL)" "exit=$rc"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/dev/null 2>&1; rc=$?
n=$(passes $D supabase/tests/verify_slice3.sql); res "B8 re-apply after rollback" "$([ $rc = 0 ] && [ $T3 -gt 0 ] && [ $n = $T3 ] && echo PASS || echo FAIL)" "exit=$rc verify_slice3 $n/$T3"

# C. preflight aborts change nothing
abort_case(){ # $1 name, $2 db, $3 mutate SQL
  local D=$2; [ -n "$3" ] && q $D -c "$3" >/dev/null
  local ea=$(q $D -c "select count(*) from event_log") ha=$(q $D -c "$SCHEMA"); [ -n "$ha" ] || echo "SCHEMA query failed"
  psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/tmp/pf.out 2>&1; local rc=$?
  local eb=$(q $D -c "select count(*) from event_log") hb=$(q $D -c "$SCHEMA") pf=$(q $D -f $PF | head -1 | cut -d'|' -f1)
  res "$1" "$([ $rc != 0 ] && grep -q 'preflight failed' /tmp/pf.out && [ "$ea" = "$eb" ] && [ "$ha" = "$hb" ] && [ "$pf" = FAIL ] && echo PASS || echo FAIL)" "standalone=$pf; $(grep -o 'ERROR: .*' /tmp/pf.out | head -1 | cut -c1-120)"; }
D=t3_mut; liveish $D
abort_case "C1 paste aborts when commission_config is not 0.38/0.05" $D "update commission_config set addon_bonus_rate=0.06 where id"
q $D -c "update commission_config set addon_bonus_rate=0.05 where id" >/dev/null
abort_case "C2 paste aborts when sales already has a slice-three column" $D "alter table sales add column lead_source text"
q $D -c "alter table sales drop column lead_source" >/dev/null
res "C3 after undoing, standalone preflight is PASS again" "$( [ "$(q $D -f $PF | head -1 | cut -d'|' -f1)" = PASS ] && echo PASS || echo FAIL)" "$(q $D -f $PF | head -1 | cut -d'|' -f1)"
D=t3_noslice2; liveish $D noslice2
abort_case "C4 paste aborts when slice two is not applied" $D ""

# E. import script: header contract, salted hashes, output handling, hub cutover (local files only; mock data)
M=/workspace/artifacts/premier_mock; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PH=$M/MOCK_PHS_Member_Products_2026-10-31.csv; BD=$M/MOCK_Sales_Board_Form_Responses_1_slice_2026-10-25_to_10-31.csv
SALT="$T/salt.txt"; ( umask 077; head -c 48 /dev/urandom | base64 > "$SALT" )   # throwaway test salt (never the real one)
python3 - "$PH" "$T/no_lp.csv" <<'PY'
import csv, sys
rows = list(csv.reader(open(sys.argv[1], encoding='cp1252', newline='')))
i = rows[0].index('Last Payment')
w = csv.writer(open(sys.argv[2], 'w', encoding='cp1252', newline=''), lineterminator='\r\n')
w.writerows([r[:i] + r[i + 1:] for r in rows])
PY
python3 scripts/csv_to_recon_sql.py --mock --premier "$T/no_lp.csv" >/dev/null 2>"$T/e1"; rc=$?
res "E1 script refuses a Premier file missing 'Last Payment' (named-column check, not count-only)" "$([ $rc != 0 ] && grep -q "required Premier column(s) missing: Last Payment" "$T/e1" && echo PASS || echo FAIL)" "$(cut -c1-120 "$T/e1")"
python3 - "$BD" "$T/moved.csv" <<'PY'
import csv, sys
rows = list(csv.reader(open(sys.argv[1], encoding='utf-8', newline='')))
for r in rows: r[40], r[39] = r[39], r[40]
csv.writer(open(sys.argv[2], 'w', encoding='utf-8', newline=''), lineterminator='\r\n').writerows(rows)
PY
python3 scripts/csv_to_recon_sql.py --mock --board "$T/moved.csv" >/dev/null 2>"$T/e2"; rc=$?
res "E2 script refuses a board file whose AO column moved" "$([ $rc != 0 ] && grep -q "required board column(s) missing or moved" "$T/e2" && echo PASS || echo FAIL)" "$(cut -c1-120 "$T/e2")"
python3 - "$BD" "$T/41.csv" <<'PY'
import csv, sys
rows = list(csv.reader(open(sys.argv[1], encoding='utf-8', newline='')))
csv.writer(open(sys.argv[2], 'w', encoding='utf-8', newline=''), lineterminator='\r\n').writerows([r[:41] for r in rows])
PY
python3 scripts/csv_to_recon_sql.py --mock --board "$T/41.csv" >/dev/null 2>"$T/e3"; rc=$?
res "E3 script refuses a stale 41-column board layout (board_live.csv shape)" "$([ $rc != 0 ] && grep -q "expected the live Sales Board columns" "$T/e3" && echo PASS || echo FAIL)" "$(cut -c1-120 "$T/e3")"
python3 scripts/csv_to_recon_sql.py --premier "$PH" --salt-file "$SALT" >/dev/null 2>"$T/e4"; rc=$?
res "E4 real (non-mock) import refuses stdout (must use --psql or --out)" "$([ $rc != 0 ] && grep -q "must use --psql" "$T/e4" && echo PASS || echo FAIL)" "$(cut -c1-120 "$T/e4")"
python3 scripts/csv_to_recon_sql.py --premier "$PH" --board "$BD" --salt-file "$SALT" --out "$T/real.sql" 2>"$T/e5"; rc=$?
res "E5 --out writes a 0600 file and prints the delete reminder" "$([ $rc = 0 ] && [ "$(stat -c %a "$T/real.sql")" = 600 ] && grep -q "shred -u" "$T/e5" && echo PASS || echo FAIL)" "mode=$(stat -c %a "$T/real.sql" 2>/dev/null)"
E6=$(python3 - "$PH" "$T/real.sql" "$SALT" <<'PY'
import csv, sys, re, hashlib, hmac
p = list(csv.DictReader(open(sys.argv[1], encoding='cp1252', newline='')))
sql = open(sys.argv[2]).read(); salt = open(sys.argv[3], 'rb').read().strip()
plain = salted = 0
for r in p:
    d = re.sub(r'\D', '', r['Phone 1'] or '')[-10:]
    e = (r['Email'] or '').strip().lower()
    for v in [x for x in (d if len(d) == 10 else '', e if '@' in e else '') if x]:
        plain += hashlib.sha256(v.encode()).hexdigest() in sql
        salted += hmac.new(salt, v.encode(), hashlib.sha256).hexdigest() in sql
bad = [c for c in ('Gender', 'Ethnicity', 'Height', 'Weight', 'Disability', 'Company Name') if f'"{c}"' in sql or f"'{c}'" in sql]
print(f"plain={plain} salted={salted} scheme={'hmac-sha256' in sql} excluded_headers={bad}")
PY
)
res "E6 real-mode SQL: phone/email hashes are salted HMACs only (no plain sha256), excluded columns absent" "$(echo "$E6" | grep -qE '^plain=0 salted=[1-9][0-9]* scheme=True excluded_headers=\[\]$' && echo PASS || echo FAIL)" "$E6"
python3 scripts/csv_to_recon_sql.py --premier "$PH" --salt-file "$T/missing_salt" --out "$T/x.sql" >/dev/null 2>"$T/e8"; rc=$?
res "E8 real mode with no salt file is refused (unsalted hashes are reversible)" "$([ $rc != 0 ] && grep -q "need the hash salt file" "$T/e8" && [ ! -e "$T/x.sql" ] && echo PASS || echo FAIL)" "$(cut -c1-120 "$T/e8")"
cp "$SALT" "$T/open_salt"; chmod 644 "$T/open_salt"
python3 scripts/csv_to_recon_sql.py --premier "$PH" --salt-file "$T/open_salt" --out "$T/x.sql" >/dev/null 2>"$T/e9"; rc=$?
res "E9 a salt file readable by others (0644) is refused" "$([ $rc != 0 ] && grep -q "must be mode 0600" "$T/e9" && echo PASS || echo FAIL)" "$(cut -c1-120 "$T/e9")"
printf 'Agent,Payday,Amount,Reason/Note,Member ID,Entered By,Date Entered\r\nTest Agent,11/13/2026,"5); delete from public.agents; --",x,,Kyle,11/01/2026\r\n' > "$T/madj_bad.csv"
python3 scripts/csv_to_recon_sql.py --mock --madj "$T/madj_bad.csv" > "$T/madj_bad.sql" 2>"$T/e10"; rc=$?
printf 'Agent,Payday,Amount,Reason/Note,Member ID,Entered By,Date Entered\r\nTest Agent,11/13/2026,"($1,234.50)",x,,Kyle,11/01/2026\r\n' > "$T/madj_ok.csv"
python3 scripts/csv_to_recon_sql.py --mock --madj "$T/madj_ok.csv" > "$T/madj_ok.sql" 2>/dev/null; rc2=$?
res "E10 madj Amount is validated: SQL injection text refused; (\$1,234.50) becomes the literal -1234.50" "$([ $rc != 0 ] && grep -q "is not a money value" "$T/e10" && ! grep -q "delete from" "$T/madj_bad.sql" && [ $rc2 = 0 ] && grep -q -- "-1234.50" "$T/madj_ok.sql" && echo PASS || echo FAIL)" "$(cut -c1-100 "$T/e10")"
printf 'Pay Friday,Agent,Paid Total,System Total,Locked At (ET),Note\r\n10/23/2026,Test Agent,100.00,100.00,10/22/2026 14:46,mock\r\n10/30/2026,Test Agent,120.50,118.00,10/29/2026 14:07,mock\r\n' > "$T/hub.csv"
printf 'Pay Friday,Agent,Paid Total,System Total,Locked At (ET),Note\r\n10/29/2026,Test Agent,100.00,100.00,,mock\r\n' > "$T/hub_bad.csv"
python3 scripts/csv_to_recon_sql.py --mock --hub "$T/hub_bad.csv" >/dev/null 2>"$T/e11"; rc=$?
res "E11 hub file with a non-Friday Pay Friday is refused" "$([ $rc != 0 ] && grep -q "is not a Friday" "$T/e11" && echo PASS || echo FAIL)" "$(cut -c1-100 "$T/e11")"
D=t3_imp; liveish $D; psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/dev/null 2>&1
touch "$T/marker"; GS0=$(git status --porcelain | md5sum)
python3 scripts/csv_to_recon_sql.py --premier "$PH" --board "$BD" --hub "$T/hub.csv" --salt-file "$SALT" --psql "-d $D" >/dev/null 2>"$T/e14"; rc=$?
res "E14 --hub without --confirm-hub is a dry run: prints the planned paydays + last_hub_payday, writes nothing" "$([ $rc != 0 ] && grep -q 'paydays 2026-10-23, 2026-10-30; last_hub_payday = 2026-10-30' "$T/e14" && grep -q 'DRY RUN' "$T/e14" && [ "$(q $D -c 'select (select count(*) from recon_imports)+(select count(*) from hub_paid_lock)')" = 0 ] && echo PASS || echo FAIL)" "$(grep -o 'hub cutover plan.*' "$T/e14" | cut -c1-110)"
python3 scripts/csv_to_recon_sql.py --premier "$PH" --board "$BD" --hub "$T/hub.csv" --confirm-hub --salt-file "$SALT" --psql "-d $D" >/dev/null 2>&1; rc=$?
NEWF=$( (find "$T" /tmp /workspace/aca_system -maxdepth 2 -newer "$T/marker" -type f \( -name '*.sql' -o -name '*recon*' \) 2>/dev/null) | grep -v "^$T/marker$" | wc -l)
res "E7 --psql streams a real-mode import (Premier + board + hub cutover) straight into the DB: ops rows land, export finalized, clock started" "$([ $rc = 0 ] && [ "$(q $D -c 'select count(*) from premier_member_products')" = 66 ] && [ "$(q $D -c 'select max(cardinality(raw_fields)) from premier_member_products')" = 68 ] && [ "$(q $D -c "select count(*) from recon_imports where finalized_at is not null and hash_scheme='hmac-sha256'")" = 1 ] && [ "$(q $D -c 'select last_hub_payday from hub_cutover')" = 2026-10-30 ] && echo PASS || echo FAIL)" "exit=$rc rows=$(q $D -c 'select count(*) from premier_member_products') hub=$(q $D -c 'select last_hub_payday from hub_cutover')"
res "E12 no generated SQL lingers: the --psql run wrote no file (box /tmp, repo, temp dir) and the repo is unchanged" "$([ "$NEWF" = 0 ] && [ "$(git status --porcelain | md5sum)" = "$GS0" ] && echo PASS || echo FAIL)" "new files=$NEWF"
python3 scripts/csv_to_recon_sql.py --hub "$T/hub.csv" --confirm-hub --salt-file "$SALT" --psql "-d $D" >/dev/null 2>"$T/e13"; rc=$?
res "E13 importing the hub file a second time is refused (one-time clock start)" "$([ $rc != 0 ] && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 2 ] && echo PASS || echo FAIL)" "$(grep -o 'ERROR: .*' "$T/e13" | head -1 | cut -c1-110)"
# rev 4: payroll_owner_sql.sh sets the owner from the secrets-style file without ever printing it
OW="$T/owner.txt"; ( umask 077; python3 -c 'import uuid; print(uuid.uuid4())' > "$OW" ); OU=$(cat "$OW")
q $D -c "insert into auth.users(id,email) values ('$OU','owner.test@example.com')" >/dev/null
bash scripts/payroll_owner_sql.sh >"$T/o0.out" 2>&1; rc0=$?
OWNER_FILE="$OW" bash scripts/payroll_owner_sql.sh --psql "-d $D" >"$T/o1.out" 2>&1; rc1=$?
OWNER_FILE="$OW" bash scripts/payroll_owner_sql.sh --out "$PWD/owner_test.sql" >"$T/o2.out" 2>&1; rc2=$?
res "E18 payroll_owner_sql.sh streams the owner id into psql (owner set) and never prints it; no-arg and in-repo --out are refused" "$([ $rc0 != 0 ] && [ $rc1 = 0 ] && [ $rc2 != 0 ] && [ ! -e owner_test.sql ] && [ "$(q $D -c 'select payroll_owner_user_id from recon_pay_config')" = "$OU" ] && ! grep -qF "$OU" "$T/o0.out" "$T/o1.out" "$T/o2.out" && echo PASS || echo FAIL)" "rc=$rc0/$rc1/$rc2 $(head -c 90 "$T/o1.out")"
psql -q -d postgres -c "drop database if exists t3_imp" >/dev/null 2>&1
python3 scripts/csv_to_recon_sql.py --premier "$PH" --salt-file "$SALT" --out "$PWD/supabase/import_test.sql" >/dev/null 2>"$T/e16"; rc=$?
res "E16 --out inside the git working tree is refused (and generated import SQL is gitignored)" "$([ $rc != 0 ] && grep -q 'inside the git working tree' "$T/e16" && [ ! -e supabase/import_test.sql ] && git check-ignore -q x_import.sql && git check-ignore -q generated.sql && echo PASS || echo FAIL)" "$(cut -c1-110 "$T/e16")"
printf 'Pay Friday,Agent,Paid Total,System Total,Locked At (ET),Note\r\n10/30/2026,Test Agent,120.50,118.00,10/29/2026 14:07,mock\r\n11/06/2026,James Carangelo,0,,,mock\r\n' > "$T/hub_blank.csv"
printf 'Pay Friday,Agent,Paid Total,System Total,Locked At (ET),Note\r\n10/30/2026,Test Agent,120.50,118.00,10/29/2026 14:07,mock\r\n10/29/2027,Test Agent,10,10,10/29/2026 14:07,typo\r\n' > "$T/hub_future.csv"
python3 scripts/csv_to_recon_sql.py --mock --hub "$T/hub_blank.csv" --confirm-hub >/dev/null 2>"$T/e15a"; ra=$?
python3 scripts/csv_to_recon_sql.py --mock --hub "$T/hub_future.csv" --confirm-hub >/dev/null 2>"$T/e15b"; rb=$?
res "E15 script refuses hub rows with a blank Locked At (repro 1) or a future Pay Friday (repro 2: 10/29/2027)" "$([ $ra != 0 ] && grep -q 'Locked At (ET) is blank' "$T/e15a" && [ $rb != 0 ] && grep -q 'is after today' "$T/e15b" && echo PASS || echo FAIL)" "$(cut -c1-80 "$T/e15a") / $(cut -c1-80 "$T/e15b")"
D=t3_mock; liveish $D; psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/dev/null 2>&1
python3 scripts/csv_to_recon_sql.py --mock --premier "$PH" --hub "$T/hub.csv" --confirm-hub --psql "-d $D" >/dev/null 2>&1; r1=$?
python3 scripts/csv_to_recon_sql.py --mock --board "$BD" --hub "$T/hub.csv" --confirm-hub --psql "-d $D" >/dev/null 2>&1; r2=$?
res "E17 a refused --mock import leaves no orphan rows (one transaction): the board import rolled back with the refused 2nd hub file" "$([ $r1 = 0 ] && [ $r2 != 0 ] && [ "$(q $D -c "select count(*) from recon_imports where kind='sales_board'")" = 0 ] && [ "$(q $D -c 'select count(*) from hub_paid_lock')" = 2 ] && echo PASS || echo FAIL)" "run1=$r1 run2=$r2 board_imports=$(q $D -c "select count(*) from recon_imports where kind='sales_board'")"
psql -q -d postgres -c "drop database if exists t3_mock" >/dev/null 2>&1

# F. slices one and two untouched in the repo (only the slice-two paste builder glob changed, output byte-identical)
CH=$(git diff --name-only main -- supabase/migrations/2026103119*.sql supabase/migrations/2026103120*.sql supabase/seed.sql supabase/seed_slice2.sql supabase/tests/verify.sql supabase/tests/verify_slice2.sql supabase/rollback/slice2_rollback.sql supabase/deploy/slice2_* | paste -sd,)
res "F1 slice-one/two migrations, seeds, verify files and rollback unchanged vs main" "$([ -z "$CH" ] && echo PASS || echo FAIL)" "${CH:-none changed}"
bash scripts/build_slice2_paste.sh "$T/s2.sql" >/dev/null
res "F2 slice-two paste rebuilt from this branch is byte-identical to the applied one" "$([ "$(sha256sum < "$T/s2.sql")" = "$(sha256sum < $PASTE2)" ] && echo PASS || echo FAIL)" "$(sha256sum < "$T/s2.sql" | cut -c1-16)"

# Q. Q30 (Kyle direct 10/31 9:04 PM): the live SQL Editor apply + revert files on a live-like DB after the slice-three paste
D=t3_q30; liveish $D; psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/dev/null 2>&1 || echo "FAIL paste"
Q30F=$(mktemp); Q30R=$(mktemp); bash scripts/build_q30_sql.sh "$Q30F" >/dev/null; bash scripts/build_q30_revert_sql.sh "$Q30R" >/dev/null
Q30STATE="select concat_ws('|', md5((to_jsonb(c) - 'note' - 'updated_at')::text), (select column_default from information_schema.columns where table_schema='public' and table_name='recon_pay_config' and column_name='one_time_fee_policy'),
  (select count(*) from supabase_migrations.schema_migrations where version = '20261031220000')) from public.recon_pay_config c where c.id"
PRE=$(q $D -c "$Q30STATE"); SCHQ0=$(q $D -c "$SCHEMA")
r0=$(psql -X -At -v ON_ERROR_STOP=1 -d $D -f "$Q30R" 2>&1 | grep -o 'not include: nothing changed' | head -1)
res "Q0 Q30 revert refuses before the apply (value pending_kyle), changes nothing" "$([ -n "$r0" ] && [ "$(q $D -c "$Q30STATE")" = "$PRE" ] && echo PASS || echo FAIL)" "${r0:-no refusal}"
r1=$(psql -X -At -v ON_ERROR_STOP=1 -d $D -f "$Q30F" 2>&1 | tail -1); r2=$(psql -X -At -v ON_ERROR_STOP=1 -d $D -f "$Q30F" 2>&1 | tail -1)
res "Q1 Q30 file: pending_kyle -> include, default include, version recorded, one decision event; re-run is a no-op" "$([ "$r1" = 'include|t|t|1' ] && [ "$r2" = 'include|t|t|1' ] && echo PASS || echo FAIL)" "run1=$r1 run2=$r2"
ev=$(q $D -c "select concat_ws('/', count(*) filter (where event_type = 'row.update' and table_name = 'recon_pay_config' and after->>'one_time_fee_policy' = 'include'), count(*) filter (where event_type = 'recon.config.decision' and detail->>'reason' = 'Kyle direct 10/31 9:04 PM Q30' and detail->>'path' = 'break-glass:postgres')) from event_log")
res "Q2 Q30 audited: row.update on recon_pay_config + recon.config.decision (reason, break-glass:postgres)" "$([ "$ev" = 1/1 ] && echo PASS || echo FAIL)" "$ev"
n=$(passes $D supabase/tests/verify_slice3.sql); res "Q3 verify_slice3 after the Q30 file" "$([ $T3 -gt 0 ] && [ $n = $T3 ] && echo PASS || echo FAIL)" "$n/$T3 $(fails $D supabase/tests/verify_slice3.sql)"
q $D -c "update public.recon_pay_config set one_time_fee_policy = 'exclude' where id" >/dev/null
r3=$(psql -X -At -v ON_ERROR_STOP=1 -d $D -f "$Q30F" 2>&1 | grep -o 'not pending_kyle: not changed' | head -1); r3v=$(q $D -c "select one_time_fee_policy from recon_pay_config")
r3r=$(psql -X -At -v ON_ERROR_STOP=1 -d $D -f "$Q30R" 2>&1 | grep -o 'not include: nothing changed' | head -1); r3rv=$(q $D -c "select one_time_fee_policy from recon_pay_config")
res "Q4 apply and revert both refuse (change nothing) when the owner already chose another value (exclude)" "$([ -n "$r3" ] && [ -n "$r3r" ] && [ "$r3v" = exclude ] && [ "$r3rv" = exclude ] && echo PASS || echo FAIL)" "apply: ${r3:-no refusal}; revert: ${r3rv:+$r3r} value=$r3rv"
q $D -c "update public.recon_pay_config set one_time_fee_policy = 'include' where id" >/dev/null
rv=$(psql -X -At -v ON_ERROR_STOP=1 -d $D -f "$Q30R" 2>&1 | tail -1); POST=$(q $D -c "$Q30STATE")
rve=$(q $D -c "select count(*) from event_log where event_type = 'recon.config.decision' and detail->>'to' = 'pending_kyle' and detail->>'path' = 'break-glass:postgres'")
res "Q5 Q30 revert: value + column default back to pending_kyle, history row deleted, decision event; recon_pay_config (minus note / updated_at), default and history == pre-Q30" "$([ "$rv" = 'pending_kyle|t|f|1' ] && [ "$POST" = "$PRE" ] && [ "$rve" = 1 ] && [ "$(q $D -c "$SCHEMA")" = "$SCHQ0" ] && echo PASS || echo FAIL)" "grid=$rv state_equal=$([ "$POST" = "$PRE" ] && echo yes || echo no) events=$rve"
r6=$(psql -X -At -v ON_ERROR_STOP=1 -d $D -f "$Q30R" 2>&1 | grep -o 'not include: nothing changed' | head -1)
n=$(passes $D supabase/tests/verify_slice3.sql)
res "Q6 revert re-run refuses; verify_slice3 passes after the revert" "$([ -n "$r6" ] && [ $n = $T3 ] && echo PASS || echo FAIL)" "${r6:-no refusal}; verify $n/$T3"
psql -X -q -v ON_ERROR_STOP=1 -d $D -f $RB >/dev/null 2>/tmp/q30rb.txt; rc=$?
res "Q7 after apply + revert the full slice-three rollback works again (exit 0, the five slice-two views back, no slice-three version left)" "$([ $rc = 0 ] && [ -n "$(q $D -c "$V5")" ] && [ "$(q $D -c "select count(*) from supabase_migrations.schema_migrations where version like '202610312%'")" = 0 ] && echo PASS || echo FAIL)" "rc=$rc $(grep -m1 ERROR /tmp/q30rb.txt)"
D=t3_q30b; liveish $D; psql -X -q -v ON_ERROR_STOP=1 -d $D -f $PASTE >/dev/null 2>&1 || echo "FAIL paste"
q $D -c "delete from public.recon_pay_config" >/dev/null
m1=$(psql -X -At -v ON_ERROR_STOP=1 -d $D -f "$Q30F" 2>&1 | grep -o 'recon_pay_config row is missing' | head -1); m2=$(psql -X -At -v ON_ERROR_STOP=1 -d $D -f "$Q30R" 2>&1 | grep -o 'recon_pay_config row is missing' | head -1)
res "Q8 apply and revert raise when the recon_pay_config row is missing (nothing recorded)" "$([ -n "$m1" ] && [ -n "$m2" ] && [ "$(q $D -c "select count(*) from supabase_migrations.schema_migrations where version = '20261031220000'")" = 0 ] && echo PASS || echo FAIL)" "apply: ${m1:-no raise}; revert: ${m2:-no raise}"
rm -f "$Q30F" "$Q30R"

# D. fresh build from the repo
D=t3_fresh; newdb $D
for f in supabase/migrations/*.sql supabase/seed.sql supabase/seed_slice2.sql; do psql -q -v ON_ERROR_STOP=1 -d $D -f $f >/dev/null 2>&1 || echo "FAIL $f"; done
n1=$(passes $D supabase/tests/verify.sql); n2=$(passes $D supabase/tests/verify_slice2_slice3era.sql); n3=$(passes $D supabase/tests/verify_slice3.sql)
res "D1 fresh build: verify.sql + verify_slice2_slice3era.sql + verify_slice3.sql" "$([ $n1 = 24 ] && [ $n2 = $T2X ] && [ $T3 -gt 0 ] && [ $n3 = $T3 ] && echo PASS || echo FAIL)" "$n1/24, $n2/$T2X, $n3/$T3 $(fails $D supabase/tests/verify_slice3.sql)"
psql -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed_slice3_mock.sql >/dev/null 2>&1; psql -q -v ON_ERROR_STOP=1 -d $D -f supabase/seed_slice3_mock.sql >/dev/null 2>&1; rc=$?
res "D2 mock seed loads and re-runs without duplicates" "$([ $rc = 0 ] && [ "$(q $D -c 'select count(*) from premier_member_products')" = 66 ] && [ "$(q $D -c 'select count(*) from board_submissions')" = 35 ] && echo PASS || echo FAIL)" "premier=$(q $D -c 'select count(*) from premier_member_products') board=$(q $D -c 'select count(*) from board_submissions')"
ADM=$(q $D -c "select id from auth.users where email='admin.test@example.com'")
PLQ="select set_config('request.jwt.claims', json_build_object('sub','$ADM','role','authenticated')::text, true); set local role authenticated;
 select concat_ws('|', (select projected_commission from pl_daily_walk where day='2026-10-29'), (select net from pl_weekly_walk where week_start='2026-10-25'),
   (select projected_commission from pl_monthly_walk where month_start='2026-10-01'), (select net from pl_monthly_walk where month_start='2026-10-01'))"
fig=$(psql -X -At -v ON_ERROR_STOP=1 -d $D -c "begin" -c "$PLQ" -c "rollback" 2>/dev/null | grep '|' | tail -1)
res "D4 mock-only P&L figures (fresh build incl. Q30 include: S18 112.86 on 10/30): 10/29 rep pay 1020.33, week 10/25 net -4449.01, October rep pay 4568.33 / net -4568.33 (before Q30: -4336.15 / 4455.47 / -4455.47; before B2: -4484.62 / 4603.94)" "$([ "$fig" = '1020.33|-4449.01|4568.33|-4568.33' ] && echo PASS || echo FAIL)" "$fig"
for m in supabase/migrations/2026103121*.sql; do psql -q -v ON_ERROR_STOP=1 -d $D -f $m >/dev/null 2>&1 || echo "FAIL rerun $m"; done
res "D3 slice-three migrations re-run on a loaded DB (idempotent, data kept)" "$([ "$(q $D -c 'select count(*) from premier_member_products')" = 66 ] && [ "$(q $D -c 'select count(*) from premier_addon_map')" = "$(q t3_live -c 'select count(*) from premier_addon_map')" ] && echo PASS || echo FAIL)" ""

echo; echo "$(printf '%s\n' "${RES[@]}" | grep -c '|PASS|')/${#RES[@]} passed"
