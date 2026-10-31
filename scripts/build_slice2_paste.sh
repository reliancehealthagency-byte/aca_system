#!/usr/bin/env bash
# Builds the one-shot SQL Editor paste for slice two: preflight + 3 migrations + seed + migration history, in ONE transaction.
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-/workspace/aca_system_deploy/slice2_paste.sql}"
{
  echo "-- slice two (line-item P&L): preflight + 3 migrations + FAKE expense seed + migration history, ONE transaction."
  echo "-- Paste into the Supabase SQL Editor (project szkmzpquomcqgkvzpoez) and run once. Nothing is dropped."
  echo "-- Aborts (no changes) unless expenses are exactly the slice-one seed. A re-run after success is a no-op."
  echo "begin;"
  echo; cat supabase/deploy/slice2_preflight_block.sql
  for f in supabase/migrations/2026103120*.sql supabase/seed_slice2.sql; do echo; echo "-- ===== $f ====="; cat "$f"; done
  echo; cat supabase/deploy/slice2_record_migrations.sql
  echo; echo "commit;"
} > "$out"
sha256sum "$out"
