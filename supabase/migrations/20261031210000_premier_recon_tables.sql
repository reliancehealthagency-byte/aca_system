-- Slice three, part 1 of 3: Premier reconciliation staging + config tables.
-- Premier "Member Products" rows and Sales Board "Form Responses 1" rows (rev 3, Kyle 10/31 relayed via Orchestrator):
--   * Client contact details MAY stay (ops is admin-only: Kyle + his co-owner brother). Premier keeps the reconciliation
--     columns plus contact columns (name, phones, emails, city/state/county); gender, company/position and the empty
--     ethnicity/height/weight/disability columns are still dropped by the import script and refused here.
--   * Board: all 42 positions A..AP; only AC (Income, not contact and not needed) arrives blank.
--   * Free text people type (Premier Hold Reason, board K Source): the raw text stays untouched in raw / raw_fields (the
--     raw layer); the typed ops columns (hold_reason, lead_source) carry a normalized copy with phone numbers, emails and
--     the row's client name replaced (recon_scrub_text).
--   * Matching still uses hashes: HMAC-sha256 (salted) of the normalized phone / email; real imports must be salted.
--   * RLS stays admin-only on every table and view; agents see none of it.
-- raw_fields = the kept CSV row in file order, raw = the same keyed by header / column letter; typed columns are parsed
-- from raw by a trigger so the parse rules live in the database and can be re-checked.
-- Attribution is the board / form submitter and is locked once written. Premier's Agent Label is reference only.
-- Rates: base + add-on bonus come ONLY from commission_config (unchanged). Spiff / ABS / ACA amounts and windows live in
-- the single-row recon_pay_config; per-agent exceptions (Kaitlyn 25% flat, Loreidy no spiffs) in agent_pay_rules.
-- Hours are not an input anywhere in this slice: no hours column exists, so hours can never affect pay.
-- Idempotent: every statement can be re-run.

-- ---------- parse helpers (pure, immutable-ish) ----------
create or replace function public.recon_parse_date(t text) returns date
language plpgsql immutable as $$
begin
  if t is null or btrim(t) = '' then return null; end if;
  if btrim(t) !~ '^\d{1,2}/\d{1,2}/\d{4}$' then return null; end if;
  return to_date(btrim(t), 'MM/DD/YYYY');
exception when others then return null;
end $$;

-- Board / Premier timestamps are Eastern wall-clock (MM/DD/YYYY HH24:MI:SS).
create or replace function public.recon_parse_ts_et(t text) returns timestamptz
language plpgsql stable as $$
begin
  if t is null or btrim(t) !~ '^\d{1,2}/\d{1,2}/\d{4} \d{1,2}:\d{2}:\d{2}$' then return null; end if;
  return to_timestamp(btrim(t), 'MM/DD/YYYY HH24:MI:SS')::timestamp at time zone 'America/New_York';
exception when others then return null;
end $$;

create or replace function public.recon_parse_money(t text) returns numeric
language plpgsql immutable as $$
declare s text;
begin
  s := regexp_replace(coalesce(t, ''), '[\s$,]', '', 'g');
  if s = '' or s !~ '^-?\d+(\.\d+)?$' then return null; end if;
  return s::numeric;
end $$;

create or replace function public.recon_yes(t text) returns boolean
language sql immutable as $$ select lower(btrim(coalesce(t, ''))) in ('yes', 'y', 'true') $$;

create or replace function public.recon_digits(t text) returns text
language sql immutable as $$ select nullif(regexp_replace(coalesce(t, ''), '\D', '', 'g'), '') $$;

-- Board column letter for a 0-based index (A..Z, AA..AZ).
create or replace function public.recon_col_letter(i int) returns text
language sql immutable as $$
  select case when i < 26 then chr(65 + i) else chr(64 + i / 26) || chr(65 + i % 26) end $$;

-- ---------- config ----------
create table if not exists public.recon_pay_config (
  id                          boolean primary key default true check (id),
  spiff_cc_asset              numeric(8,2) not null default 20,
  spiff_cc_edge               numeric(8,2) not null default 50,
  spiff_cc_ultra              numeric(8,2) not null default 75,
  spiff_wellness              numeric(8,2) not null default 20,
  abs_spiff_per_item          numeric(8,2) not null default 20,      -- ABS is a flat $ per item, NEVER a percentage
  abs_item_prices             numeric(8,2)[] not null default array[29.98, 34.98],
  aca_flat                    numeric(8,2) not null default 30,
  aca_wrap_rate               numeric(6,4) not null default 0.50,    -- Premier/Neo add-on on an ACA row; never +5%
  product_window_days         int not null default 0,                -- add-on cutoff = Date Booked (+N days; Kyle 10/31: 0) or the post date
  post_date_gap_days          int not null default 1,                -- Premier first billing > Date Booked + N days = post-dated
  rerun_match_days            int not null default 21,
  premier_fee_exclude         text[] not null default array['AnnualMembershipFeefontcolorredonlychargedonyearlyanniversaryfont Fee'],
  premier_one_time_fee_cols   text[] not null default array['Enrollment Fee','EnrollmentProcessingFee Fee','ApplicationFee Fee','AWALifetimeMembership Fee'],
  updated_at                  timestamptz not null default now(),
  note                        text,
  constraint recon_pay_config_abs_flat check (abs_spiff_per_item >= 0 and abs_spiff_per_item < 1000),
  constraint recon_pay_config_abs_prices check (cardinality(abs_item_prices) >= 1)
);
comment on table public.recon_pay_config is
  'Single row. Spiff, ABS, ACA amounts and windows for Premier reconciliation. Commission base/add-on rates are NOT here: they come only from commission_config.';

create table if not exists public.agent_pay_rules (
  agent_name             text primary key,
  base_rate_override     numeric(6,4),   -- null = commission_config.base_rate
  addon_bonus_override   numeric(6,4),   -- null = commission_config.addon_bonus_rate; 0 = no increased tier
  no_spiff               boolean not null default false,
  note                   text,
  updated_at             timestamptz not null default now()
);
comment on table public.agent_pay_rules is 'Per-agent exceptions only. Everyone else uses commission_config.';

