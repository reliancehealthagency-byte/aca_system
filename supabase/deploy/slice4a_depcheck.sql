-- Slice 4a: READ-ONLY dependency and backfill check. Run in the SQL Editor before the paste; it changes nothing.
-- kind 'dependent'  : objects that depend on the objects 20261101130100 replaces (create or replace keeps them). Expected
--                     PR #7's view premier_recon_hub_open (reads premier_recon_trueup; 4a only appends columns), PR #7's
--                     rerun guard functions hub_open_items_schema_ok() / pay_line_locks_hub_schema_guard() (4a's
--                     definitions satisfy them), and the payroll_cutoffs_guard trigger. Any other 'dependent' row = review before applying.
-- kind 'collision'  : a slice-4a name already in use (expected: none; the preflight also refuses).
-- kind 'backfill'   : source rows (count | total) and, for pay_adjustments, how many actually post (only those on a LOCKED
--                     payday after the hub cutover; hub-era / unlocked ones never post). Live today: expected 0 everywhere
--                     except manual_entries. (The local test's '1 | 75' pay_adjustments row is the slice-three MOCK seed's
--                     $75 adjustment; it posts 0 rows because the mock has no lock for its payday.)
with tgt(n) as (values ('premier_recon_trueup')),
fns(n) as (values ('recon_line_pays'), ('premier_lock_payday'), ('payroll_cutoffs_guard'))
select kind, object, detail from (
  select 'dependent' kind, v.relname::text object, 'view depends on ' || s.relname detail
    from pg_depend d
    join pg_rewrite r on r.oid = d.objid and d.classid = 'pg_rewrite'::regclass
    join pg_class v on v.oid = r.ev_class
    join pg_class s on s.oid = d.refobjid and d.refclassid = 'pg_class'::regclass
   where s.relnamespace = 'public'::regnamespace and s.relname in (select n from tgt) and v.oid <> s.oid
  union all
  select 'dependent', p.oid::regprocedure::text, 'function body names premier_recon_trueup'
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosrc ~ '\mpremier_recon_trueup\M'
  union all
  select 'dependent', t.tgname || ' on ' || t.tgrelid::regclass::text, 'trigger calls ' || p.proname
    from pg_trigger t join pg_proc p on p.oid = t.tgfoid where not t.tgisinternal and p.proname in (select n from fns)
  union all
  select 'collision', c.relname::text, c.relkind::text from pg_class c
   where c.relnamespace = 'public'::regnamespace
     and (c.relname like 'ledger\_%' or c.relname like 'pl\_actual\_%' or c.relname like 'pl\_projected\_%' or c.relname = 'closed_week_carry_anchors')
     and c.relname not like 'pl\_projected\_rep\_pay%'
  union all
  select 'collision', 'recon_pay_config.closed_week_policy', 'column exists'
    from information_schema.columns where table_schema = 'public' and table_name = 'recon_pay_config' and column_name = 'closed_week_policy'
  union all
  select 'backfill', 'manual_entries (current, confirmed kinds)', count(*) || ' | ' || coalesce(sum(amount), 0) from public.manual_entries
  union all
  select 'backfill', 'overhead_entries', count(*) || ' | ' || coalesce(sum(amount), 0) from public.overhead_entries
  union all
  select 'backfill', 'pay_line_locks', count(*) || ' | ' || coalesce(sum(amount), 0) from public.pay_line_locks
  union all
  select 'backfill', 'pay_adjustments', count(*) || ' | ' || coalesce(sum(amount), 0) || ' | posts ' ||
         count(*) filter (where exists (select 1 from public.pay_line_locks k where k.payday = a.payday)
                            and a.payday > coalesce((select h.last_hub_payday from public.hub_cutover h), 'infinity'::date))
    from public.pay_adjustments a
  union all
  select 'backfill', 'hub_paid_lock', count(*) || ' | ' || coalesce(sum(paid_total), 0) from public.hub_paid_lock
) z order by 1, 2;
