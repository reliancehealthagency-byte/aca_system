#!/usr/bin/env bash
# Builds the agent-attribution (C5) SQL Editor paste + regenerates its rollback. ONE transaction, no mock data.
#   agent_attribution_paste.sql     preflight + 20261101090000 + history. Changes attribution of FUTURE board imports only.
#   agent_attribution_rollback.sql  copy of supabase/rollback/agent_attribution_rollback.sql
# The alias rows themselves are owner data: scripts/agent_aliases_sql.py --tab <live Agent Aliases tab CSV> (runbook step).
set -euo pipefail
cd "$(dirname "$0")/.."
dir="${1:-/workspace/aca_system_deploy}"; mkdir -p "$dir"
python3 scripts/build_agent_attribution_rollback.py >/dev/null
p="$dir/agent_attribution_paste.sql"
{
  echo "-- C5 agent attribution (hub v19.11 rules): preflight + 20261101090000 + history, ONE transaction."
  echo "-- Paste into the Supabase SQL Editor (project szkmzpquomcqgkvzpoez) ONLY after Orchestrator review. Then load the aliases"
  echo "-- (scripts/agent_aliases_sql.py) BEFORE the next board import. Existing board rows are unchanged. Re-run = no-op."
  echo "begin;"
  echo; cat supabase/deploy/agent_attribution_preflight_block.sql
  echo; echo "-- ===== supabase/migrations/20261101090000_agent_attribution.sql ====="; cat supabase/migrations/20261101090000_agent_attribution.sql
  echo; echo "insert into supabase_migrations.schema_migrations (version, name, statements) values"
  echo "  ('20261101090000', 'agent_attribution', array['-- applied via SQL Editor (agent_attribution_paste.sql)'])"
  echo "on conflict (version) do nothing;"
  echo; echo "commit;"; echo; echo "notify pgrst, 'reload schema';"
} > "$p"
cp supabase/rollback/agent_attribution_rollback.sql "$dir/agent_attribution_rollback.sql"
sha256sum "$p" "$dir/agent_attribution_rollback.sql"
