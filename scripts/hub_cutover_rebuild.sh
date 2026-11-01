#!/usr/bin/env bash
# One-command rebuild of the hub cutover package (run ONLY at the actual switch, right after re-exporting the tabs).
#
#   scripts/hub_cutover_rebuild.sh PKG_DIR                 # build both imports + checks + DRY RUN sql + manifest
#   TOKEN=XXXXXXXXXX scripts/hub_cutover_rebuild.sh PKG_DIR  # same, plus the APPLY sql bound to that dry-run token
#
# PKG_DIR/source/ must hold ONE read of the hub sheet (Sheets connector, read-only; never write to the sheet):
#   paid_lock_unformatted.csv  paid_lock_formatted.csv  lock_open_items.csv  hub_code_seeds.csv
#   finalized_paydays_summary.csv  agent_sheets.csv  agent_aliases.csv
# Outputs (0600, private: real pay data never goes in the repo): paid_lock_import.csv, lock_open_import.csv,
# snapshot.json, checks.md, hub_cutover_dryrun.sql, [hub_cutover_apply.sql], manifest.txt.
# Nothing here touches a database. The SQL files are pasted into the Supabase SQL Editor by the owner.
set -euo pipefail
PKG=${1:?usage: hub_cutover_rebuild.sh PKG_DIR}; S=$PKG/source
HERE=$(cd "$(dirname "$0")/.." && pwd); PY="python3 $HERE/scripts/hub_cutover.py"
umask 077
for f in paid_lock_unformatted.csv paid_lock_formatted.csv lock_open_items.csv hub_code_seeds.csv \
         finalized_paydays_summary.csv agent_sheets.csv agent_aliases.csv; do
  [ -s "$S/$f" ] || { echo "missing $S/$f (re-export the hub tabs in ONE read first)" >&2; exit 2; }
done
$PY build --unformatted "$S/paid_lock_unformatted.csv" --formatted "$S/paid_lock_formatted.csv" --out "$PKG/paid_lock_import.csv" \
    --lock-open-formatted "$S/lock_open_items.csv" --lock-open-out "$PKG/lock_open_import.csv" --hub-code-seeds "$S/hub_code_seeds.csv"
{ $PY check --csv "$PKG/paid_lock_import.csv" --roster "$S/agent_sheets.csv" --aliases "$S/agent_aliases.csv" \
      --finalized "$S/finalized_paydays_summary.csv" --lock-open "$PKG/lock_open_import.csv"
  cat <<'MD'

### Runbook (one line)
At the switch only: re-export the hub tabs (one read) → `scripts/hub_cutover_rebuild.sh PKG` → owner pastes `hub_cutover_dryrun.sql` in the SQL Editor (must say DRY RUN OK + token; BLOCKED = load roster/aliases first) → `TOKEN=<token> scripts/hub_cutover_rebuild.sh PKG` → owner pastes `hub_cutover_apply.sql` (refuses if anything changed since the dry run).

### Timing
- No live cutover before the actual switch; the Paid Lock + Lock Open Items tabs are re-exported right before it (this package is a rehearsal until then).
- Until the cutover is recorded, no backend submits for paydays the hub is still paying.
- Before the dry run: backend roster + agent_name_aliases loaded (else DRY RUN BLOCKED), and the latest Premier board export loaded (open items match board lines by Line ID). Board rows loaded before the roster keep a NULL agent id.
MD
} > "$PKG/checks.md"
$PY sql --csv "$PKG/paid_lock_import.csv" --lock-open "$PKG/lock_open_import.csv" --snapshot "$PKG/snapshot.json" --dry-run --out "$PKG/hub_cutover_dryrun.sql"
rm -f "$PKG/hub_cutover_apply.sql"
if [ -n "${TOKEN:-}" ]; then
  $PY sql --csv "$PKG/paid_lock_import.csv" --lock-open "$PKG/lock_open_import.csv" --snapshot "$PKG/snapshot.json" \
      --confirm-hub --dry-run-token "$TOKEN" --out "$PKG/hub_cutover_apply.sql"
fi
cp "$HERE/supabase/deploy/hub_cutover_preflight.sql" "$PKG/hub_cutover_preflight.sql"
( cd "$PKG" && { echo "hub cutover package, built $(date '+%Y-%m-%d %H:%M %Z') from $(git -C "$HERE" rev-parse --short HEAD)"
  sha256sum $(ls *.csv *.sql *.md *.json *.txt 2>/dev/null | grep -v '^manifest.txt$') source/*.csv; } > manifest.txt )
chmod 600 "$PKG"/*.* "$S"/*.csv
echo "rebuilt $PKG: $(grep -c '' "$PKG/paid_lock_import.csv") paid-lock lines, $(grep -c '' "$PKG/lock_open_import.csv") open-item lines; apply: ${TOKEN:+built for token $TOKEN}${TOKEN:-not built (needs TOKEN from the live dry run)}"