-- Spiff cutoffs: the moment Kyle submits payroll for that payday (master-context §5.2 rule 3).
create table if not exists public.payroll_cutoffs (
  payday      date primary key check (extract(dow from payday) = 5),
  cutoff_at   timestamptz not null,
  source      text not null check (source in ('submit', 'provisional')),
  note        text,
  created_at  timestamptz not null default now()
);
comment on table public.payroll_cutoffs is
  'Spiff cutoff per payday = Kyle''s payroll submit. provisional rows (Thu 23:59:59 ET) stand in until the submit is recorded.';

-- ---------- imports + staging ----------
create table if not exists public.recon_imports (
  id            bigint generated always as identity primary key,
  kind          text not null check (kind in ('premier_member_products', 'sales_board')),
  file_name     text not null,
  file_sha256   text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  encoding      text not null,
  line_ending   text not null,
  header        text[] not null,
  row_count     int not null check (row_count >= 0),
  is_mock       boolean not null default false,
  imported_at   timestamptz not null default now(),
  imported_by   uuid default public.audit_actor_uid(),
  note          text,
  hash_scheme   text not null default 'none' check (hash_scheme in ('none', 'sha256', 'hmac-sha256')),
  unique (kind, file_sha256)
);
comment on table public.recon_imports is 'One row per ingested file (sha256 of the raw bytes). Re-importing the same file is refused by the unique key.';
-- rev 3: a board export only counts once it is FINALIZED (recon_finalize_board_import, called by the import script in the
-- same transaction). Finalizing records the export's Timestamp range and refuses a stale export (older max Timestamp
-- than the latest finalized export, or rows that revert a submission to a superseded version). Rows can't be added to a
-- finalized import. Every finalized export is an immutable snapshot (week-to-week diffs: board_export_diffs).
alter table public.recon_imports add column if not exists finalized_at timestamptz;
alter table public.recon_imports add column if not exists min_submitted_at timestamptz;
alter table public.recon_imports add column if not exists max_submitted_at timestamptz;

create table if not exists public.premier_member_products (
  id                    bigint generated always as identity primary key,
  import_id             bigint not null references public.recon_imports(id) on delete restrict,
  row_num               int not null check (row_num >= 1),
  raw_fields            text[] not null,      -- exact CSV fields in file order (decoded from cp1252)
  raw                   jsonb not null,       -- header -> value (all 132 columns)
  member_id             text,                 -- digits only; null = blank (data-quality issue, never paid)
  product_id            text,
  product_label         text,
  product_benefit       text,
  period_label          text,
  agent_label           text,                 -- REFERENCE ONLY, never used for attribution
  phone_sha256          text check (phone_sha256 is null or phone_sha256 ~ '^[0-9a-f]{64}$'),   -- matching (salted hash)
  email_sha256          text check (email_sha256 is null or email_sha256 ~ '^[0-9a-f]{64}$'),
  member_created_date   date,
  product_created_date  date,
  active_date           date,
  first_billing_date    date,
  next_billing_date     date,
  inactive_date         date,
  hold_date             date,
  hold_reason           text,
  paid                  boolean,
  last_payment          int,
  refund_requested      boolean,
  refund_provided       boolean,
  refund_provided_date  date,
  created_at            timestamptz not null default now(),
  unique (import_id, row_num)
);
create index if not exists premier_member_products_member_idx on public.premier_member_products(member_id);
alter table public.premier_member_products add column if not exists first_name text;   -- rev 3: ops contact (admin-only)
alter table public.premier_member_products add column if not exists last_name text;
alter table public.premier_member_products add column if not exists phone1 text;
alter table public.premier_member_products add column if not exists email text;
comment on table public.premier_member_products is
  'Premier Member Products rows, raw fields preserved. Typed columns parsed by trigger. Agent Label is reference only.';

create table if not exists public.board_submissions (
  id                 bigint generated always as identity primary key,
  import_id          bigint not null references public.recon_imports(id) on delete restrict,
  row_num            int not null check (row_num >= 1),
  raw_fields         text[] not null,         -- exact CSV fields A..AP in file order
  raw                jsonb not null,          -- column letter -> value (headers repeat on the board, letters don't)
  submitted_at       timestamptz,             -- col A, Eastern
  deal_type          text,                    -- col R
  line_kind          text,                    -- premier / aca / abs_only (derived)
  member_id          text,                    -- col B digits
  date_booked        date,                    -- col C
  agent_name         text,                    -- LOCKED attribution (form submitter): F, then S, then AP (ACA rows: S, AP, F)
  agent_source_col   text,
  board_premium      numeric(12,2),           -- col G: the agent's claim, never paid
  board_post_date    boolean,                 -- col M
  board_active_date  date,                    -- col E (form future date: never used for pay timing)
  abs_addon          boolean,                 -- col P (Premier rows) / AI (ACA rows)
  abs_member_id      text,                    -- col AJ
  abs_premium        numeric(12,2),           -- col AK
  aca_ffm            text,                    -- col U
  aca_date_booked    date,                    -- col Y
  wrap_member_id     text,                    -- col AG
  wrap_premium       numeric(12,2),           -- col AH (claim)
  increased_answer   text,                    -- col AO
  customer_name      text,                    -- rev 3: ops contact (admin-only): H, else V (ACA client)
  customer_email     text,                    -- I
  customer_phone     text,                    -- J, else AM
  lead_source        text,                    -- K, normalized (recon_scrub_text); raw text in raw->'K'
  agent_id           uuid,                    -- rev 3: roster link for agent_name (agents.id via display name / alias)
  submission_key     text not null,           -- board row identity = col A Timestamp (ET, to the second): YYYYMMDDHH24MISS
  phone_sha256       text check (phone_sha256 is null or phone_sha256 ~ '^[0-9a-f]{64}$'),   -- customer phone (J / AM), hash only
  email_sha256       text check (email_sha256 is null or email_sha256 ~ '^[0-9a-f]{64}$'),   -- customer email (I), hash only
  created_at         timestamptz not null default now(),
  unique (import_id, row_num),
  unique (import_id, submission_key)          -- two rows with one Timestamp in one file = ambiguous: the import is refused
);
create index if not exists board_submissions_key_idx on public.board_submissions(submission_key);
alter table public.board_submissions add column if not exists customer_name text;
alter table public.board_submissions add column if not exists customer_email text;
alter table public.board_submissions add column if not exists customer_phone text;
alter table public.board_submissions add column if not exists lead_source text;
alter table public.board_submissions add column if not exists agent_id uuid;

-- Board name -> roster agent (rev 3, Kyle 10/31: agents are matched on an agent id, not the display name). The board's
-- first + last name resolves to agents.id by agents.display_name, else by an alias row here (hub "Agent Aliases" tab).
create table if not exists public.agent_name_aliases (
  alias       text primary key,                 -- name as typed on the Sales Board
  agent_id    uuid not null references public.agents(id),
  note        text,
  created_at  timestamptz not null default now()
);
create or replace function public.recon_agent_id(name text) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select a.id from public.agents a where lower(a.display_name) = lower(btrim(name))),
                  (select x.agent_id from public.agent_name_aliases x where lower(x.alias) = lower(btrim(name)))) $$;
