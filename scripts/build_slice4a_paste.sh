#!/usr/bin/env bash
# Builds the two slice-4a SQL Editor pastes (ONE transaction each, no mock data):
#   slice4a_paste.sql       preflight + 20261101100000 (actuals ledger) + 20261101100100 (closed-week carry, policy 'hold') + history
#   slice4a_autopay_on.sql  preflight + 20261101100200 (policy -> next_open_payday) + history. LIVE PAY CHANGE: Kyle's go-ahead only.
set -euo pipefail
cd "$(dirname "$0")/.."
dir="${1:-/workspace/aca_system_deploy}"
p="$dir/slice4a_paste.sql"; a="$dir/slice4a_autopay_on.sql"
{
  echo "-- slice 4a (Balanced Books: actuals ledger + closed-week carry, behavior-neutral): preflight + 2 migrations + history, ONE transaction."
  echo "-- Paste into the Supabase SQL Editor (project szkmzpquomcqgkvzpoez) and run once, ONLY after Orchestrator review and Kyle's sign-off."
  echo "-- Aborts (no changes) unless slice three (5) + Q30 are recorded and no slice-4a object exists. Live pay does not change:"
  echo "-- closed_week_policy is created as 'hold'. The ledger backfills every confirmed source row at apply time. A re-run is a no-op."
  echo "begin;"
  echo; cat supabase/deploy/slice4a_preflight_block.sql
  for f in supabase/migrations/20261101100000_actuals_ledger.sql supabase/migrations/20261101100100_closed_week_next_open_payday.sql; do
    echo; echo "-- ===== $f ====="; cat "$f"; done
  echo; cat supabase/deploy/slice4a_record_migrations.sql
  echo; echo "commit;"; echo; echo "notify pgrst, 'reload schema';"
} > "$p"
{
  echo "-- slice 4a part 3: closed-week rows AUTO-PAY on the next open payday. ONE transaction. LIVE PAYROLL BEHAVIOR CHANGE."
  echo "-- Run ONLY with Kyle's direct go-ahead (Orchestrator relays), after slice4a_paste.sql. Re-run is a no-op."
  echo "begin;"
  echo; cat supabase/deploy/slice4a_autopay_preflight_block.sql
  echo; echo "-- ===== supabase/migrations/20261101100200_closed_week_autopay_on.sql ====="; cat supabase/migrations/20261101100200_closed_week_autopay_on.sql
  echo; echo "insert into supabase_migrations.schema_migrations (version, name, statements) values"
  echo "  ('20261101100200', 'closed_week_autopay_on', array['-- applied via SQL Editor (slice4a_autopay_on.sql; sha256 in slice4a_review.md)'])"
  echo "on conflict (version) do nothing;"
  echo; echo "commit;"; echo; echo "notify pgrst, 'reload schema';"
} > "$a"
sha256sum "$p" "$a"
