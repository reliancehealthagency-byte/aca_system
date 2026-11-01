-- Slice three PREFLIGHT, standalone and READ-ONLY (selects only). Run in the SQL Editor before slice3_paste.sql.
-- Two result sets: (1) the preflight verdict; (2) the rev-4 dependency check for retiring slice two's P&L views.
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
                       where version in (''20261031210000'',''20261031210100'',''20261031210200'',''20261031210300'',''20261031210400'')', false, true, '')))[1]::text::int end as s3_versions,
         case when to_regclass('supabase_migrations.schema_migrations') is null then 0
              else (xpath('/row/c/text()', query_to_xml(
                     'select count(*) as c from supabase_migrations.schema_migrations
                       where version in (''20261031190000'',''20261031190100'',''20261031190200'',''20261031190300'',
                                         ''20261031200000'',''20261031200100'',''20261031200200'')', false, true, '')))[1]::text::int end as prior_versions,
         to_regclass('public.expense_categories') is not null and to_regclass('public.pl_line_items') is not null as has_s2,
         to_regprocedure('public.is_admin()') is not null and to_regprocedure('public.audit_row_change()') is not null as has_security,
         (select string_agg(format('%s/%s', base_rate, addon_bonus_rate), ',') from public.commission_config) as commission_config
)
select case when has_s3 and s3_versions = 5 then 'ALREADY APPLIED'
            when has_s3 or s3_versions > 0 or sales_cols > 0 then 'FAIL'
            when prior_versions = 7 and has_s2 and has_security and commission_config in ('0.3800/0.0500', '0.38/0.05') then 'PASS'
            else 'FAIL' end as preflight,
       prior_versions as slice12_versions_recorded, has_s2 as slice2_present, has_security, commission_config,
       has_s3 as slice3_tables_present, s3_versions as slice3_versions_recorded, sales_cols as slice3_sales_columns_present
  from m;

-- Slice three rev 4: READ-ONLY dependency check for retiring slice two's P&L views (Kyle directly 10/31 7:35 PM ET).
-- Lists everything in the database that would break when pl_line_items, pl_daily, pl_weekly, pl_monthly and
-- pl_unpriced_sales are dropped. Expected result: only the 'grant' rows (the views' own grants, which go with them) and
-- 'internal' rows among the five themselves. Any 'view', 'view_text', 'function' or 'policy' row = STOP.
with five(n) as (values ('pl_line_items'), ('pl_daily'), ('pl_weekly'), ('pl_monthly'), ('pl_unpriced_sales')),
pat as (select '\mpl_(line_items|daily|weekly|monthly|unpriced_sales)\M'::text as re)
select kind, object, detail from (
  select case when v.relname in (select n from five) then 'internal' else 'view' end as kind,
         v.relname::text as object, 'depends on ' || s.relname as detail
    from pg_depend d
    join pg_rewrite r on r.oid = d.objid and d.classid = 'pg_rewrite'::regclass
    join pg_class v on v.oid = r.ev_class
    join pg_class s on s.oid = d.refobjid and d.refclassid = 'pg_class'::regclass
   where s.relnamespace = 'public'::regnamespace and s.relname in (select n from five) and v.oid <> s.oid
  union
  select 'view_text', schemaname || '.' || viewname, 'definition names a retired view'
    from pg_views, pat
   where schemaname not in ('pg_catalog', 'information_schema') and viewname not in (select n from five)
     and definition ~ pat.re
  union
  select 'function', p.oid::regprocedure::text, 'body names a retired view'
    from pg_proc p, pat
   where p.pronamespace not in ('pg_catalog'::regnamespace, 'information_schema'::regnamespace) and p.prosrc ~ pat.re
  union
  select 'policy', schemaname || '.' || tablename || '.' || policyname, 'policy names a retired view'
    from pg_policies, pat
   where coalesce(qual, '') || coalesce(with_check, '') ~ pat.re
  union
  select 'grant', c.relname::text, coalesce(array_to_string(c.relacl, ' '), '(default)') || ' owner=' || pg_get_userbyid(c.relowner)
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname in (select n from five)
) x
order by case kind when 'view' then 1 when 'view_text' then 2 when 'function' then 3 when 'policy' then 4 when 'internal' then 5 else 6 end, object, detail;