comment on column public.board_submissions.submission_key is
  'Identity of a form submission across exports (col A Timestamp). Supersede rule: for each submission_key the row from the most recent import (imported_at, then id) is the current version; older versions are kept as evidence and never paid.';
create index if not exists board_submissions_member_idx on public.board_submissions(member_id);
comment on column public.board_submissions.agent_name is 'Attribution = board / form submitter. Locked after insert. Premier Agent Label never changes it.';

-- Snapshot of what has already been logged, so the event logger only writes real changes (re-runs are no-ops).
create table if not exists public.premier_recon_event_state (
  state_key   text primary key,
  state       jsonb not null,
  updated_at  timestamptz not null default now()
);

-- ---------- triggers ----------
-- Header contract (rev 2): every column reconciliation reads must be present by NAME (a count check is not enough), and
-- Premier headers outside the allow-list (client PII) are refused. Board headers are checked by position (letters).
create or replace function public.recon_premier_required_cols() returns text[]
language sql immutable as $$
  select array['Member ID', 'Product ID', 'Product Label', 'Product Benefit', 'Period Label', 'Agent Label',
               'Member Created Date', 'Product Created Date', 'Active Date', 'First Billing Date', 'Next Billing Date',
               'Inactive Date', 'Hold Date', 'Hold Reason', 'Paid', 'Last Payment', 'Refund Requested', 'Refund Provided',
               'Refund Provided Date', 'Product Fee', 'Enrollment Fee', 'EnrollmentProcessingFee Fee', 'ApplicationFee Fee',
               'AWALifetimeMembership Fee'] $$;
create or replace function public.recon_premier_allowed_cols() returns text[]
language sql immutable as $$
  select public.recon_premier_required_cols() || array['Agent ID', 'Agent Code', 'Inactive Reason', 'Product Status',
         'Paytype', 'Refund Requested Date', 'Next Billing Amount', 'Inactive Date Set',
         -- rev 3 (Kyle 10/31): client contact details may stay in ops (admin-only)
         'First Name', 'Last Name', 'Phone 1', 'Phone 1 Ext', 'Phone 2', 'Phone 2 Ext', 'Phone 3', 'Phone 3 Ext',
         'Email', 'Email2', 'Email 3', 'City', 'State', 'Country', 'County', 'Other City', 'Other State'] $$;
create or replace function public.recon_board_expected_cols() returns text[]
language sql immutable as $$   -- live Sales Board A..AP (42); only the named positions are checked, '' = not checked
  select array['Timestamp', 'Member ID', 'Date Booked', '', 'Active Date', 'Agent', 'Premium', 'Customer Name',
               'Customer Email', 'Customer Phone', '', '', 'Post Date', 'Email', '', 'ABS Addon?', '', 'Deal Type', 'Agent',
               '', 'FFM', 'Client Name', '', '', 'Date Booked', '', '', '', 'Income', '', '', 'Premier/Neo Addon?',
               'Premier/Neo Member ID', 'Premier/Neo Premium', 'ABS Addon?', 'ABS Member ID', 'ABS Premium', '',
               'Phone Number', '', 'Increased Comm/Spiff Product?', 'Agent'] $$;
-- Normalized ("ops") copy of a free-text field (rev 3, Kyle 10/31): emails, phone-like digit runs and the row's own client
-- name parts (when known) are replaced. The raw text is kept untouched in raw / raw_fields.
create or replace function public.recon_scrub_text(t text, names text[] default '{}') returns text
language plpgsql immutable as $$
declare r text; n text;
begin
  if t is null or btrim(t) = '' then return null; end if;
  r := regexp_replace(t, '[^[:space:]@<>(),;]+@[^[:space:]@<>(),;]+[.][A-Za-z]{2,}', '[email]', 'g');
  r := regexp_replace(r, '[+(]?[0-9][0-9 ().-]{5,}[0-9]', '[phone]', 'g');
  foreach n in array coalesce(names, '{}') loop
    if n ~ '^[A-Za-z][A-Za-z''-]{2,}$' then
      r := regexp_replace(r, '\m' || n || '\M', '[name]', 'gi');
    end if;
  end loop;
  return r;
end $$;

create or replace function public.recon_import_check() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare missing text[]; extra text[]; exp text[]; bad text[];
begin
  -- finalize fields are written only by recon_finalize_board_import
  new.finalized_at := null; new.min_submitted_at := null; new.max_submitted_at := null;
  -- real data must be matched on SALTED hashes (an unsalted phone hash is reversed in under a second)
  if not new.is_mock and new.hash_scheme <> 'hmac-sha256' then
    raise exception 'import %: real (non-mock) imports must use salted hashes (hash_scheme hmac-sha256, salt in /workspace/secrets/recon_hash_salt.txt); got %', new.file_name, new.hash_scheme;
  end if;
  if new.kind = 'premier_member_products' then
    select array_agg(c) into missing from unnest(public.recon_premier_required_cols()) c where not (c = any (new.header));
    if missing is not null then
      raise exception 'Premier import %: required column(s) missing: %', new.file_name, array_to_string(missing, ', ');
    end if;
    select array_agg(c) into extra from unnest(new.header) c
     where not (c = any (public.recon_premier_allowed_cols())) and c not like '% Fee';
    if extra is not null then
      raise exception 'Premier import %: column(s) outside the ops allow-list (gender / company / ethnicity / height / weight / disability etc. are never stored): %', new.file_name, array_to_string(extra, ', ');
    end if;
  elsif new.kind = 'sales_board' then
    exp := public.recon_board_expected_cols();
    if cardinality(new.header) <> cardinality(exp) then
      raise exception 'Board import %: expected the live Sales Board columns A..AP (%), found % columns', new.file_name, cardinality(exp), cardinality(new.header);
    end if;
    select array_agg(public.recon_col_letter(i - 1) || ' ' || exp[i] || ' (found ' || coalesce(new.header[i], 'NULL') || ')') into bad
      from generate_series(1, cardinality(exp)) i
     where exp[i] <> '' and lower(regexp_replace(btrim(coalesce(new.header[i], '')), '\s+', ' ', 'g')) <> lower(exp[i]);
    if bad is not null then
      raise exception 'Board import %: required column(s) missing or moved: %', new.file_name, array_to_string(bad, '; ');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists recon_imports_check on public.recon_imports;
