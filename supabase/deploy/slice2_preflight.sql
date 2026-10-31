-- Slice two PREFLIGHT, standalone and READ-ONLY (selects only). Run in the SQL Editor before slice2_paste.sql.
-- preflight = PASS            -> safe to run the paste (expenses are exactly Leads x3 + Software x1, no slice-two objects)
--           = ALREADY APPLIED -> slice two is in place and recorded; the paste would be a no-op
--           = FAIL            -> do not run the paste; see detail
with s as (
  select count(*)::int as n,
         count(*) filter (where category = 'Leads')::int    as leads,
         count(*) filter (where category = 'Software')::int as software,
         coalesce(string_agg(category, ', ' order by category), 'none') as categories
    from public.expenses
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
            when s.n = 4 and s.leads = 3 and s.software = 1 then 'PASS'
            else 'FAIL' end as preflight,
       s.n as expense_rows, s.leads, s.software, s.categories,
       m.has_s2 as slice2_tables_present, m.versions_recorded as slice2_versions_recorded
  from s, m;
