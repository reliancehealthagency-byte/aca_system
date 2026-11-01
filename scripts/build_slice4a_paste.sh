#!/usr/bin/env bash
# Builds the slice-4a SQL Editor pastes (ONE transaction each, no mock data):
#   slice4a_paste.sql        preflight (requires PR #7 20261101120000 first) + 20261101130000 (actuals ledger)
#                            + 20261101130100 (combined true-up / lock: #7 exemption + closed-week carry, policy 'hold')
#                            + history + post-apply assertion
#   slice4a_autopay_on.sql   preflight + supabase/manual/closed_week_autopay_on.sql  (policy -> next_open_payday). LIVE PAY CHANGE.
#   slice4a_autopay_off.sql  preflight + supabase/manual/closed_week_autopay_off.sql (policy -> hold, audited). Kyle's go-ahead only.
set -euo pipefail
cd "$(dirname "$0")/.."
dir="${1:-/workspace/aca_system_deploy}"
p="$dir/slice4a_paste.sql"; a="$dir/slice4a_autopay_on.sql"; o="$dir/slice4a_autopay_off.sql"
{
  echo "-- slice 4a (Balanced Books: actuals ledger + closed-week carry, behavior-neutral): preflight + 2 migrations + history, ONE transaction."
  echo "-- Paste into the Supabase SQL Editor (project szkmzpquomcqgkvzpoez) and run once, ONLY after Orchestrator review and Kyle's sign-off."
  echo "-- Aborts (no changes) unless slice three (5) + Q30 + PR #7 (20261101120000) are recorded and incorporated and no slice-4a object exists."
  echo "-- Live pay does not change:"
  echo "-- closed_week_policy is created as 'hold'. The ledger backfills every confirmed source row at apply time. A re-run is a no-op."
  echo "begin;"
  echo; cat supabase/deploy/slice4a_preflight_block.sql
  for f in supabase/migrations/20261101130000_actuals_ledger.sql supabase/migrations/20261101130100_closed_week_next_open_payday.sql; do
    echo; echo "-- ===== $f ====="; cat "$f"; done
  echo; cat supabase/deploy/slice4a_record_migrations.sql
  echo; echo "commit;"; echo; echo "notify pgrst, 'reload schema';"
} > "$p"
sw(){ # $1 out, $2 manual file, $3 header
  { echo "$3"
    echo "-- Run ONLY with Kyle's direct go-ahead (Orchestrator relays), after slice4a_paste.sql. Re-run is a no-op. No migration version is recorded."
    echo "begin;"
    echo; cat supabase/deploy/slice4a_autopay_preflight_block.sql
    echo; echo "-- ===== $2 ====="; cat "$2"
    echo; echo "commit;"; echo; echo "notify pgrst, 'reload schema';"
  } > "$1"; }
sw "$a" supabase/manual/closed_week_autopay_on.sql "-- slice 4a switch ON: closed-week rows AUTO-PAY on the next open payday. ONE transaction. LIVE PAYROLL BEHAVIOR CHANGE."
sw "$o" supabase/manual/closed_week_autopay_off.sql "-- slice 4a switch OFF: closed-week rows back to HOLD (audited decision event). ONE transaction. LIVE PAYROLL BEHAVIOR CHANGE."
sha256sum "$p" "$a" "$o"