create trigger recon_imports_check before insert on public.recon_imports
  for each row execute function public.recon_import_check();

create or replace function public.premier_parse_raw() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare h text[]; k text; r jsonb;
begin
  select header into h from public.recon_imports where id = new.import_id and kind = 'premier_member_products';
  if h is null then raise exception 'import % is not a premier_member_products import', new.import_id; end if;
  if cardinality(new.raw_fields) <> cardinality(h) then
    raise exception 'Premier row % has % fields, header has %', new.row_num, cardinality(new.raw_fields), cardinality(h);
  end if;
  new.raw := jsonb_object(h, new.raw_fields);
  r := new.raw;
  new.member_id            := public.recon_digits(r->>'Member ID');
  new.product_id           := nullif(btrim(r->>'Product ID'), '');
  new.product_label        := r->>'Product Label';
  new.product_benefit      := r->>'Product Benefit';
  new.period_label         := r->>'Period Label';
  new.agent_label          := r->>'Agent Label';
  new.member_created_date  := public.recon_parse_date(r->>'Member Created Date');
  new.product_created_date := public.recon_parse_date(r->>'Product Created Date');
  new.active_date          := public.recon_parse_date(r->>'Active Date');
  new.first_billing_date   := public.recon_parse_date(r->>'First Billing Date');
  new.next_billing_date    := public.recon_parse_date(r->>'Next Billing Date');
  new.inactive_date        := public.recon_parse_date(r->>'Inactive Date');
  new.hold_date            := public.recon_parse_date(r->>'Hold Date');
  new.first_name           := nullif(btrim(r->>'First Name'), '');
  new.last_name            := nullif(btrim(r->>'Last Name'), '');
  new.phone1               := nullif(btrim(r->>'Phone 1'), '');
  new.email                := nullif(btrim(r->>'Email'), '');
  -- ops copy is normalized; the raw Hold Reason stays untouched in raw / raw_fields
  new.hold_reason          := public.recon_scrub_text(r->>'Hold Reason', array[new.first_name, new.last_name]);
  new.paid                 := public.recon_yes(r->>'Paid');
  new.last_payment         := coalesce(public.recon_parse_money(r->>'Last Payment'), 0)::int;
  new.refund_requested     := public.recon_yes(r->>'Refund Requested');
  new.refund_provided      := public.recon_yes(r->>'Refund Provided');
  new.refund_provided_date := public.recon_parse_date(r->>'Refund Provided Date');
  return new;
end $$;
drop trigger if exists premier_member_products_parse on public.premier_member_products;
create trigger premier_member_products_parse before insert on public.premier_member_products
  for each row execute function public.premier_parse_raw();

create or replace function public.board_parse_raw() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare h text[]; r jsonb; keys text[]; i int; f text; s text; ap text; aca boolean; k text;
begin
  select header into h from public.recon_imports where id = new.import_id and kind = 'sales_board';
  if h is null then raise exception 'import % is not a sales_board import', new.import_id; end if;
  if exists (select 1 from public.recon_imports where id = new.import_id and finalized_at is not null) then
    raise exception 'board import % is finalized: rows can''t be added to it (import the new export as a new file)', new.import_id;
  end if;
  if cardinality(new.raw_fields) <> cardinality(h) then
    raise exception 'Board row % has % fields, header has %', new.row_num, cardinality(new.raw_fields), cardinality(h);
  end if;
  keys := array(select public.recon_col_letter(g - 1) from generate_series(1, cardinality(h)) g);
  new.raw := jsonb_object(keys, new.raw_fields);
  r := new.raw;
  new.submitted_at      := public.recon_parse_ts_et(r->>'A');
  if new.submitted_at is null then
    raise exception 'board row %: Timestamp (col A) % is missing or not MM/DD/YYYY HH:MI:SS; a row without it cannot be identified across exports', new.row_num, coalesce(r->>'A', 'NULL');
  end if;
  new.submission_key    := to_char(new.submitted_at at time zone 'America/New_York', 'YYYYMMDDHH24MISS');
  -- AC (Income) is not contact data and not needed: it must arrive blank (the import script blanks it)
  if coalesce(btrim(r->>'AC'), '') <> '' then
    raise exception 'board row %: column AC (Income) must be blank; the import script blanks it', new.row_num;
  end if;
  new.customer_name     := coalesce(nullif(btrim(r->>'H'), ''), nullif(btrim(r->>'V'), ''));
  new.customer_email    := nullif(btrim(r->>'I'), '');
  new.customer_phone    := coalesce(nullif(btrim(r->>'J'), ''), nullif(btrim(r->>'AM'), ''));
  new.lead_source       := public.recon_scrub_text(r->>'K', regexp_split_to_array(coalesce(new.customer_name, ''), '\s+'));
  new.deal_type         := nullif(btrim(r->>'R'), '');
  new.member_id         := public.recon_digits(r->>'B');
  new.date_booked       := public.recon_parse_date(r->>'C');
  new.board_active_date := public.recon_parse_date(r->>'E');
  new.board_premium     := public.recon_parse_money(r->>'G');
  new.board_post_date   := public.recon_yes(r->>'M');
  new.aca_ffm           := public.recon_digits(r->>'U');
  new.aca_date_booked   := public.recon_parse_date(r->>'Y');
  new.wrap_member_id    := public.recon_digits(r->>'AG');
  new.wrap_premium      := public.recon_parse_money(r->>'AH');
  new.abs_member_id     := public.recon_digits(r->>'AJ');
  new.abs_premium       := public.recon_parse_money(r->>'AK');
  new.increased_answer  := nullif(btrim(r->>'AO'), '');
  f := nullif(btrim(r->>'F'), ''); s := nullif(btrim(r->>'S'), ''); ap := nullif(btrim(r->>'AP'), '');
  if lower(coalesce(new.deal_type, '')) = 'abs only' then
    new.line_kind := 'abs_only';
  else
    aca := lower(coalesce(new.deal_type, '')) like '%aca%' or lower(coalesce(new.deal_type, '')) = 'yes' or (f is null and s is not null);
    new.line_kind := case when aca then 'aca' else 'premier' end;
  end if;
  if new.line_kind = 'premier' then
    new.agent_name := coalesce(f, s, ap);
    new.agent_source_col := case when f is not null then 'F' when s is not null then 'S' when ap is not null then 'AP' end;
    new.abs_addon := public.recon_yes(r->>'P');
  else
    new.agent_name := coalesce(s, ap, f);
    new.agent_source_col := case when s is not null then 'S' when ap is not null then 'AP' when f is not null then 'F' end;
    new.abs_addon := case when new.line_kind = 'abs_only' then true
                          else public.recon_yes(r->>'AI') or coalesce(new.abs_premium, 0) > 0 end;
  end if;
  new.agent_id := public.recon_agent_id(new.agent_name);
  return new;
