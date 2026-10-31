-- Slice two: line-item P&L, part 1 of 3 (tables).
-- Non-destructive: extends the slice-one expenses table in place (existing rows kept; category values remapped
-- to lookup codes, which the audit trigger logs as row.update events with before/after).
-- Not touched: commission_config, pay_premium, attribution lock, event_log, Premier/Convoso (no integrations here).
-- Idempotent: safe to re-run.

-- Expense categories: one lookup table, admin-maintained. expenses.category must be one of these codes.
create table if not exists public.expense_categories (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[a-z][a-z0-9_]*$'),
  label       text not null,
  sort_order  integer not null default 100,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
comment on table public.expense_categories is 'Expense category lookup (admin only). expenses.category references code.';
-- Audit from the first row (same generic trigger as slice one).
drop trigger if exists audit_expense_categories on public.expense_categories;
create trigger audit_expense_categories after insert or update or delete on public.expense_categories
  for each row execute function public.audit_row_change();

insert into public.expense_categories (code, label, sort_order) values
  ('lead_spend',      'Lead spend',        10),
  ('dialer_software', 'Dialer / software', 20),
  ('payroll_spiffs',  'Payroll / spiffs',  30),
  ('office',          'Office',            40),
  ('marketing',       'Marketing',         50),
  ('other',           'Other',             90)
on conflict (code) do nothing;

-- Extend expenses. Slice one already has: id, category, amount (>= 0), date, description, created_at.
-- "date" stays the expense date (renaming it would break the slice-one P&L views).
alter table public.expenses add column if not exists source       text;
alter table public.expenses add column if not exists vendor       text;
alter table public.expenses add column if not exists external_ref text;   -- e.g. invoice # or import row key; idempotent seeds/imports
alter table public.expenses add column if not exists created_by   uuid default auth.uid();
alter table public.expenses add column if not exists updated_at   timestamptz not null default now();

-- Backfill source on existing rows (slice-one seed rows say "FAKE seed").
update public.expenses set source = case when description ilike 'FAKE seed%' then 'seed' else 'manual' end
 where source is null;
alter table public.expenses alter column source set default 'manual';
alter table public.expenses alter column source set not null;

-- Remap free-text categories to lookup codes. Unknown values go to 'other' with the old text kept in description.
update public.expenses set category = case lower(trim(category))
    when 'leads' then 'lead_spend' when 'lead spend' then 'lead_spend' when 'lead_spend' then 'lead_spend'
    when 'software' then 'dialer_software' when 'dialer' then 'dialer_software' when 'dialer_software' then 'dialer_software'
    when 'payroll' then 'payroll_spiffs' when 'spiffs' then 'payroll_spiffs' when 'payroll_spiffs' then 'payroll_spiffs'
    when 'office' then 'office' when 'marketing' then 'marketing' when 'other' then 'other'
    else 'other' end,
  description = case when lower(trim(category)) in ('leads','lead spend','lead_spend','software','dialer','dialer_software',
                       'payroll','spiffs','payroll_spiffs','office','marketing','other')
                     then description
                     else concat_ws(' ', '[was category: ' || category || ']', description) end
 where category not in (select code from public.expense_categories);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'expenses_category_fkey' and conrelid = 'public.expenses'::regclass) then
    alter table public.expenses add constraint expenses_category_fkey
      foreign key (category) references public.expense_categories(code) on update cascade on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'expenses_source_check' and conrelid = 'public.expenses'::regclass) then
    alter table public.expenses add constraint expenses_source_check
      check (source in ('manual','seed','csv_import','recurring','integration'));
  end if;
end $$;
create unique index if not exists expenses_source_external_ref_key on public.expenses(source, external_ref)
  where external_ref is not null;
create index if not exists expenses_date_idx on public.expenses(date);
create index if not exists expenses_category_idx on public.expenses(category);
comment on column public.expenses.date is 'Expense date (the P&L day this line lands on).';
comment on column public.expenses.source is 'Where the line came from: manual, seed, csv_import, recurring, integration.';

-- Revenue adjustments: revenue lines that are not a single sale's premium (placeholders until the
-- 42% vs 38/43% revenue question is answered). Signed: chargebacks/clawbacks are negative.
create table if not exists public.revenue_adjustments (
  id            uuid primary key default gen_random_uuid(),
  date          date not null,
  category      text not null check (category in ('carrier_bonus','override','chargeback','other_revenue')),
  amount        numeric(12,2) not null check (amount <> 0),
  description   text,
  source        text not null default 'manual' check (source in ('manual','seed','csv_import','recurring','integration')),
  sale_id       uuid references public.sales(id) on delete restrict,   -- optional link to the sale it adjusts
  external_ref  text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.revenue_adjustments is
  'Manual revenue lines (carrier bonus, override, chargeback = negative, other). Admin only. Empty until used.';
create unique index if not exists revenue_adjustments_source_external_ref_key
  on public.revenue_adjustments(source, external_ref) where external_ref is not null;
create index if not exists revenue_adjustments_date_idx on public.revenue_adjustments(date);

-- updated_at maintenance
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists expenses_touch_updated_at on public.expenses;
create trigger expenses_touch_updated_at before update on public.expenses
  for each row execute function public.touch_updated_at();
drop trigger if exists revenue_adjustments_touch_updated_at on public.revenue_adjustments;
create trigger revenue_adjustments_touch_updated_at before update on public.revenue_adjustments
  for each row execute function public.touch_updated_at();

-- Same generic audit trigger on revenue_adjustments (expenses already has audit_expenses; expense_categories above).
drop trigger if exists audit_revenue_adjustments on public.revenue_adjustments;
create trigger audit_revenue_adjustments after insert or update or delete on public.revenue_adjustments
  for each row execute function public.audit_row_change();
