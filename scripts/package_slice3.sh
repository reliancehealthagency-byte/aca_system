#!/usr/bin/env bash
# Builds the slice-three deploy package OUTSIDE the repo and ties it to the current commit (rev 4):
#   slice3_paste.sql (rebuilt), slice3_rollback.sql, slice3_preflight.sql, slice3_retire_depcheck.sql (copied from the tree),
#   slice3_package_manifest.txt (head + sha256 of each). Run on a clean tree after committing; local_test_slice3.sh P0-P2 check it.
set -euo pipefail
cd "$(dirname "$0")/.."
PKG="${1:-/workspace/aca_system_deploy}"
case "$(realpath -m "$PKG")" in "$(git rev-parse --show-toplevel)"*) echo "package dir is inside the repo; refused" >&2; exit 1;; esac
[ -z "$(git status --porcelain -- supabase scripts web | grep -v '^??')" ] || { echo "tree has uncommitted changes; commit first" >&2; exit 1; }
bash scripts/build_slice3_paste.sh "$PKG/slice3_paste.sql" >/dev/null
for f in supabase/rollback/slice3_rollback.sql supabase/deploy/slice3_preflight.sql supabase/deploy/slice3_retire_depcheck.sql; do
  cp "$f" "$PKG/$(basename "$f")"; done
{ echo "head $(git rev-parse HEAD)"; echo "branch $(git rev-parse --abbrev-ref HEAD)"; echo "built $(date '+%F %T %Z')"
  for n in slice3_paste.sql slice3_rollback.sql slice3_preflight.sql slice3_retire_depcheck.sql; do
    echo "sha256 $(sha256sum < "$PKG/$n" | cut -d' ' -f1) $n"; done; } > "$PKG/slice3_package_manifest.txt"
cat "$PKG/slice3_package_manifest.txt"
