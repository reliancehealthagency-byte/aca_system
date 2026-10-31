#!/usr/bin/env bash
# Apply slice-one migrations + seed to the live Supabase project, then run the verification.
# Two transports:
#   psql  (default): needs network access to Postgres (session pooler, port 5432).
#   api:            Supabase Management API over HTTPS; needs a personal access token in SUPABASE_ACCESS_TOKEN.
# Secrets are read from files/env and never printed.
#   SUPABASE_ENV=/workspace/secrets/supabase.env DB_PASSWORD_FILE=/workspace/secrets/supabase_db_password.txt \
#   POOLER_HOST=aws-0-us-east-1.pooler.supabase.com scripts/apply_remote.sh [psql|api]
set -euo pipefail
MODE=${1:-psql}
cd "$(dirname "$0")/.."
set -a; . "${SUPABASE_ENV:?}"; set +a
FILES=(supabase/migrations/*.sql supabase/seed.sql)

if [ "$MODE" = psql ]; then
  export PGPASSWORD="$(tr -d '\n' < "${DB_PASSWORD_FILE:?}")"
  CONN="host=${POOLER_HOST:-aws-0-us-east-1.pooler.supabase.com} port=5432 user=postgres.$SUPABASE_PROJECT_REF dbname=postgres sslmode=require"
  for f in "${FILES[@]}"; do echo "applying $f"; psql "$CONN" -X -q -v ON_ERROR_STOP=1 -f "$f"; done
  psql "$CONN" -X -f supabase/tests/verify.sql
elif [ "$MODE" = api ]; then
  : "${SUPABASE_ACCESS_TOKEN:?personal access token required for api mode}"
  q() { python3 -c 'import json,sys; print(json.dumps({"query": sys.stdin.read()}))' \
        | curl -sS -X POST "https://api.supabase.com/v1/projects/$SUPABASE_PROJECT_REF/database/query" \
               -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H 'content-type: application/json' --data-binary @-; echo; }
  for f in "${FILES[@]}"; do echo "applying $f"; q < "$f"; done
  # verify.sql without psql meta-commands; results are returned inside an exception so the test transaction aborts.
  grep -v '^\\' supabase/tests/verify.sql \
    | sed 's/^rollback;$/do $x$ begin raise exception '"'"'VERIFY_RESULTS %'"'"', (select json_agg(json_build_object('"'"'n'"'"',n,'"'"'pass'"'"',pass,'"'"'check'"'"',check_name,'"'"'detail'"'"',detail) order by n) from results); end $x$;/' \
    | q
else
  echo "usage: $0 [psql|api]"; exit 2
fi
