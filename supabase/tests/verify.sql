-- Slice one verification. Runs in ONE transaction and ROLLS BACK, so it leaves no test rows behind
-- (except that rolled-back work never existed). Requires the seed and the two test users
-- (admin.test@example.com, agent.test@example.com) linked to agents.
-- Run as the project owner (postgres):  psql -v ON_ERROR_STOP=1 -f supabase/tests/verify.sql
\set QUIET on
\o /dev/null
begin;
create temp table results(n serial, check_name text, pass boolean, detail text);
grant all on results to public; grant all on sequence results_n_seq to public;

create or replace function pg_temp.r(c text, p boolean, d text default null) returns void language sql as
$$ insert into results(check_name, pass, detail) values (c, coalesce(p,false), d) $$;

-- helper: act as a Supabase role with a JWT
create or replace function pg_temp.act(role_name text, email text) returns void language plpgsql as $$
declare uid uuid;
begin
  reset role;
  select id into uid from auth.users where auth.users.email = act.email;
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', role_name, 'email', email)::text, true);
  execute format('set local role %I', role_name);
end $$;

-- 1. tables and views exist
select pg_temp.r('1. tables + views exist',
  (select count(*) from information_schema.tables where table_schema='public' and table_name in
    ('agents','contacts','applications','sales','call_metrics','expenses','commission_config','event_log',
     'sales_commission','daily_pl','weekly_pl','monthly_pl')) = 12,
  (select string_agg(table_name, ',' order by table_name) from information_schema.tables where table_schema='public'));

