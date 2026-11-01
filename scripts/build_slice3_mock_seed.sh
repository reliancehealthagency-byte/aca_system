#!/usr/bin/env bash
# Rebuilds supabase/seed_slice3_mock.sql from Payroll's MOCK files (box: /workspace/artifacts/premier_mock).
set -euo pipefail
cd "$(dirname "$0")/.."
M=${M:-/workspace/artifacts/premier_mock}
{
echo "-- Slice three MOCK seed (ALL DATA FAKE; agent names real with Kyle's OK). NOT part of the live paste: load only on a test DB"
echo "-- or with Kyle's explicit OK. Re-running is a no-op (imports keyed by file sha256; cutoffs/adjustments on conflict do nothing)."
echo "-- Spiff cutoffs for the mock week (README assumptions): 10/30 payday = Kyle's submit Thu 10/29 ~14:07:15 ET;"
echo "-- 11/06 payday = provisional Thu 11/05 23:59:59 ET until the submit is recorded."
echo "insert into public.payroll_cutoffs (payday, cutoff_at, source, note) values"
echo "  ('2026-10-23', '2026-10-22 14:46:46 America/New_York', 'submit', 'MOCK seed: stand-in (10/22 Rates-tab cutoff)'),"
echo "  ('2026-10-30', '2026-10-29 14:07:15 America/New_York', 'submit', 'MOCK seed: README assumption (hub cutoff run 10/29 14:07:15)'),"
echo "  ('2026-11-06', '2026-11-05 23:59:59 America/New_York', 'provisional', 'MOCK seed: provisional until Kyle submits')"
echo "on conflict (payday) do nothing;"
echo
python3 scripts/csv_to_recon_sql.py --mock --premier "$M/MOCK_PHS_Member_Products_2026-10-31.csv" \
  --board "$M/MOCK_Sales_Board_Form_Responses_1_slice_2026-10-25_to_10-31.csv" --madj "$M/MOCK_Manual_Adjustments_2026-10-31.csv"
} > supabase/seed_slice3_mock.sql
sha256sum supabase/seed_slice3_mock.sql
