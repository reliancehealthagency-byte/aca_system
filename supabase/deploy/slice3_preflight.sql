-- Slice three PREFLIGHT, standalone and READ-ONLY (selects only). Run in the SQL Editor before slice3_paste.sql.
-- preflight = PASS            -> safe to run the paste (slice one + two recorded, commission_config 0.38/0.05, no slice-three objects)
--           = ALREADY APPLIED -> slice three is in place and recorded; the paste would be a no-op
--           = FAIL            -> do not run the paste; see the columns
with m as (
  select to_regclass('public.recon_imports') is not null as has_s3,
         (select count(*) from information_schema.columns where table_schema='public' and table_name='sales'
            and column_name in ('premier_member_id','lead_source'))::int as sales_cols,
         case when to_regclass('supabase_migrations.schema_migrations') is null then 0
              else (xpath('/row/c/text()', query_to_xml(
                     'select count(*) as c from supabase_migrations.schema_migrations
                       where version in (''20261031210000'',''20261031210100'',''20261031210200'',''20261031210300'')', false, true, '')))[1]::text::int end as s3_versions,
         case when to_regclass('supabase_migrations.schema_migrations') is null then 0
              else (xpath('/row/c/text()', query_to_xml(
                     'select count(*) as c from supabase_migrations.schema_migrations
                       where version in (''20261031190000'',''20261031190100'',''20261031190200'',''20261031190300'',
                                         ''20261031200000'',''20261031200100'',''20261031200200'')', false, true, '')))[1]::text::int end as prior_versions,
         to_regclass('public.expense_categories') is not null and to_regclass('public.pl_line_items') is not null as has_s2,
         to_regprocedure('public.is_admin()') is not null and to_regprocedure('public.audit_row_change()') is not null as has_security,
         (select string_agg(format('%s/%s', base_rate, addon_bonus_rate), ',') from public.commission_config) as commission_config
)
select case when has_s3 and s3_versions = 4 then 'ALREADY APPLIED'
            when has_s3 or s3_versions > 0 or sales_cols > 0 then 'FAIL'
            when prior_versions = 7 and has_s2 and has_security and commission_config in ('0.3800/0.0500', '0.38/0.05') then 'PASS'
            else 'FAIL' end as preflight,
       prior_versions as slice12_versions_recorded, has_s2 as slice2_present, has_security, commission_config,
       has_s3 as slice3_tables_present, s3_versions as slice3_versions_recorded, sales_cols as slice3_sales_columns_present
  from m;
