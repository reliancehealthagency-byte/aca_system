-- Slice two PREFLIGHT, standalone and READ-ONLY (selects only). Run in the SQL Editor before slice2_paste.sql.
-- preflight = PASS            -> safe to run the paste: expenses are exactly the 4 slice-one rows below
--                                (date, amount, description, category) and no slice-two objects exist
--           = ALREADY APPLIED -> slice two is in place and recorded; the paste would be a no-op
--           = FAIL            -> do not run the paste; see the columns
with expected(date, amount, description, category) as (
  values (date '2026-10-26', 200.00::numeric, 'FAKE seed: lead spend',   'Leads'),
         (date '2026-10-29', 175.00::numeric, 'FAKE seed: lead spend',   'Leads'),
         (date '2026-10-31', 150.00::numeric, 'FAKE seed: lead spend',   'Leads'),
         (date '2026-10-31',  49.00::numeric, 'FAKE seed: subscription', 'Software')
), s as (
  select (select count(*) from public.expenses)::int as n,
         (select count(*) from (select date, amount, description, category from public.expenses except all select * from expected) x)::int as unexpected,
         (select count(*) from (select * from expected except all select date, amount, description, category from public.expenses) x)::int as missing,
         (select coalesce(string_agg(format('%s %s %s %s', date, amount, coalesce(description, 'NULL'), category), '; ' order by date, amount), 'none')
            from public.expenses) as rows_found
), m as (
  select to_regclass('public.expense_categories') is not null as has_s2,
         case when to_regclass('supabase_migrations.schema_migrations') is null then 0
              else (xpath('/row/c/text()', query_to_xml(
                     'select count(*) as c from supabase_migrations.schema_migrations
                       where version in (''20261031200000'',''20261031200100'',''20261031200200'')', false, true, '')))[1]::text::int
         end as versions_recorded
)
select case when m.has_s2 and m.versions_recorded = 3 then 'ALREADY APPLIED'
            when m.has_s2 or m.versions_recorded > 0 then 'FAIL'
            when s.n = 4 and s.unexpected = 0 and s.missing = 0 then 'PASS'
            else 'FAIL' end as preflight,
       s.n as expense_rows, s.unexpected, s.missing,
       m.has_s2 as slice2_tables_present, m.versions_recorded as slice2_versions_recorded, s.rows_found
  from s, m;
