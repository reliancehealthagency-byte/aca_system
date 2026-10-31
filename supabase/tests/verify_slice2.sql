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
select pg_temp.r('S1. new tables + views exist',
  (select count(*) from information_schema.tables where table_schema='public' and table_name in
    ('expense_categories','revenue_adjustments','pl_line_items','pl_daily','pl_weekly','pl_monthly','pl_unpriced_sales')) = 7);
-- S2. RLS on new tables; every P&L view is security_invoker
select pg_temp.r('S2a. RLS enabled on expense_categories + revenue_adjustments',
  (select bool_and(relrowsecurity) from pg_class where oid in ('public.expense_categories'::regclass,'public.revenue_adjustments'::regclass)));
select pg_temp.r('S2b. P&L views are security_invoker',
  (select bool_and(coalesce(reloptions @> array['security_invoker=true'], false)) from pg_class
    where oid in ('public.pl_line_items'::regclass,'public.pl_daily'::regclass,'public.pl_weekly'::regclass,'public.pl_monthly'::regclass,'public.pl_unpriced_sales'::regclass)));
-- S3. anon has nothing
select pg_temp.r('S3. anon has no SELECT on new tables/views',
  not (has_table_privilege('anon','public.expense_categories','SELECT') or has_table_privilege('anon','public.revenue_adjustments','SELECT')
    or has_table_privilege('anon','public.pl_line_items','SELECT') or has_table_privilege('anon','public.pl_daily','SELECT')
    or has_table_privilege('anon','public.pl_weekly','SELECT') or has_table_privilege('anon','public.pl_monthly','SELECT')
    or has_table_privilege('anon','public.pl_unpriced_sales','SELECT')));
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

-- S6. admin P&L values (seed only)
select pg_temp.act('authenticated','admin.test@example.com');
do $$ declare m record; w record; d record; li int; wsum numeric; bad_w int; bad_d int; c27 record; ok_types boolean; begin
  select * into m from public.pl_monthly where month_start = '2026-10-01';
  select * into w from public.pl_weekly  where week_start  = '2026-10-25';
  select * into d from public.pl_daily   where day         = '2026-10-31';
  select count(*), sum(signed_amount) into li, wsum from public.pl_line_items where week_start = '2026-10-25';
  select count(*) into bad_w from public.pl_weekly n full join public.weekly_pl o using (week_start)
    where n.revenue is distinct from o.premium_total or n.commission is distinct from o.agent_commission
       or n.expenses is distinct from o.expenses::numeric(12,2) or n.net is distinct from o.net_placeholder;
  select count(*) into bad_d from public.pl_daily n full join public.daily_pl o using (day)
    where n.revenue is distinct from o.premium_total or n.net is distinct from o.net_placeholder;
  select sum(amount) filter (where category='agent_commission_base') as base,
         sum(amount) filter (where category='agent_commission_addon_bonus') as bonus
    into c27 from public.pl_line_items where ref_id = '00000000-0000-4000-8000-00000005a002' and line_type='commission';
  select bool_and(line_type in ('revenue','commission','expense')) into ok_types from public.pl_line_items;
  reset role;
  perform pg_temp.r('S6a. Oct 2026 monthly: revenue 560.00, commission 218.80, expenses 4958.86, net -4617.66, 35 lines',
    m.revenue = 560.00 and m.commission = 218.80 and m.expenses = 4958.86 and m.net = -4617.66 and m.line_count = 35 and m.sales_count = 5,
    format('rev=%s com=%s exp=%s net=%s lines=%s sales=%s', m.revenue, m.commission, m.expenses, m.net, m.line_count, m.sales_count));
  perform pg_temp.r('S6b. week of Sun 10/25: revenue 560.00, commission 218.80, expenses 574.00, net -232.80, 15 lines',
    w.revenue = 560.00 and w.commission = 218.80 and w.expenses = 574.00 and w.net = -232.80 and w.line_count = 15,
    format('rev=%s com=%s exp=%s net=%s lines=%s', w.revenue, w.commission, w.expenses, w.net, w.line_count));
  perform pg_temp.r('S6c. today 10/31: revenue 110.00, commission 41.80, expenses 199.00, net -130.80',
    d.revenue = 110.00 and d.commission = 41.80 and d.expenses = 199.00 and d.net = -130.80,
    format('rev=%s com=%s exp=%s net=%s', d.revenue, d.commission, d.expenses, d.net));
  perform pg_temp.r('S6d. drill-down lines add back to the week summary', li = w.line_count and wsum = w.net, format('lines=%s sum=%s', li, wsum));
  perform pg_temp.r('S6e. new weekly/daily summaries equal slice-one weekly_pl/daily_pl (no adjustments)', bad_w = 0 and bad_d = 0,
    format('weekly mismatches=%s daily mismatches=%s', bad_w, bad_d));
  perform pg_temp.r('S6f. 10/27 commission split: base 45.60 + add-on bonus 6.00 = 51.60', c27.base = 45.60 and c27.bonus = 6.00,
    format('base=%s bonus=%s', c27.base, c27.bonus));
  perform pg_temp.r('S6g. line_type is only revenue/commission/expense', ok_types);
