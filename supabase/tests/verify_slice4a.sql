-- Slice 4a verification: the full slice-three scenario (closed_week_policy forced to 'hold' for it, rolled back), then the
-- actuals-ledger (LG1-LG14) and closed-week next-open-payday (CW0-CW6) checks on its end state. ONE transaction, rolls back.
-- Requires slices one-three + PR #7 20261101120000 + 20261101130000/130100 (autopay switch optional). Run from the repo root:  psql -v ON_ERROR_STOP=1 -f supabase/tests/verify_slice4a.sql
\set slice4a 1
\ir verify_slice3.sql
