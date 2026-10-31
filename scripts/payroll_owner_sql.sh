#!/usr/bin/env bash
# Apply-time helper (slice three): sets recon_pay_config.payroll_owner_user_id from /workspace/secrets/payroll_owner_user_id.txt
# (0600, never committed). The uuid is NEVER printed (rev 4):
#   scripts/payroll_owner_sql.sh --psql "<psql connection args>"   stream the statement straight into psql (as postgres)
#   scripts/payroll_owner_sql.sh --out /tmp/owner.sql              write a 0600 file OUTSIDE the repo to open in the SQL
#                                                                  Editor; shred it right after (shred -u /tmp/owner.sql)
# Run only after the paste is applied and Kyle gave the go-ahead. Optional: OWNER_FILE=<path> to read another file.
set -euo pipefail
F=${OWNER_FILE:-/workspace/secrets/payroll_owner_user_id.txt}
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
mode=${1:-}; arg=${2:-}
case "$mode" in --psql|--out) [ -n "$arg" ] || { echo "payroll_owner_sql: $mode needs a value" >&2; exit 2; } ;;
  *) echo "usage: payroll_owner_sql.sh --psql \"<conn args>\" | --out FILE  (the uuid is never printed)" >&2; exit 2 ;; esac
[ -f "$F" ] || { echo "payroll_owner_sql: owner file not found: leave payroll_owner_user_id NULL" >&2; exit 1; }
[ "$(stat -c %a "$F")" = 600 ] || { echo "payroll_owner_sql: owner file must be mode 0600" >&2; exit 1; }
U=$(tr -d '[:space:]' < "$F")
[[ "$U" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "payroll_owner_sql: owner file does not hold a uuid" >&2; exit 1; }
sql(){ cat <<SQL
-- set the payroll owner once (SQL Editor / postgres only; refused for service_role and other admins by recon_pay_config_guard)
do \$\$ begin
  if not exists (select 1 from auth.users where id = '$U') then raise exception 'payroll owner: that auth user does not exist'; end if;
  update public.recon_pay_config set payroll_owner_user_id = '$U' where id and payroll_owner_user_id is null;
  if not found then raise exception 'payroll owner already set: change it only as the current owner'; end if;
end \$\$;
SQL
}
if [ "$mode" = --psql ]; then
  # shellcheck disable=SC2086
  sql | psql -X -q -v ON_ERROR_STOP=1 $arg >/dev/null && echo "payroll owner set from the secrets file (id not shown)" >&2
else
  d=$(cd "$(dirname "$arg")" && pwd -P); case "$d/" in "$REPO"/*) echo "payroll_owner_sql: --out must be outside the repo" >&2; exit 1;; esac
  ( umask 077; sql > "$arg" ); chmod 600 "$arg"
  echo "wrote $arg (0600). Paste it in the SQL Editor, then: shred -u $arg" >&2
fi