end $$;
reset role;
insert into public.revenue_adjustments (date, category, amount, description, source)
  values ('2026-10-31', 'chargeback', -25.00, 'VERIFY fake chargeback', 'manual');
select pg_temp.act('authenticated','admin.test@example.com');
do $$ declare d record; begin
  select * into d from public.pl_daily where day = '2026-10-31';
  reset role;
  perform pg_temp.r('S6h. a -25.00 chargeback adjustment lands as a revenue line (today net -130.80 -> -155.80)',
    d.revenue = 85.00 and d.net = -155.80, format('rev=%s net=%s', d.revenue, d.net));
end $$;
reset role;
delete from public.revenue_adjustments where description = 'VERIFY fake chargeback';

-- S6i. a sale with no Premier and no board premium is not dropped silently: it appears in pl_unpriced_sales
insert into public.sales (id, contact_id, agent_of_record, sale_date, board_premium, premier_premium)
  values ('00000000-0000-4000-8000-00000005a999', '00000000-0000-4000-8000-0000000c0006',
          '00000000-0000-4000-8000-00000000a002', '2026-10-31', null, null);
select pg_temp.act('authenticated','admin.test@example.com');
do $$ declare u int; l int; u0 int; begin
  select count(*) into u from public.pl_unpriced_sales where sale_id = '00000000-0000-4000-8000-00000005a999';
  select count(*) into l from public.pl_line_items where ref_id = '00000000-0000-4000-8000-00000005a999';
  select count(*) into u0 from public.pl_unpriced_sales where sale_id <> '00000000-0000-4000-8000-00000005a999';
  reset role;
  perform pg_temp.r('S6i. unpriced sale listed in pl_unpriced_sales (1), has no P&L line (0); seed has 0 unpriced',
    u = 1 and l = 0 and u0 = 0, format('unpriced=%s lines=%s other_unpriced=%s', u, l, u0));
end $$;
reset role;
delete from public.sales where id = '00000000-0000-4000-8000-00000005a999';

-- S7. agent: nothing new is visible, own sales unchanged, no writes
select pg_temp.act('authenticated','agent.test@example.com');
do $$ declare n int; s int; begin
  select (select count(*) from public.expense_categories) + (select count(*) from public.revenue_adjustments)
       + (select count(*) from public.pl_line_items) + (select count(*) from public.pl_daily)
       + (select count(*) from public.pl_weekly) + (select count(*) from public.pl_monthly)
       + (select count(*) from public.pl_unpriced_sales)
       + (select count(*) from public.expenses) into n;
  select count(*) into s from public.sales;
  reset role;
  perform pg_temp.r('S7a. agent sees 0 rows in expenses, categories, adjustments and all P&L views', n = 0, format('rows=%s', n));
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
