#!/usr/bin/env bash
# One-command rebuild of the hub cutover package (run ONLY at the actual switch, right after re-exporting the tabs).
#
#   scripts/hub_cutover_rebuild.sh PKG_DIR                 # build both imports + checks + DRY RUN sql + manifest
#   TOKEN=XXXXXXXXXX scripts/hub_cutover_rebuild.sh PKG_DIR  # same, plus the APPLY sql bound to that dry-run token
#
# PKG_DIR/source/ must hold ONE read of the hub sheet (Sheets connector, read-only; never write to the sheet):
#   paid_lock_unformatted.csv  paid_lock_formatted.csv  lock_open_items.csv  manual_adjustments_formatted.csv  cover_seeds.csv
#   finalized_paydays_summary.csv  agent_sheets.csv  agent_aliases.csv
# and, when the Manual Adjustments tab has rows dated after the last hub payday (B-3: MUST RE-ENTER, never imported),
#   reenter_ack.csv (Tab Row,Payday,Agent,Amount,Acknowledged By) listing each one; build refuses without it. An
#   'Acknowledged By' of REHEARSAL... is accepted for the dry run only: the APPLY needs Kyle's own ack.
# Outputs (0600, private: real pay data never goes in the repo): paid_lock_import.csv, lock_open_import.csv, adjustments_import.csv, must_reenter.csv,
# snapshot.json, checks.md, hub_cutover_dryrun.sql, [hub_cutover_apply.sql], hub_cutover_preflight.sql,
# hub_lock_open_items_rollback.sql, manifest.txt.
# Nothing here touches a database. The SQL files are pasted into the Supabase SQL Editor by the owner.
set -euo pipefail
PKG=${1:?usage: hub_cutover_rebuild.sh PKG_DIR}; S=$PKG/source
HERE=$(cd "$(dirname "$0")/.." && pwd); PY="python3 $HERE/scripts/hub_cutover.py"
umask 077
ACK=; [ -s "$S/reenter_ack.csv" ] && ACK=$S/reenter_ack.csv
for f in paid_lock_unformatted.csv paid_lock_formatted.csv lock_open_items.csv manual_adjustments_formatted.csv cover_seeds.csv \
         finalized_paydays_summary.csv agent_sheets.csv agent_aliases.csv; do
  [ -s "$S/$f" ] || { echo "missing $S/$f (re-export the hub tabs in ONE read first)" >&2; exit 2; }