end $$;
drop trigger if exists board_submissions_parse on public.board_submissions;
create trigger board_submissions_parse before insert on public.board_submissions
  for each row execute function public.board_parse_raw();

-- Staging rows are evidence: raw fields never change, and board attribution is locked.
create or replace function public.recon_staging_immutable() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception '% rows are immutable snapshots (every export is kept for week-to-week diffs)', tg_table_name;
  end if;
  if tg_table_name = 'board_submissions' and ((to_jsonb(new)->>'agent_name') is distinct from (to_jsonb(old)->>'agent_name')
                                              or (to_jsonb(new)->>'agent_id') is distinct from (to_jsonb(old)->>'agent_id')) then
    raise exception 'board_submissions.agent_name is locked (attribution = board / form submitter; Premier agent is reference only)';
  end if;
  if new.raw_fields is distinct from old.raw_fields or new.raw is distinct from old.raw then
    raise exception '% raw fields are immutable', tg_table_name;
  end if;
  return new;
end $$;
drop trigger if exists premier_member_products_immutable on public.premier_member_products;
create trigger premier_member_products_immutable before update or delete on public.premier_member_products
  for each row execute function public.recon_staging_immutable();
drop trigger if exists board_submissions_immutable on public.board_submissions;
create trigger board_submissions_immutable before update or delete on public.board_submissions
  for each row execute function public.recon_staging_immutable();
-- recon_imports: immutable, except that the finalize step fills finalized_at / min / max ONCE.
create or replace function public.recon_imports_immutable() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'recon_imports rows are immutable (export snapshots)'; end if;
  if old.finalized_at is not null
     or (to_jsonb(new) - 'finalized_at' - 'min_submitted_at' - 'max_submitted_at')
        is distinct from (to_jsonb(old) - 'finalized_at' - 'min_submitted_at' - 'max_submitted_at') then
    raise exception 'recon_imports row % is immutable (only the one-time finalize step may complete it)', old.id;
  end if;
  return new;
end $$;
drop trigger if exists recon_imports_immutable on public.recon_imports;
create trigger recon_imports_immutable before update or delete on public.recon_imports
  for each row execute function public.recon_imports_immutable();

-- Audit (event_log) on config + import header tables. Staging rows are covered by their import's audit row
-- (one event per file, not one per CSV line) and are immutable.
do $$
declare t text;
begin
  foreach t in array array['recon_pay_config','agent_pay_rules','payroll_cutoffs','recon_imports'] loop
    execute format('drop trigger if exists audit_%1$s on public.%1$I', t);
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_row_change()', t);
  end loop;
end $$;

-- Config rows (after the audit triggers, so their creation is logged).
insert into public.recon_pay_config (id, note)
values (true, 'Kyle 10/14-10/31 via payroll-breakdown.md §1.2-1.4, §7; master-context §5.2. ABS $20/item at $29.98 or $34.98 (v19.13 mixed count). Add-on cutoff = Date Booked / post date (Kyle 10/31 as recorded by Payroll; replaces the hub 3-day window).')
on conflict (id) do nothing;
insert into public.agent_pay_rules (agent_name, base_rate_override, addon_bonus_override, no_spiff, note) values
  ('Kaitlyn Romine',   0.25, 0.00, false, 'Premier 25% flat, no increased tier; ACA wrap still 50% (Rates tab, Kyle 10/14)'),
  ('Loreidy Martinez', null, null, true,  'No spiffs (ConsultCare, Wellness, ABS) and no transfer pay (Kyle 10/15, 10/20, 10/29)')
on conflict (agent_name) do nothing;

-- ---------- product -> add-on mapping (Payroll owns this list; case-insensitive regex, configurable) ----------
-- Replaces, FOR RECONCILIATION, slice one's case-sensitive LIKE list in commission_config.qualifying_addon_patterns:
-- against Premier's real labels that list only catches 'Wellness4You' and 'ChampionCare' (checked in verify_slice3 T3).
-- commission_config itself is unchanged and still supplies the rates (base_rate, addon_bonus_rate).
create table if not exists public.premier_addon_map (
  id               bigint generated always as identity primary key,
  source           text not null check (source in ('premier_label', 'premier_benefit', 'board_answer')),
  pattern          text not null,             -- POSIX regex, matched case-insensitively (~*)
  addon_key        text not null check (addon_key in ('consultcare', 'wellness', 'add_type', 'champion')),
  tier             text check (tier in ('asset', 'edge', 'ultra')),
  qualifies_bonus  boolean not null default true,   -- true = triggers commission_config.addon_bonus_rate (+5%)
  status           text not null default 'approved' check (status in ('approved', 'proposed')),  -- proposed = awaiting Kyle's OK
  active           boolean not null default true,
  owner            text not null default 'Payroll',
  note             text,
  updated_at       timestamptz not null default now(),
  unique (source, pattern)
);
comment on table public.premier_addon_map is
  'Payroll-owned, case-insensitive product -> add-on mapping. premier_benefit rows give the ConsultCare tier. Seeded from payroll-breakdown.md §7.1/§7.2 (INCREASED_KEYWORDS, CONSULTCARE_KEYWORD, WELLNESS_KEYWORDS, board AO options).';

