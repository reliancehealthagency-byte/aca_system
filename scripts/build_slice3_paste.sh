#!/usr/bin/env bash
# Builds the one-shot SQL Editor paste for slice three: preflight + 5 migrations + migration history, in ONE transaction.
# The MOCK Premier/board seed (supabase/seed_slice3_mock.sql) is deliberately NOT included: live gets structure + config only.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-/workspace/aca_system_deploy/slice3_paste.sql}"
{
  echo "-- slice three (Premier reconciliation): preflight + 5 migrations + migration history, ONE transaction. No mock data."
  echo "-- Paste into the Supabase SQL Editor (project szkmzpquomcqgkvzpoez) and run once, ONLY after Orchestrator review and Kyle's sign-off."
  echo "-- Aborts (no changes) unless slice one + two are recorded, commission_config is 0.38/0.05 and no slice-three object exists."
  echo "-- Drops slice two's five P&L views (Kyle 10/31 7:35 PM: retired; views only, no data; slice3_rollback.sql recreates them). Sales gains two nullable columns (premier_member_id, lead_source). A re-run after success is a no-op."
  echo "begin;"
  echo; cat supabase/deploy/slice3_preflight_block.sql
  for f in supabase/migrations/2026103121*.sql; do echo; echo "-- ===== $f ====="; cat "$f"; done
  echo; cat supabase/deploy/slice3_record_migrations.sql
  echo; echo "commit;"
} > "$out"
sha256sum "$out" | tee "$out.sha256"
