-- ROLLBACK for slice two (line-item P&L). Reverts every slice-two object/column; keeps all slice-one data.
-- ONE transaction: any error rolls the whole thing back. Run as the project owner (SQL Editor) only if slice two must be undone.
-- What it does:
--   1. Refuses to run if revenue_adjustments holds rows, or if any non-seed expense has vendor / external_ref /
--      created_by set or a source other than 'manual' (that data would be lost; export it first).
--   2. Drops the 5 P&L views (pl_unpriced_sales, pl_monthly, pl_weekly, pl_daily, pl_line_items).
--   3. Drops the category FK, then maps expenses.category codes back to free text
--      (lead_spend -> 'Leads', dialer_software -> 'Software', others -> their category label), so the slice-one rows
--      read exactly as before ('Leads' x3, 'Software' x1).
--   4. Deletes ONLY the 20 slice-two FAKE seed lines (source='seed' and external_ref like 'seed-s2-%').
--      The 4 slice-one rows lose their seed-s1-* external_ref with the column. Plain manual expenses are KEPT.
--   5. Drops the added expenses columns (source, vendor, external_ref, created_by, updated_at), their indexes and trigger.
--   6. Drops expense_categories, revenue_adjustments and touch_updated_at().
--   7. Deletes the 3 slice-two versions from supabase_migrations.schema_migrations (slice-one backfill rows stay).
-- Not touched: sales, agents, contacts, applications, call_metrics, commission_config, slice-one views, event_log.
-- event_log is append-only by design: the rollback's own deletes/updates are logged and the slice-two audit rows stay.
begin;

do $$ declare n bigint; begin
  if to_regclass('public.revenue_adjustments') is not null then
    execute 'select count(*) from public.revenue_adjustments' into n;
    if n > 0 then
      raise exception 'revenue_adjustments has % row(s); export them before rolling back slice two', n;
    end if;
  end if;
  -- Any expense that is not one of the 24 seed lines and carries slice-two-only data (vendor, external_ref,
  -- created_by, or a source other than the default 'manual') would lose that data when the columns drop: refuse.
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='expenses' and column_name='external_ref') then
    execute $q$select count(*) from public.expenses
                where not (source = 'seed' and external_ref ~ '^seed-s[12]-[0-9]{2}$')
                  and (vendor is not null or external_ref is not null or created_by is not null or source <> 'manual')$q$ into n;
    if n > 0 then
      raise exception '% non-seed expense row(s) carry vendor/external_ref/created_by/source data; export them before rolling back slice two', n;
    end if;
  end if;
end $$;

drop view if exists public.pl_unpriced_sales;
drop view if exists public.pl_monthly;
drop view if exists public.pl_weekly;
drop view if exists public.pl_daily;
drop view if exists public.pl_line_items;

alter table public.expenses drop constraint if exists expenses_category_fkey;
alter table public.expenses drop constraint if exists expenses_source_check;

do $$ begin
  if to_regclass('public.expense_categories') is not null then
    execute $q$update public.expenses e set category = case e.category
        when 'lead_spend' then 'Leads' when 'dialer_software' then 'Software' else c.label end
      from public.expense_categories c where c.code = e.category$q$;
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='expenses' and column_name='external_ref') then
    execute $q$delete from public.expenses where source = 'seed' and external_ref like 'seed-s2-%'$q$;
  end if;
end $$;

drop trigger if exists expenses_touch_updated_at on public.expenses;
drop index if exists public.expenses_source_external_ref_key;
drop index if exists public.expenses_date_idx;
drop index if exists public.expenses_category_idx;
alter table public.expenses drop column if exists source;
alter table public.expenses drop column if exists vendor;
alter table public.expenses drop column if exists external_ref;
alter table public.expenses drop column if exists created_by;
alter table public.expenses drop column if exists updated_at;
comment on column public.expenses.date is null;

drop table if exists public.revenue_adjustments;   -- its triggers and policy go with it
drop table if exists public.expense_categories;
drop function if exists public.touch_updated_at();

-- Migration history: forget the slice-two versions (slice-one backfill rows stay; they are true).
do $$ begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$delete from supabase_migrations.schema_migrations
                where version in ('20261031200000','20261031200100','20261031200200')$q$;
  end if;
end $$;

commit;