-- ---------- policy-count validation ----------
create table if not exists public.policy_count_claims (
  id            bigint generated always as identity primary key,
  agent_name    text not null,
  week_start    date not null check (extract(dow from week_start) = 0),   -- Sunday
  typed_count   numeric(6,1) not null check (typed_count >= 0),
  source        text not null default 'manual',
  note          text,
  created_at    timestamptz not null default now(),
  unique (agent_name, week_start, source)
);
comment on table public.policy_count_claims is 'Policy counts as typed by/for the agent, compared with board- and Premier-derived counts (half policy < threshold = 0.5).';

-- ---------- true-up / paid lock / adjustments ----------
-- Stages per pay line: board_estimate -> premier_corrected -> payroll_actual. Locks are written once (immutable) at payroll
-- submit; adjustments (incl. Cancel Commission) are separate rows keyed by the stable line_key, so a re-run of the
-- reconciliation never overwrites a locked or adjusted amount.
-- rev 3: ONE lock row per (line_key, component), across ALL paydays (unique constraint). A component whose due payday
-- moves later (a missed spiff, a Premier billing-date change, a late cutoff) can therefore never be locked / paid twice.
create table if not exists public.pay_line_locks (
  id            bigint generated always as identity primary key,
  line_key      text not null,              -- stable: <submission_key = board Timestamp yyyymmddhh24miss>-<P|PADD|ACA|ABS>
  component     text not null check (component in ('commission', 'claimed_spiffs', 'missed_spiffs')),
  payday        date not null check (extract(dow from payday) = 5),
  agent_name    text not null,
  agent_id      uuid,                       -- roster link (rev 3)
  stage         text not null default 'payroll_actual' check (stage = 'payroll_actual'),
  amount        numeric(12,2) not null,     -- what payroll paid for this component on this payday
  board_estimate     numeric(12,2),         -- snapshot of the line's stage-1 amount at lock time
  premier_corrected  numeric(12,2),         -- snapshot of the line's stage-2 amount at lock time
  locked_at     timestamptz not null default now(),
  locked_by     uuid default public.audit_actor_uid(),
  note          text,
  constraint pay_line_locks_once unique (line_key, component)
);
create index if not exists pay_line_locks_payday_idx on public.pay_line_locks(payday);

-- PB Q12 (rev 3): the next-open-payday rule moves with every new submit, so a missed spiff's payday is ANCHORED the first
-- time it is detected (before a submit is recorded, at every lock and every event-logger run) and never moves after that.
create table if not exists public.missed_spiff_anchors (
  line_key     text primary key,
  payday       date not null check (extract(dow from payday) = 5),
  amount       numeric(12,2) not null,     -- missed amount when first detected (reference)
  mode         text not null check (mode = 'next_open_payday'),
  detected_at  timestamptz not null default now(),
  note         text
);
comment on table public.missed_spiff_anchors is
  'First-detection payday of each missed (Premier-only) spiff under missed_spiff_payday = next_open_payday. Immutable.';

-- Closed weeks (rev 3, Kyle 10/31 relayed via Orchestrator): once a week's payroll is submitted (or the hub cutover covers
-- it), its board data is never revised. Each submission of that week is frozen to the version current at that moment;
-- later exports that change or drop it only raise a flag (closed_week_change), never a pay change.
-- Week of a submission = the Sun-Sat week of its Timestamp; its payday = the Friday after (recon_friday_after_week).
create table if not exists public.board_week_freezes (
  submission_key  text primary key,
  board_id        bigint not null references public.board_submissions(id),
  week_payday     date not null check (extract(dow from week_payday) = 5),
  reason          text not null check (reason in ('payroll_submit', 'hub_cutover')),
  frozen_at       timestamptz not null default now()
);

-- Hub cutover (rev 3, Kyle 10/31): importing the hub's export starts this system's clock. ONE row, ever: owner-only (or the
-- SQL Editor while no owner is set), audited, immutable (no admin can reset or move it). Every payday in the file is
-- paid_by_hub. Import shape = the hub "Paid Lock" tab: Pay Friday, Agent, Paid Total, System Total, Locked At (ET), Note.
create table if not exists public.hub_paid_lock (
  id            bigint generated always as identity primary key,
  file_sha256   text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  row_num       int not null check (row_num >= 1),
  payday        date not null check (extract(dow from payday) = 5),
  agent_name    text not null,
  paid_total    numeric(12,2) not null,
  system_total  numeric(12,2),
  locked_at     timestamptz,
  note          text,
  unique (file_sha256, row_num)
);
create table if not exists public.hub_cutover (
  id              boolean primary key default true check (id),
  file_name       text not null,
  file_sha256     text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  last_hub_payday date,                      -- set by the trigger: max(Pay Friday) of the imported file
  paydays         date[],                    -- every payday the file covers (all paid_by_hub)
  row_count       int,
  recorded_at     timestamptz not null default now(),
  recorded_by     uuid default public.audit_actor_uid(),
  recorded_role   text default public.audit_actor_role(),
  note            text
);
comment on table public.hub_cutover is
  'One-time hub cutover: the hub''s Paid Lock export. last_hub_payday and earlier = paid by the hub, never payable here. Immutable.';