-- 2. RLS enabled on every public table
select pg_temp.r('2. RLS enabled on all tables',
  not exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
               where n.nspname='public' and c.relkind='r' and not c.relrowsecurity),
  (select string_agg(relname || '=' || relrowsecurity, ',') from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r'));

-- 3. anon can read nothing (privileges revoked + no policies)
do $$ declare t text; ok boolean := true; bad text := ''; begin
  foreach t in array array['agents','contacts','applications','sales','call_metrics','expenses','commission_config',
                           'event_log','sales_commission','daily_pl','weekly_pl','monthly_pl'] loop
    if has_table_privilege('anon', 'public.' || t, 'SELECT') then ok := false; bad := bad || t || ' '; end if;
  end loop;
  perform pg_temp.r('3a. anon has no SELECT on any table/view', ok, nullif(bad,''));
  perform pg_temp.r('3b. anon cannot execute commission_rates()',
    not has_function_privilege('anon', 'public.commission_rates()', 'EXECUTE'));
end $$;

-- 4/5. event rows on insert and update, with before/after
insert into public.contacts(id, name, email, state) values ('00000000-0000-4000-8000-0000000ce999','Verify Fake','verify@example.com','FL');
select pg_temp.r('4. INSERT writes event with after',
  exists (select 1 from event_log where table_name='contacts' and row_id='00000000-0000-4000-8000-0000000ce999'
          and action='INSERT' and before is null and after->>'name'='Verify Fake'));
update public.contacts set state='GA' where id='00000000-0000-4000-8000-0000000ce999';
select pg_temp.r('5. UPDATE writes event with before/after + changed_fields',
  exists (select 1 from event_log where table_name='contacts' and row_id='00000000-0000-4000-8000-0000000ce999'
          and action='UPDATE' and before->>'state'='FL' and after->>'state'='GA' and changed_fields = array['state']));

-- 6. event log is immutable
do $$ begin
  begin update event_log set table_name='x' where id=(select min(id) from event_log);
        perform pg_temp.r('6a. event_log UPDATE rejected', false, 'update succeeded');
  exception when others then perform pg_temp.r('6a. event_log UPDATE rejected', true, sqlerrm); end;
  begin delete from event_log where id=(select min(id) from event_log);
        perform pg_temp.r('6b. event_log DELETE rejected', false, 'delete succeeded');
  exception when others then perform pg_temp.r('6b. event_log DELETE rejected', true, sqlerrm); end;
  perform pg_temp.r('6c. authenticated/service_role have no UPDATE/DELETE grant on event_log',
    not has_table_privilege('authenticated','public.event_log','UPDATE,DELETE')
    and not has_table_privilege('service_role','public.event_log','UPDATE,DELETE'));
end $$;

-- 7. commission 38% base / 43% with qualifying add-on
select pg_temp.r('7a. commission 38% base (100.00 -> 38.00)',
  (select commission_rate=0.38 and commission=38.00 from sales_commission where id='00000000-0000-4000-8000-00000005a001'));
select pg_temp.r('7b. commission 43% with Wellness4You (120.00 -> 51.60)',
  (select commission_rate=0.43 and commission=51.60 from sales_commission where id='00000000-0000-4000-8000-00000005a002'));

-- 10. daily / weekly P&L (as admin). Runs BEFORE checks 8/9, which change a rate and a Premier premium in this
-- transaction (9b sets 95.00 on the post-dated sale); reading after them gave the wrong 565.00 / 220.70 week total.
-- Expected = seed math: premium 100+120+140+90+110 = 560.00; commission 38.00+51.60+53.20+34.20 (estimate)+41.80 = 218.80.
select pg_temp.act('authenticated','admin.test@example.com');
do $$ declare d record; w record; begin
  select * into d from public.daily_pl where day = date '2026-10-31';
  select * into w from public.weekly_pl where week_start = date '2026-10-25';
  reset role;
  perform pg_temp.r('10a. daily_pl 2026-10-31 = 1 sale, 110.00, 41.80, 199.00, net -130.80',
    d.sales_count = 1 and d.premium_total = 110.00 and d.agent_commission = 41.80 and d.expenses = 199.00 and d.net_placeholder = -130.80,
    format('sales=%s premium=%s commission=%s expenses=%s net=%s', d.sales_count, d.premium_total, d.agent_commission, d.expenses, d.net_placeholder));
  perform pg_temp.r('10b. weekly_pl 10/25 = 5 sales, 560.00, 218.80, 574.00, net -232.80',
    w.sales_count = 5 and w.premium_total = 560.00 and w.agent_commission = 218.80 and w.expenses = 574.00 and w.net_placeholder = -232.80,
    format('sales=%s premium=%s commission=%s expenses=%s net=%s', w.sales_count, w.premium_total, w.agent_commission, w.expenses, w.net_placeholder));
end $$;
reset role;

-- 8. config change changes the result, no migration
update public.commission_config set base_rate = 0.40 where id;
select pg_temp.r('8. base_rate 0.38 -> 0.40 changes commission (38.00 -> 40.00, 43% -> 45%)',
  (select commission=40.00 from sales_commission where id='00000000-0000-4000-8000-00000005a001')
  and (select commission_rate=0.45 from sales_commission where id='00000000-0000-4000-8000-00000005a002'));
update public.commission_config set base_rate = 0.38 where id;

-- 9. premium mismatch event (seed sale: board 150 vs Premier 140) + paid on Premier + attribution unchanged
select pg_temp.r('9a. premium_mismatch event for seeded mismatch',
  exists (select 1 from event_log where event_type='premium_mismatch' and row_id='00000000-0000-4000-8000-00000005a003'
          and (detail->>'diff')::numeric = -10.00));
update public.sales set premier_premium = 95.00 where id='00000000-0000-4000-8000-00000005a004';
select pg_temp.r('9b. new Premier figure != board creates premium_mismatch on UPDATE',
  exists (select 1 from event_log where event_type='premium_mismatch' and row_id='00000000-0000-4000-8000-00000005a004'));
select pg_temp.r('9c. mismatch sale paid on Premier (140 x 38% = 53.20), attribution = form/CRM agent',
  (select commission=53.20 and agent_name='Blair Sample (fake)' from sales_commission where id='00000000-0000-4000-8000-00000005a003'));
do $$ begin
  update public.sales set agent_of_record='00000000-0000-4000-8000-00000000a002' where id='00000000-0000-4000-8000-00000005a003';
  perform pg_temp.r('9d. agent_of_record locked', false, 'update succeeded');
exception when others then perform pg_temp.r('9d. agent_of_record locked', true, sqlerrm); end $$;

-- 11. RLS as agent: own sales only; no expenses / P&L / config / event log
select pg_temp.act('authenticated','agent.test@example.com');
do $$ declare s int; o int; e int; p int; c int; l int; ct int; begin
  select count(*), count(*) filter (where agent_of_record <> '00000000-0000-4000-8000-00000000a002') into s, o from public.sales;
  select count(*) into e from public.expenses;
  select count(*) into p from public.daily_pl;
  select count(*) into c from public.commission_config;
  select count(*) into l from public.event_log;
  select count(*) into ct from public.contacts;
  reset role;
  perform pg_temp.r('11a. agent sees only own sales', s = 3 and o = 0, format('visible=%s others=%s', s, o));
  perform pg_temp.r('11b. agent sees no expenses / P&L / config / event log', e+p+c+l = 0, format('exp=%s pl=%s cfg=%s log=%s', e,p,c,l));
  perform pg_temp.r('11c. agent sees only contacts on own sales', ct = 3, format('contacts=%s', ct));
end $$;
select pg_temp.act('authenticated','agent.test@example.com');
do $$ declare com numeric; begin
  select commission into com from public.sales_commission where id='00000000-0000-4000-8000-00000005a002';
  reset role;
  perform pg_temp.r('11d. agent still gets derived commission on own sale (51.60)', com = 51.60, coalesce(com::text,'null'));
end $$;
select pg_temp.act('authenticated','agent.test@example.com');
do $$ begin
  update public.sales set board_premium = 999 where id='00000000-0000-4000-8000-00000005a001';
  reset role;
  perform pg_temp.r('11e. agent cannot change sales', (select board_premium from public.sales where id='00000000-0000-4000-8000-00000005a001') <> 999);
end $$;

-- 12. admin sees all
select pg_temp.act('authenticated','admin.test@example.com');
do $$ declare s int; begin select count(*) into s from public.sales; reset role;
  perform pg_temp.r('12. admin sees all sales', s >= 5, format('visible=%s', s)); end $$;

reset role;
\o
select n, case when pass then 'PASS' else 'FAIL' end as result, check_name, detail from results order by n;
rollback;
