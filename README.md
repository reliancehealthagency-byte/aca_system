# aca_system: Reliance backend (slice one skeleton + slice two line-item P&L, seed data only)

Backend for Reliance Health Agency's two-system rebuild (architecture spec approved by Kyle 10/31/2026).
This slice is a **skeleton with fake seed data only**: no GoHighLevel, Kimbo, Ringba or Premier integrations, and no real PII.

- Supabase project `aca-system`: `https://szkmzpquomcqgkvzpoez.supabase.co` (ref `szkmzpquomcqgkvzpoez`, us-east-1, Free). Keys are **never** in this repo.
- Postgres schema + RLS + audited event log: `supabase/migrations/`
- Fake seed data: `supabase/seed.sql`
- Verification (24 checks, runs in a rolled-back transaction): `supabase/tests/verify.sql` (10a/10b assert the P&L values and run before the checks that change a rate and a premium)
- Dashboard (Next.js App Router, TypeScript): `web/`

## Schema (Premier-first)

| Object | What it is |
|---|---|
| `agents` | Agent/admin profile linked to `auth.users` (`role` = `agent` or `admin`, `dialer_alias`, `no_spiff`, `no_transfer_pay`) |
| `contacts` | name, email, phone, state, preferred_language, created_at |
| `applications` | contact_id, carrier, plan_type, status, submitted_date, **premier_billing_date** |
| `sales` | contact_id, application_id, **agent_of_record** (form submitter / CRM converter, locked), `premier_agent_ref` (**reference only, never used for attribution**), `sale_date` (= form Date Booked), `board_premium` (claim), `premier_premium` (truth), `pay_premium` (generated = premier_premium), `addon_products`, `post_dated` |
| `call_metrics` | agent_name, date, calls_made, connects, appointments_set |
| `expenses` | category (FK to `expense_categories.code`), amount, date, description, **source**, vendor, external_ref, created_by, updated_at (slice two) |
| `commission_config` | **The one place commission rates live**: `base_rate` 0.38, `addon_bonus_rate` 0.05, `qualifying_addon_patterns` (LIKE patterns: ConsultCare Asset/Edge/Ultra, Wellness4You, AD&D / ADD / "Any ADD type" / Champion) |
| `event_log` | Append-only audit log (see below) |
| `sales_commission` (view) | Commission derived at read time: `pay_premium × (base + bonus if a qualifying add-on)`. Also `commission_estimate` (uses the board claim while Premier is pending), `pay_basis_date` (Premier billing date for post-dated deals, else Date Booked) and `commission_pay_friday` (Friday after that Sun–Sat week) |
| `daily_pl`, `weekly_pl`, `monthly_pl` (views) | P&L by day / Sun–Sat week / month. Admin only |

Changing a rate is a row update, not a migration: `update commission_config set base_rate = 0.40 where id;`

### P&L revenue figure: PLACEHOLDER
`daily_pl.net_placeholder = premium_total − agent_commission − expenses`, where `premium_total` is Premier's premium (or the board claim while Premier is pending) and `agent_commission` is `commission_estimate` from `commission_config`.
**This is a placeholder.** The agency's real revenue per sale (the P&L prototype's 42% vs payroll's 38%/43%) is an open question, so the net figure is not the agency's real profit.

## Slice two: line-item P&L
Migrations `20261031200000..200200`, seed `supabase/seed_slice2.sql` (20 FAKE expense lines, Oct 1-24 2026), checks `supabase/tests/verify_slice2.sql` (29 checks, rolled back), rollback `supabase/rollback/slice2_rollback.sql`.

**Live apply (SQL Editor paste, built by `scripts/build_slice2_paste.sh`):**
- Paste file: `slice2_paste.sql`, sha256 `6f9f741562c757e666d79cbc65c088b5a6a38187215921c08cf190cc7be2c090`
- Applied to live: **pending**
- Order inside ONE transaction: preflight (`supabase/deploy/slice2_preflight_block.sql`: aborts unless expenses are exactly the 4 live slice-one rows by (date, amount, description, category), as read from live 10/31 in `supabase/deploy/live_expenses_preapply.json`, or slice two is already applied and recorded) -> 3 migrations -> `seed_slice2.sql` -> migration history (`supabase/deploy/slice2_record_migrations.sql`: `supabase_migrations.schema_migrations`, CLI shape, slice-one versions backfilled, `on conflict do nothing`).
- Standalone read-only preflight: `supabase/deploy/slice2_preflight.sql`. Live check: `scripts/verify_live_slice2.py` (read-only by default; `--allow-writes` adds VERIFY-tagged user-level tests with cleanup in `finally`). Local suite: `scripts/local_test_slice2.sh`.

