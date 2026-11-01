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
