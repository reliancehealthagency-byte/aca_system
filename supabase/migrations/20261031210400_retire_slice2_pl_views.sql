-- Slice three, part 5 of 5 (rev 4). Kyle directly, 10/31 7:35 PM ET: "Retire those, this is what we want."
-- Slice two's line-item P&L views book the premium as revenue (the old model). They are retired; the slice-three walk
-- views (pl_daily_walk / pl_weekly_walk / pl_monthly_walk + pl_manual_entry_lines, pl_projected_rep_pay_daily,
-- pl_overhead_weekly / pl_overhead_monthly) are the only P&L from here on.
-- Dropped (views only, no data): pl_unpriced_sales, pl_monthly, pl_weekly, pl_daily, pl_line_items.
-- Kept: the slice-two TABLES expense_categories and revenue_adjustments (they hold entered data) and their policies /
-- grants; the function touch_updated_at() (their updated_at trigger); slice one's sales_commission / commission_rates()
-- and slice one's daily_pl / weekly_pl / monthly_pl (slice one, not retired by this ruling; slice one's verify uses them).
-- No slice-two function encodes the old model, so no function is dropped. slice3_rollback.sql recreates the five views
-- exactly (definitions, comments, grants). The dependency guard below refuses if anything else depends on them.
do $$
declare dep text;
begin
  select string_agg(x, '; ') into dep from (
    -- views / rules that reference one of the five (other than the five themselves)
    select distinct 'view ' || v.relname || ' -> ' || s.relname as x
      from pg_depend d
      join pg_rewrite r on r.oid = d.objid and d.classid = 'pg_rewrite'::regclass
      join pg_class v on v.oid = r.ev_class
      join pg_class s on s.oid = d.refobjid and d.refclassid = 'pg_class'::regclass
     where s.relnamespace = 'public'::regnamespace
       and s.relname in ('pl_line_items', 'pl_daily', 'pl_weekly', 'pl_monthly', 'pl_unpriced_sales')
       and v.oid <> s.oid
       and v.relname not in ('pl_line_items', 'pl_daily', 'pl_weekly', 'pl_monthly', 'pl_unpriced_sales')
    union all
    -- functions whose body names one of them
    select 'function ' || p.oid::regprocedure::text from pg_proc p
     where p.pronamespace not in ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
       and p.prosrc ~ '\mpl_(line_items|daily|weekly|monthly|unpriced_sales)\M'
    union all
    -- RLS policies that name one of them
    select 'policy ' || tablename || '.' || policyname from pg_policies
     where coalesce(qual, '') || coalesce(with_check, '') ~ '\mpl_(line_items|daily|weekly|monthly|unpriced_sales)\M'
  ) z;
  if dep is not null then
    raise exception 'retire slice-two P&L views refused: other objects depend on them (%)', dep;
  end if;
end $$;
drop view if exists public.pl_unpriced_sales;
drop view if exists public.pl_monthly;
drop view if exists public.pl_weekly;
drop view if exists public.pl_daily;
drop view if exists public.pl_line_items;