create table if not exists public.pay_adjustments (
  id            bigint generated always as identity primary key,
  line_key      text,                       -- null = agent-level adjustment
  member_id     text,                       -- reference (e.g. the hub Manual Adjustments "Member ID")
  agent_name    text not null,
  payday        date not null check (extract(dow from payday) = 5),
  kind          text not null check (kind in ('cancel_commission', 'clawback_approved', 'true_up', 'manual')),
  component     text not null default 'commission' check (component in ('commission', 'spiff', 'other')),
  amount        numeric(12,2) not null check (amount <> 0),
  reason        text not null check (btrim(reason) <> ''),
  created_at    timestamptz not null default now(),
  created_by    uuid default public.audit_actor_uid(),
  entered_by    text,                       -- who decided it (e.g. 'Kyle'); exceptions are Kyle's manual adjustments only
  covers        text check (covers is null or covers ~* '^(pay|reverse|dup|claw) ((spiff|comm):\S+|xfer)$'),
                                            -- hub "Covers" (col H): this row stands in for a system item so it is never paid twice
  external_ref  text unique,                -- idempotent imports (e.g. 'mock-madj-<sha>-<row>')
  agent_id      uuid references public.agents(id),   -- rev 3: stable link for the agent's own view (resolved server-side)
  constraint pay_adjustments_cancel_negative check (kind <> 'cancel_commission' or (amount < 0 and line_key is not null and component = 'commission'))
);
create index if not exists pay_adjustments_line_idx on public.pay_adjustments(line_key);
-- PB §1.8 / §4.2 fields: agent-safe note = reason; Kyle-only internal_note (never broadcast); reason_code.
-- entered_by / entered_by_uid are set SERVER-SIDE from auth.uid() (any value the client sends is overwritten);
-- source_entered_by keeps the "Entered By" text of an imported hub row as reference only.
alter table public.pay_adjustments add column if not exists agent_id uuid references public.agents(id);
alter table public.pay_adjustments add column if not exists entered_by_uid uuid;
alter table public.pay_adjustments add column if not exists source_entered_by text;
alter table public.pay_adjustments add column if not exists internal_note text;
alter table public.pay_adjustments add column if not exists reason_code text
  check (reason_code is null or reason_code in ('addon_exception', 'base_reduction', 'correction', 'other'));
-- PB §1.8 "Locked paydays": an adjustment on a submitted (locked) payday is refused; use the next open payday.
create or replace function public.pay_adjustment_open_payday() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); rl text := public.audit_actor_role(); owner uuid; srv text;
begin
  -- "Kyle-only": a signed-in user may record an adjustment only if they ARE recon_pay_config.payroll_owner_user_id.
  -- NULL owner = nobody can (Kyle's auth user id is set by Kyle; it is never guessed). Server roles (SQL Editor owner,
  -- service_role: imports run by Kyle) are stamped 'server:<role>'.
  -- Kyle 10/31: the admin key (service_role) never records adjustments, signed-in user claim or not.
  if rl = 'service_role' or current_user = 'service_role' then
    raise exception 'pay adjustments: the service_role (admin key) path is refused; the payroll owner records adjustments (postgres SQL Editor = audited break-glass)';
  end if;
  if uid is null and rl in ('postgres', 'supabase_admin') then
    -- rev 3 (Kyle 10/31 default, still configurable): service_role is refused; the SQL Editor (postgres) is an audited
    -- break-glass path (entered_by 'break-glass:postgres', event payroll.adjustment.break_glass); 'off' refuses both.
    srv := (select adjustment_server_path from public.recon_pay_config where id);
    if rl = 'service_role' or srv = 'off' then
      raise exception 'pay adjustments: the % path is refused (recon_pay_config.adjustment_server_path = %); the payroll owner records adjustments', rl, srv;
    end if;
    new.entered_by := 'break-glass:' || rl;
  else
    select payroll_owner_user_id into owner from public.recon_pay_config where id;
    if owner is null or uid is distinct from owner then
      raise exception 'only the payroll owner (recon_pay_config.payroll_owner_user_id%) may record pay adjustments',
        case when owner is null then ', not set yet' else '' end;
    end if;
    new.entered_by := coalesce((select a.display_name from public.agents a where a.user_id = uid limit 1), uid::text);
  end if;
  new.entered_by_uid := uid;
  new.created_by := uid;
  -- agent link (rev 3): an explicit agent_id must exist and match agent_name; else resolved from the roster by name
  -- (case-insensitive). Unresolved = NULL: the agent can't see it in my_pay_adjustments() until Kyle fixes the name.
  if new.agent_id is not null then
    if not exists (select 1 from public.agents a where a.id = new.agent_id and lower(a.display_name) = lower(new.agent_name)) then
      raise exception 'pay adjustment: agent_id % does not match agent_name %', new.agent_id, new.agent_name;
    end if;
  else
    new.agent_id := (select a.id from public.agents a where lower(a.display_name) = lower(btrim(new.agent_name)));
  end if;
  if exists (select 1 from public.pay_line_locks where payday = new.payday) then
    raise exception 'payday % is locked (payroll submitted): enter the adjustment on the next open payday', new.payday;
  end if;
  return new;
end $$;

create or replace function public.pay_lock_immutable() returns trigger
language plpgsql as $$
begin
  raise exception '% rows are immutable once written: add a pay_adjustments row instead', tg_table_name;
end $$;
drop trigger if exists pay_line_locks_immutable on public.pay_line_locks;
create trigger pay_line_locks_immutable before update or delete on public.pay_line_locks
  for each row execute function public.pay_lock_immutable();
drop trigger if exists missed_spiff_anchors_immutable on public.missed_spiff_anchors;
create trigger missed_spiff_anchors_immutable before update or delete on public.missed_spiff_anchors
  for each row execute function public.pay_lock_immutable();
drop trigger if exists board_week_freezes_immutable on public.board_week_freezes;
create trigger board_week_freezes_immutable before update or delete on public.board_week_freezes
  for each row execute function public.pay_lock_immutable();
drop trigger if exists hub_paid_lock_immutable on public.hub_paid_lock;
create trigger hub_paid_lock_immutable before update or delete on public.hub_paid_lock
  for each row execute function public.pay_lock_immutable();
drop trigger if exists hub_cutover_immutable on public.hub_cutover;
create trigger hub_cutover_immutable before update or delete on public.hub_cutover
  for each row execute function public.pay_lock_immutable();
drop trigger if exists pay_adjustments_open_payday on public.pay_adjustments;
create trigger pay_adjustments_open_payday before insert on public.pay_adjustments
  for each row execute function public.pay_adjustment_open_payday();
drop trigger if exists pay_adjustments_immutable on public.pay_adjustments;
create trigger pay_adjustments_immutable before update or delete on public.pay_adjustments
  for each row execute function public.pay_lock_immutable();

do $$
declare t text;
begin
  foreach t in array array['premier_addon_map','policy_count_claims','pay_line_locks','pay_adjustments','missed_spiff_anchors',
                           'board_week_freezes','hub_paid_lock','hub_cutover','agent_name_aliases'] loop
    execute format('drop trigger if exists audit_%1$s on public.%1$I', t);
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_row_change()', t);
  end loop;
end $$;

