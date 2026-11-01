#!/usr/bin/env bash
# Builds the slice-4a deploy package OUTSIDE the repo and ties it to the current commit:
#   slice4a_paste.sql + slice4a_autopay_on.sql (rebuilt), slice4a_rollback.sql (regenerated, must match the tree),
#   slice4a_preflight.sql, slice4a_depcheck.sql (copied), slice4a_package_manifest.txt (head + sha256 of each).
set -euo pipefail
cd "$(dirname "$0")/.."
PKG="${1:-/workspace/aca_system_deploy}"
case "$(realpath -m "$PKG")/" in "$(git rev-parse --show-toplevel)/"*) echo "package dir is inside the repo; refused" >&2; exit 1;; esac
[ -z "$(git status --porcelain -- supabase scripts web)" ] || { echo "tree has uncommitted changes; commit first" >&2; exit 1; }
python3 scripts/build_slice4a_rollback.py >/dev/null
[ -z "$(git status --porcelain -- supabase/rollback)" ] || { echo "slice4a_rollback.sql is stale vs origin/main; commit the regenerated file" >&2; exit 1; }
bash scripts/build_slice4a_paste.sh "$PKG" >/dev/null
for f in supabase/rollback/slice4a_rollback.sql supabase/deploy/slice4a_preflight.sql supabase/deploy/slice4a_depcheck.sql; do
  cp "$f" "$PKG/$(basename "$f")"; done
{ echo "head $(git rev-parse HEAD)"; echo "branch $(git rev-parse --abbrev-ref HEAD)"; echo "built $(date '+%F %T %Z')"
  for n in slice4a_paste.sql slice4a_autopay_on.sql slice4a_rollback.sql slice4a_preflight.sql slice4a_depcheck.sql; do
    echo "sha256 $(sha256sum < "$PKG/$n" | cut -d' ' -f1) $n"; done; } > "$PKG/slice4a_package_manifest.txt"
cat "$PKG/slice4a_package_manifest.txt"