| Object | What it is |
|---|---|
| `expense_categories` | Lookup: lead_spend, dialer_software, payroll_spiffs, office, marketing, other. Admin only, audited |
| `expenses` (extended) | Existing rows kept; old free-text categories remapped (Leads -> lead_spend, Software -> dialer_software) and the 4 slice-one seed rows get external_ref seed-s1-01..04; logged as row.update events |
| `revenue_adjustments` | Manual revenue lines not tied to one sale's premium: carrier_bonus, override, chargeback (must be negative: check constraint), other_revenue. Admin only, audited, empty |
| `pl_unpriced_sales` (view) | Sales with no Premier and no board premium (they have no P&L line); count shown on `/pl`. Admin only |
| `pl_line_items` (view) | Every P&L line: line_date, week_start (Sunday), month_start, line_type (revenue / commission / expense), category, category_label, description, source, amount, signed_amount, ref_table, ref_id, agent_name |
| `pl_daily`, `pl_weekly`, `pl_monthly` (views) | Sums of `pl_line_items`: sales_count, line_count, revenue, commission, expenses, net. A drill-down always adds back to its summary row |

Revenue lines per sale: one premium line (`premium_premier`, or `premium_board_claim` while Premier is pending; add-ons are named in the description).
Commission lines per sale: `agent_commission_base` (base rate x premium) and, with a qualifying add-on, `agent_commission_addon_bonus` (the remainder, so the two add up exactly to `commission_estimate`). `commission_config`, `pay_premium` and the attribution lock are unchanged.
The slice-one `daily_pl`/`weekly_pl`/`monthly_pl` views are kept as-is and match the new views while `revenue_adjustments` is empty.
Dashboard: `/pl?period=daily|weekly|monthly` (summary per period) and `/pl/<period>/<YYYY-MM-DD>` (lines grouped by type and category with totals). Admin only.

