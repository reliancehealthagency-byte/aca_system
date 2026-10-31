-- Slice two verification, SLICE-THREE-ERA version (rev 4). Derived from supabase/tests/verify_slice2.sql, which is kept
-- unchanged as history and still passes 29/29 on a slice-one + two database (and after slice3_rollback.sql).
-- After slice three, slice two's five P&L views are retired (Kyle directly, 10/31 7:35 PM ET: "Retire those, this is
-- what we want"), so the checks that read them no longer apply:
--   S1  adapted: the 2 slice-two tables exist AND the 5 views are gone (was: 2 tables + 5 views exist)
--   S2b removed: "P&L views are security_invoker" (the views no longer exist)
--   S3  adapted: anon has no SELECT on the 2 tables (the 5 views are gone)
--   S6a-S6g removed: monthly / weekly / daily totals, drill-down add-back, equality with weekly_pl / daily_pl,
--           10/27 commission split, line types (all read pl_monthly / pl_weekly / pl_daily / pl_line_items)
--   S6h removed: chargeback lands as a revenue line in pl_daily (revenue_adjustments is kept but no P&L view reads it)
--   S6i removed: unpriced sale listed in pl_unpriced_sales
--   S7a adapted: agent sees 0 rows in expenses, categories and adjustments (the 5 views are gone)
-- Every other check (S2a, S4a-S4g, S5a-S5d, S7b-S7d) is byte-for-byte the slice-two check.
-- Slice two verification (line-item P&L). ONE transaction, ROLLS BACK: leaves nothing behind.
-- Requires slice one + slice two applied (migrations + seed.sql + seed_slice2.sql) and the two test users linked.
-- Run as the project owner:  psql -v ON_ERROR_STOP=1 -f supabase/tests/verify_slice2.sql
-- Expected values below are for the FAKE seed only (5 sales in week of Sun 10/25, 24 expense lines in Oct 2026).
-- Writes made here (VERIFY chargeback, VERIFY unpriced sale, temp category) are all rolled back at the end.
\set QUIET on
\o /dev/null
begin;
create temp table results(n serial, check_name text, pass boolean, detail text);
grant all on results to public; grant all on sequence results_n_seq to public;
create or replace function pg_temp.r(c text, p boolean, d text default null) returns void language sql as
$$ insert into results(check_name, pass, detail) values (c, coalesce(p,false), d) $$;
create or replace function pg_temp.act(role_name text, email text) returns void language plpgsql as $$
declare uid uuid;
begin
  reset role;
  select id into uid from auth.users where auth.users.email = act.email;
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', role_name, 'email', email)::text, true);
  execute format('set local role %I', role_name);
end $$;

-- S1. objects exist
select pg_temp.r('S1 (slice-three era). slice-two tables kept; its 5 P&L views retired (Kyle 7:35 PM)',
  (select count(*) from information_schema.tables where table_schema='public' and table_name in
    ('expense_categories','revenue_adjustments')) = 2
  and to_regclass('public.pl_line_items') is null and to_regclass('public.pl_daily') is null and to_regclass('public.pl_weekly') is null
  and to_regclass('public.pl_monthly') is null and to_regclass('public.pl_unpriced_sales') is null);
-- S2. RLS on new tables; every P&L view is security_invoker
select pg_temp.r('S2a. RLS enabled on expense_categories + revenue_adjustments',
  (select bool_and(relrowsecurity) from pg_class where oid in ('public.expense_categories'::regclass,'public.revenue_adjustments'::regclass)));
-- S3. anon has nothing
select pg_temp.r('S3 (slice-three era). anon has no SELECT on the slice-two tables',
  not (has_table_privilege('anon','public.expense_categories','SELECT') or has_table_privilege('anon','public.revenue_adjustments','SELECT')));
-- S4. expenses extended non-destructively
select pg_temp.r('S4a. expenses has category, amount, date, description, source, vendor, external_ref',
  (select count(*) from information_schema.columns where table_schema='public' and table_name='expenses'
    and column_name in ('category','amount','date','description','source','vendor','external_ref')) = 7);
select pg_temp.r('S4b. slice-one expense rows kept, remapped (3 lead_spend = 525.00, 1 dialer_software = 49.00, source=seed, seed-s1-01..04)',
  (select count(*) = 4 and sum(amount) = 574.00
          and count(*) filter (where category='lead_spend') = 3 and count(*) filter (where category='dialer_software') = 1
          and bool_and(source='seed')
          and array_agg(external_ref order by external_ref) = array['seed-s1-01','seed-s1-02','seed-s1-03','seed-s1-04']
          and count(*) filter (where external_ref='seed-s1-04' and category='dialer_software' and amount=49.00) = 1
     from public.expenses where description like 'FAKE seed:%' and date >= '2026-10-25'),
  (select string_agg(coalesce(external_ref,'NULL')||' '||category||' '||amount||' '||source, ', ' order by external_ref)
     from public.expenses where date >= '2026-10-25'));
select pg_temp.r('S4b2. no expense row without external_ref (all 24 are seed lines)',
  (select count(*) from public.expenses where external_ref is null) = 0 and (select count(*) from public.expenses) = 24,
  (select format('total=%s null_ref=%s', count(*), count(*) filter (where external_ref is null)) from public.expenses));
