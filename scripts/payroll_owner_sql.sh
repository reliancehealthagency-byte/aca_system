#!/usr/bin/env bash
# Apply-time helper (slice three): prints the ONE SQL Editor statement that sets recon_pay_config.payroll_owner_user_id
# from /workspace/secrets/payroll_owner_user_id.txt (0600, never committed). Run it only after the paste is applied and
# Kyle signed off; paste the output into the SQL Editor (postgres). While the file doesn't exist the owner stays NULL.
set -euo pipefail
F=${1:-/workspace/secrets/payroll_owner_user_id.txt}
[ -f "$F" ] || { echo "payroll_owner_sql: $F not found: leave payroll_owner_user_id NULL (no Kyle account identified)" >&2; exit 1; }
[ "$(stat -c %a "$F")" = 600 ] || { echo "payroll_owner_sql: $F must be mode 0600" >&2; exit 1; }
U=$(tr -d '[:space:]' < "$F")
[[ "$U" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "payroll_owner_sql: $F does not hold a uuid" >&2; exit 1; }
cat <<SQL
-- set the payroll owner once (SQL Editor only; refused for service_role / other admins by recon_pay_config_guard)
do \$\$ begin
  if not exists (select 1 from auth.users where id = '$U') then raise exception 'no auth user %', '$U'; end if;
  update public.recon_pay_config set payroll_owner_user_id = '$U' where id and payroll_owner_user_id is null;
  if not found then raise exception 'payroll owner already set: change it only as the current owner'; end if;
end \$\$;
SQL