## Audited event log
- One table, `public.event_log`: `id, occurred_at, event_type, actor_uid (auth.uid()), actor_role (JWT role or DB session user), table_name, row_id, action, before, after, changed_fields, detail`.
- A generic trigger logs every INSERT / UPDATE / DELETE on `agents, contacts, applications, sales, call_metrics, expenses, commission_config` (+ `expense_categories`, `revenue_adjustments` in slice two). No-op updates are not logged.
- **Premium mismatch:** when `premier_premium` and `board_premium` differ by more than $0.01, a `premium_mismatch` event is written (detail: both figures, the diff, agent_of_record, "attribution unchanged", paid on Premier).
- **Immutable:** UPDATE/DELETE/TRUNCATE privileges are revoked from anon, authenticated and service_role, and a trigger raises on any UPDATE, DELETE or TRUNCATE. (The database owner could still drop the trigger; that's a schema change and shows in migrations.)

## Security
- RLS is enabled on every table. `anon` has no table, view or helper-function privileges.
- Agents see their own `agents` row, their own sales (by `agent_of_record`), and only the contacts/applications/call_metrics tied to them. They can't write.
- Admins (`agents.role = 'admin'`) see and write everything. `expenses`, P&L views, `commission_config` and `event_log` are admin-only.
- Agents still get their derived commission through the security-definer `commission_rates()` function without reading the config table.
- `agent_of_record` can't be changed once written (trigger).
- The web app uses only the public anon/publishable key plus the user's session cookie, so every read is under RLS. The service-role key is never used by the app.

## Run it
```bash
# migrations + seed + verification against the live project (needs Postgres network access)
SUPABASE_ENV=/workspace/secrets/supabase.env DB_PASSWORD_FILE=/workspace/secrets/supabase_db_password.txt scripts/apply_remote.sh psql
# or over HTTPS with a Supabase personal access token
SUPABASE_ENV=/workspace/secrets/supabase.env SUPABASE_ACCESS_TOKEN=... scripts/apply_remote.sh api

# test users (admin.test@example.com, agent.test@example.com); passwords go only to OUT (chmod 600)
SUPABASE_ENV=/workspace/secrets/supabase.env OUT=/workspace/secrets/test_users.env scripts/create_test_users.sh

# dashboard
cd web && cp .env.example .env.local   # fill in URL + anon key
npm install && npm run build && npm start
```
`supabase/tests/local_supabase_stub.sql` lets the migrations run on a plain local Postgres for testing. **Never run it against the real project.**

## One-time hub cutover (Paid Lock + Lock Open Items import)
Layout (Kyle 11/01 11:55 AM ET, relayed): `Pay Friday | Agent | Paid Total | System Total | Locked At (ET) | Note`, the hub's
Paid Lock tab, plus the hub's Lock Open Items tab (read-only, from the SAME read). `scripts/hub_cutover.py`:
- `build`: Paid Lock read twice (UNFORMATTED serials + as displayed; both must agree) -> normalized CSV (ISO dates, cents,
  Locked At to the minute in ET; the display hides the time). Lock Open Items -> normalized CSV (kind post_date | unconfirmed),
  plus the hub code's `LOCK_OPEN_SEEDS_` items from a private `--hub-code-seeds` CSV. Writes `snapshot.json` (both shas):
  `sql --snapshot` refuses files from different reads. Real pay data never goes in this public repo (`--out` refuses).
- `check`: rows and sums per payday, Paid vs System variances, duplicates, hub-roster and backend agent-id mapping, ET parsing,
  System Total vs Finalized Paydays, open items by agent. Exit 1 on a hard error.
- `sql --dry-run | --confirm-hub --dry-run-token T`: one SQL Editor paste = one transaction (migration
  `20261101120000_hub_lock_open_items` if not yet in place, SQL Editor only + one DO block). The dry run validates against the
  live state, prints `DRY RUN TOKEN T` (file shas + live-state fingerprint) and raises, so nothing persists. APPLY refuses unless
  T matches the live state now (dry-run-before-confirm, enforced in SQL without writing). Apply: payroll owner login (migration
  applied beforehand) or SQL Editor (postgres break-glass), audited by `payroll.hub_cutover.recorded` + `payroll.hub_cutover.import`.
  Same files again = no-op; another file = refused; refused if this system already locked a payday or submitted one after the
  file's last payday; in-DB re-check of duplicates, Fridays, per-payday counts and sums.
- Roster check (in SQL): every name carrying hub dollars or a still-open item must resolve to a backend agent or
  `agent_name_aliases` row, else DRY RUN BLOCKED (no token) / APPLY refused. `UNKNOWN` at $0 is exempt. Board rows loaded
  before the roster keep a NULL agent id (not back-filled by the cutover).
- Open items: a still-open item (Paid On blank) is exempt from `paid_by_hub`: once Premier confirms, it shows as
  `hub_open_item` in `premier_recon_trueup` and pays ONCE on the next open payday (post dates: commission; unconfirmed:
  commission + spiffs), locked by `premier_lock_payday`. An item with Paid On set was paid by the hub and stays $0.
- Rebuild at the switch: `scripts/hub_cutover_rebuild.sh PKG` (then `TOKEN=T` for the apply). Timing: no live cutover before
  the actual switch; re-export both tabs right before it; until it is recorded, no backend submits for paydays the hub still pays.
  Paid Lock values are frozen after the import; later corrections go through `pay_adjustments`.
- The older `csv_to_recon_sql.py --hub` path is superseded (it does not import open items, and after a cutover none can be added).
- Roster prerequisite: the live dry run stays BLOCKED until the backend roster + `agent_name_aliases` are loaded (planned in
  slice 4a/4c: the LIVE hub Agent Aliases tab plus the hub's code-only defaults).
- Rollback of the migration: `supabase/rollback/hub_lock_open_items_rollback.sql` (SQL Editor; refused once the cutover has been
  applied; otherwise restores the pre-migration schema exactly; run it before `slice3_rollback.sql`).
- Read-only preflight: `supabase/deploy/hub_cutover_preflight.sql`. Tests: `scripts/local_test_hub_cutover.sh [REAL.csv]`
  (fresh local build of this tree; fake fixtures `supabase/tests/fixtures/hub_paid_lock_mock.csv`, `hub_lock_open_mock.csv`).

## Seed data (fake)
3 agents (1 admin, 2 agents), 10 contacts (`@example.com`, 555-01xx phones), 5 applications, 5 sales in the week of Sun 10/25 to Sat 10/31/2026:
one at 38%, one with Wellness4You at 43%, one premium mismatch (board $150 vs Premier $140, paid on $140),
one post-dated with Premier pending (pays Friday 11/13 off the 11/05 billing date), and one today (10/31). Plus call metrics and expenses.

## Not in this slice
ACA (separate table/flag later), retention status (GoHighLevel is a separate system), spiffs/ABS/transfers/clawbacks, the Premier pull (target: daily n8n job against the Nexus dashboard export; manual weekly file is the fallback), CRM seam events, QuickBooks.