done
$PY build --unformatted "$S/paid_lock_unformatted.csv" --formatted "$S/paid_lock_formatted.csv" --out "$PKG/paid_lock_import.csv" \
    --lock-open-formatted "$S/lock_open_items.csv" --lock-open-out "$PKG/lock_open_import.csv" \
    --adjustments-formatted "$S/manual_adjustments_formatted.csv" --adjustments-out "$PKG/adjustments_import.csv" --cover-seeds "$S/cover_seeds.csv" \
    --must-reenter-out "$PKG/must_reenter.csv" ${ACK:+--reenter-ack "$ACK"}
{ $PY check --csv "$PKG/paid_lock_import.csv" --roster "$S/agent_sheets.csv" --aliases "$S/agent_aliases.csv" \
      --finalized "$S/finalized_paydays_summary.csv" --lock-open "$PKG/lock_open_import.csv" --adjustments "$PKG/adjustments_import.csv" \
      --must-reenter "$PKG/must_reenter.csv" ${ACK:+--reenter-ack "$ACK"}
  cat <<'MD'

### Runbook (one line)
At the switch only: re-export the hub tabs (one read) → Kyle fills `source/reenter_ack.csv` (his name on every MUST RE-ENTER row) → `scripts/hub_cutover_rebuild.sh PKG` → owner pastes `hub_cutover_dryrun.sql` in the SQL Editor (must say DRY RUN OK + token; BLOCKED = load roster/aliases first) → `TOKEN=<token> scripts/hub_cutover_rebuild.sh PKG` → owner pastes `hub_cutover_apply.sql` (refuses if anything changed since the dry run).

### Timing
- No live cutover before the actual switch; the Paid Lock + Lock Open Items tabs are re-exported right before it (this package is a rehearsal until then).
- Until the cutover is recorded, no backend submits for paydays the hub is still paying.
- Before the dry run: backend roster + agent_name_aliases loaded (else DRY RUN BLOCKED), and the latest Premier board export loaded (open items match board lines by Line ID). Board rows loaded before the roster keep a NULL agent id.

### Roster prerequisite (the live dry run cannot pass yet)
- The LIVE dry run will say DRY RUN BLOCKED (no token) until the backend roster (`agents`) and `agent_name_aliases` are loaded: today the live roster is fake-only, so all 10 names carrying hub dollars are unmapped (see the Agent mapping table above).
- That load is planned in slice 4a/4c: it loads the LIVE hub "Agent Aliases" tab **plus the code-only defaults** the hub adds when the tab doesn't map a name (`CODE_ALIASES_` / `CODE_DIALER_`; one agent resolves by code only, not the tab). Reference: `/workspace/artifacts/validation_1029/agent_name_map.md`.
- Order at the switch: slice 4a/4c roster + aliases live → Premier board export loaded → re-export the tabs → rebuild → dry run.

### Open items and hub adjustments (Orchestrator B-2)
- Lock Open Items come from the tab only: the hub has no placeholder logic (v19.9-v19.11); a $0 pending line in a snapshot is only a rendering, so it is not imported.
- Hub-era Manual Adjustments are NOT imported as pay (they are inside the Paid Lock totals). Every line-linked one (Covers column, or a hub code COVER_SEEDS_ match; the hard-coded wrong-ID links are ignored) is imported as a paid-elsewhere marker on that line component (`hub_paid_elsewhere`): the backend pays it $0 and never locks it, however spiffs are recomputed later. See the tables above (a spiff the hub paid via the 10/30 lock shows "paid 2026-10-30 via the lock").

### MUST RE-ENTER (Orchestrator B-3)
- Every Manual Adjustments row dated after the last hub payday — line-linked or not (advance repays, spot paybacks, ...) — was never paid by the hub. The cutover does NOT import it as pay or as a marker; it is listed in the MUST RE-ENTER table above and in `must_reenter.csv`, and must be entered in the backend as a pay adjustment for its payday.
- `build` refuses unless `source/reenter_ack.csv` lists every one of them (Tab Row, Payday, Agent, Amount, Acknowledged By) and nothing else; the shas of `must_reenter.csv` and the ack are in `snapshot.json`, `sql` re-checks both, and both go into the dry-run token and the import event. So none can be dropped silently.
- This rehearsal uses a `REHEARSAL (Systems Build)` ack: enough for the dry run only; `--confirm-hub` refuses it. At the switch Kyle replaces it with his own ack (then a fresh dry run, since the token covers the ack).

### Settled by hub / marker drift (should-fix 2 + 3)
- Clawbacks: a refund / void whose clawback payday is on/before the cutover, or whose commission the hub clawed by hand (a `claw` marker, e.g. tab row 9), shows `settled_by_hub` in `premier_recon_clawbacks` and in the event log ("settled by hub", never "needs Kyle approve"); a `clawback_approved` adjustment for it is refused by a trigger, so it can't be clawed twice.
- Markers zero a whole line part. `premier_recon_paid_elsewhere_drift` compares what the hub paid / clawed on each marked part with the backend's current amount; a difference (later add-on, reinstatement) shows `differs` and is logged once per amount (`hub_cutover.paid_elsewhere_amount_differs`) for Kyle — it is not paid automatically.

### Paste on live (main without migration 20261101120000): tests M1–M2
- The cutover paste carries migration 20261101120000 inside its own transaction: on a database that does not have it yet (live today), the **APPLY applies the migration and records the cutover in ONE transaction** (M2: tables, views, guards and the schema_migrations version row all land together with the cutover rows, or none of it does).
- The **DRY RUN does not refuse** on such a database: it applies the migration in-transaction, runs every check, prints DRY RUN OK + token, and then **rolls everything back**, DDL included (M1: afterwards no hub_lock_open_items / hub_paid_elsewhere table exists).

### Rollback (schema only, before any cutover)
`hub_lock_open_items_rollback.sql` undoes migration 20261101120000 (SQL Editor): refuses once the cutover has been applied (any hub_paid_lock row, a recorded hub_cutover, or imported open items); otherwise restores the pre-migration schema exactly (verified: pg_dump --schema-only identical). Run it before `slice3_rollback.sql`.
MD
} > "$PKG/checks.md"
$PY sql --csv "$PKG/paid_lock_import.csv" --lock-open "$PKG/lock_open_import.csv" --adjustments "$PKG/adjustments_import.csv" --snapshot "$PKG/snapshot.json" --dry-run --out "$PKG/hub_cutover_dryrun.sql"
rm -f "$PKG/hub_cutover_apply.sql"
if [ -n "${TOKEN:-}" ]; then
  $PY sql --csv "$PKG/paid_lock_import.csv" --lock-open "$PKG/lock_open_import.csv" --adjustments "$PKG/adjustments_import.csv" --snapshot "$PKG/snapshot.json" \
      --confirm-hub --dry-run-token "$TOKEN" --out "$PKG/hub_cutover_apply.sql"
fi
cp "$HERE/supabase/deploy/hub_cutover_preflight.sql" "$PKG/hub_cutover_preflight.sql"
cp "$HERE/supabase/rollback/hub_lock_open_items_rollback.sql" "$PKG/hub_lock_open_items_rollback.sql"
( cd "$PKG" && { echo "hub cutover package, built $(date '+%Y-%m-%d %H:%M %Z') from $(git -C "$HERE" rev-parse --short HEAD)"
  sha256sum $(ls *.csv *.sql *.md *.json *.txt 2>/dev/null | grep -v '^manifest.txt$') source/*.csv; } > manifest.txt )
chmod 600 "$PKG"/*.* "$S"/*.csv
echo "rebuilt $PKG: $(grep -c '' "$PKG/paid_lock_import.csv") paid-lock lines, $(grep -c '' "$PKG/lock_open_import.csv") open-item lines; apply: ${TOKEN:+built for token $TOKEN}${TOKEN:-not built (needs TOKEN from the live dry run)}"