-- Half policy + policy-count thresholds live with the other recon settings.
alter table public.recon_pay_config add column if not exists half_policy_threshold numeric(12,2) not null default 200;
alter table public.recon_pay_config add column if not exists half_policy_value numeric(3,1) not null default 0.5;
-- Decisions still OPEN with Kyle: configurable, defaulting to "pending" (flagged, never guessed).
--   one_time_fee_policy (S18 / README OPEN): pending_kyle = line OPEN with both readings; exclude / include = pay on
--     recurring fees only / recurring + one-time fees (Enrollment, Application, Processing, AWA Lifetime).
--   post_date_source (PB Q11): which field is the "post date" for the add-on cutoff and pay week on a post-dated deal.
--     premier_fbd_else_board_active (default, provisional) | board_active_only | premier_fbd_only; status stays
--     'pending_kyle' until Kyle answers (shown on every line via addon_cutoff_source).
alter table public.recon_pay_config add column if not exists one_time_fee_policy text not null default 'pending_kyle'
  check (one_time_fee_policy in ('pending_kyle', 'exclude', 'include'));
alter table public.recon_pay_config add column if not exists post_date_source text not null default 'premier_fbd_else_board_active'
  check (post_date_source in ('premier_fbd_else_board_active', 'board_active_only', 'premier_fbd_only'));
-- Q11 RESOLVED (Kyle 10/31 relayed via Orchestrator): Premier First Billing Date, falling back to the board Active Date.
alter table public.recon_pay_config add column if not exists post_date_source_status text not null default 'confirmed'
  check (post_date_source_status in ('pending_kyle', 'confirmed'));
-- rev 2 (Orchestrator review):
--   payroll_owner_user_id: the ONE auth user allowed to record pay adjustments ("Kyle-only"). NULL = nobody. Kyle sets it.
--   missed_spiff_payday (PB Q12, confirmed by Kyle 10/31): next_open_payday (default) = a spiff found only in Premier (board did not
--     claim it) whose booked cycle is already submitted pays on the first payday after the latest submitted one;
--     booked_cycle = it stays in its Date Booked cycle.
alter table public.recon_pay_config add column if not exists payroll_owner_user_id uuid;
alter table public.recon_pay_config add column if not exists missed_spiff_payday text not null default 'next_open_payday'
  check (missed_spiff_payday in ('next_open_payday', 'booked_cycle'));
alter table public.recon_pay_config add column if not exists missed_spiff_payday_status text not null default 'confirmed'
  check (missed_spiff_payday_status in ('pending_kyle', 'confirmed'));   -- Kyle 10/31 relayed via Orchestrator: next open payday, anchored
-- rev 3: adjustment_server_path (pending Kyle; default per Kyle 10/31): who besides the payroll owner may insert a pay
--   adjustment with no signed-in user. postgres_break_glass (default) = only the SQL Editor (postgres), stamped and logged
--   as break-glass; off = nobody. service_role is always refused. Guarded like payroll_owner_user_id.
--   (cutover_date was removed in rev 3: the hub cutover import, table hub_cutover, starts the clock.)
alter table public.recon_pay_config add column if not exists adjustment_server_path text not null default 'postgres_break_glass'
  check (adjustment_server_path in ('postgres_break_glass', 'off'));

insert into public.premier_addon_map (source, pattern, addon_key, tier, qualifies_bonus, note, status) values
  ('premier_label',   'consult\s*care',                 'consultcare', null,    true, 'CONSULTCARE_KEYWORD; real label "AWA ConsultCare AEU"', 'approved'),
  ('premier_benefit', '^\s*asset',                      'consultcare', 'asset', true, 'Product Benefit "Asset - Member" -> $20', 'approved'),
  ('premier_benefit', '^\s*edge',                       'consultcare', 'edge',  true, 'Product Benefit "Edge - Member " -> $50', 'approved'),
  ('premier_benefit', '^\s*ultra',                      'consultcare', 'ultra', true, 'Product Benefit "Ultra - Member" -> $75', 'approved'),
  ('premier_label',   'wellness\s*4\s*(you|u)\M',       'wellness',    null,    true, 'WELLNESS_KEYWORDS Wellness4You;Wellness4U -> $20', 'approved'),
  ('premier_label',   'ad\s*&\s*d',                     'add_type',    null,    true, 'INCREASED_KEYWORDS AD&D; real labels "AWA SecureElite AME-AD&D", "HD SecureShield CI-AME-AD&D"', 'approved'),
  ('premier_label',   '(^|[^a-z])add([^a-z]|$)',        'add_type',    null,    true, 'Whole word ADD, e.g. "HD ProtectLife ADD": APPROVED (Kyle 10/31 relayed via Orchestrator; payroll-breakdown §6.3 Q13)', 'approved'),
  ('premier_label',   'champion\s*care',                'champion',    null,    true, 'ChampionCare / Champion Care kept as trigger (Kyle 10/29); no spiff', 'approved'),
  ('board_answer',    'consult\s*care.*asset',          'consultcare', 'asset', true, 'AO "Consult Care - Asset"', 'approved'),
  ('board_answer',    'consult\s*care.*edge',           'consultcare', 'edge',  true, 'AO "Consult Care - Edge"', 'approved'),
  ('board_answer',    'consult\s*care.*ultra',          'consultcare', 'ultra', true, 'AO "Consult Care - Ultra"', 'approved'),
  ('board_answer',    'wellness',                       'wellness',    null,    true, 'AO "Wellness4You"', 'approved'),
  ('board_answer',    'any\s*add\s*type',               'add_type',    null,    true, 'AO "Any ADD type product" (covers AD&D and Champion)', 'approved')
on conflict (source, pattern) do nothing;

-- ---------- sales (slice one): Premier member ID + lead source, nullable, non-breaking ----------
-- Where the member ID comes from (form, CRM, Premier) is OPEN with Kyle: nothing fills it yet; missing = flagged.
alter table public.sales add column if not exists premier_member_id text
  check (premier_member_id is null or premier_member_id ~ '^\d{6,12}$');
alter table public.sales add column if not exists lead_source text;
comment on column public.sales.premier_member_id is 'Premier member ID. Source OPEN with Kyle (do not guess). NULL = flagged in sales_missing_member_id.';
comment on column public.sales.lead_source is 'Lead source as typed on the form (board col K / AL). Display only, never pay.';