select pg_temp.r('S4c. slice-two seed: 20 lines, total 4384.86, all source=seed',
  (select count(*) = 20 and sum(amount) = 4384.86 and bool_and(source='seed') from public.expenses where external_ref like 'seed-s2-%'),
  (select format('rows=%s total=%s', count(*), sum(amount)) from public.expenses where external_ref like 'seed-s2-%'));
insert into public.expenses (date, category, amount, description, vendor, source, external_ref)
  values ('2026-10-01', 'dialer_software', 300.00, 'dup', null, 'seed', 'seed-s2-01')
  on conflict (source, external_ref) where external_ref is not null do nothing;
select pg_temp.r('S4d. seed is idempotent (re-insert seed-s2-01 adds nothing)',
  (select count(*) from public.expenses where external_ref = 'seed-s2-01') = 1);
do $$ begin
  insert into public.expenses (date, category, amount) values ('2026-10-31', 'not_a_category', 1);
  perform pg_temp.r('S4e. unknown category rejected by lookup FK', false, 'insert succeeded');
exception when foreign_key_violation then perform pg_temp.r('S4e. unknown category rejected by lookup FK', true, sqlerrm); end $$;
do $$ begin
  insert into public.revenue_adjustments (date, category, amount, description) values ('2026-10-31', 'chargeback', 10.00, 'VERIFY positive chargeback');
  perform pg_temp.r('S4g. positive chargeback rejected (check category <> chargeback or amount < 0)', false, 'insert succeeded');
exception when check_violation then perform pg_temp.r('S4g. positive chargeback rejected (check category <> chargeback or amount < 0)', true, sqlerrm); end $$;
select pg_temp.r('S4f. 6 expense categories',
  (select count(*) from public.expense_categories) = 6, (select string_agg(code, ',' order by sort_order) from public.expense_categories));

-- S5. audit trigger on new tables + expense updates still logged
insert into public.revenue_adjustments (id, date, category, amount, description, source)
  values ('00000000-0000-4000-8000-0000000ad001', '2026-10-31', 'chargeback', -25.00, 'VERIFY fake chargeback', 'manual');
update public.revenue_adjustments set amount = -24.00 where id = '00000000-0000-4000-8000-0000000ad001';
update public.revenue_adjustments set amount = -25.00 where id = '00000000-0000-4000-8000-0000000ad001';
select pg_temp.r('S5a. revenue_adjustments insert/update audited',
  (select count(*) from event_log where table_name='revenue_adjustments' and row_id='00000000-0000-4000-8000-0000000ad001') = 3);
insert into public.expense_categories (code, label) values ('verify_tmp', 'Verify temp');
delete from public.expense_categories where code = 'verify_tmp';
select pg_temp.r('S5b. expense_categories insert/delete audited',
  (select count(*) from event_log where table_name='expense_categories' and after->>'code'='verify_tmp' or (table_name='expense_categories' and before->>'code'='verify_tmp')) = 2);
-- On the live project the slice-one rows were inserted as 'Leads' and remapped; on a fresh build seed.sql inserts codes directly.
select pg_temp.r('S5c. slice-one category remap is in the event log (row.update on expenses, category changed)',
  exists (select 1 from event_log where table_name='expenses' and action='UPDATE' and 'category' = any(changed_fields)
          and before->>'category' = 'Leads' and after->>'category' = 'lead_spend')
  or not exists (select 1 from event_log where table_name='expenses' and action='INSERT' and after->>'category' = 'Leads'),
  case when exists (select 1 from event_log where table_name='expenses' and action='INSERT' and after->>'category' = 'Leads')
       then 'legacy rows remapped' else 'fresh build: no legacy categories to remap' end);
select pg_temp.r('S5d. commission_config unchanged (0.38 / 0.05)',
  (select base_rate = 0.38 and addon_bonus_rate = 0.05 from public.commission_config));
delete from public.revenue_adjustments where id = '00000000-0000-4000-8000-0000000ad001';

-- S6a-S6i: not applicable after slice three (they read the retired views; see the header).

-- S7. agent: nothing new is visible, own sales unchanged, no writes
select pg_temp.act('authenticated','agent.test@example.com');
do $$ declare n int; s int; begin
  select (select count(*) from public.expense_categories) + (select count(*) from public.revenue_adjustments)
       + (select count(*) from public.expenses) into n;
  select count(*) into s from public.sales;
  reset role;
  perform pg_temp.r('S7a (slice-three era). agent sees 0 rows in expenses, categories and adjustments', n = 0, format('rows=%s', n));
  perform pg_temp.r('S7b. agent still sees only own 3 sales', s = 3, format('sales=%s', s));
end $$;
select pg_temp.act('authenticated','agent.test@example.com');
do $$ begin
  insert into public.expenses (date, category, amount, description) values ('2026-10-31','other',1,'agent write');
  reset role; perform pg_temp.r('S7c. agent cannot insert expenses', false, 'insert succeeded');
exception when others then reset role; perform pg_temp.r('S7c. agent cannot insert expenses', true, sqlerrm); end $$;
select pg_temp.act('authenticated','agent.test@example.com');
do $$ begin
  insert into public.revenue_adjustments (date, category, amount) values ('2026-10-31','other_revenue',1);
  reset role; perform pg_temp.r('S7d. agent cannot insert revenue adjustments', false, 'insert succeeded');
exception when others then reset role; perform pg_temp.r('S7d. agent cannot insert revenue adjustments', true, sqlerrm); end $$;

reset role;
\o
select n, case when pass then 'PASS' else 'FAIL' end as result, check_name, detail from results order by n;
rollback;
