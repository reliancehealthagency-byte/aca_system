-- C5 agent attribution checks (20261101090000). ALL DATA FAKE. Run on a local stub DB built from the migrations; rolls back.
-- psql -X -q -d DB -f supabase/tests/verify_agent_attribution.sql   (expects every row PASS)
begin;
\o /dev/null
create temp table results (n serial, check_name text, pass boolean, detail text);
create or replace function pg_temp.r(c text, p boolean, d text default null) returns void language sql as
$$ insert into results(check_name, pass, detail) values (c, coalesce(p,false), d) $$;
-- 42-column board row: A ts, B member, F agent, G premium, R deal type, S agent (ACA), AJ ABS member, AK ABS premium,
-- AP agent 3, plus one free-text column O ('Column 36') for the row-scan case
create or replace function pg_temp.brow(ts text, member text, f text, deal text, s text, ap text, absm text default '', absp text default '',
                                        prem text default '', o text default '') returns text[] language sql as $$
  select array[ts, member, '11/02/2026', '', '', f, prem, '', '', '', '', '', '', '', o, '', '', deal, s, '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '',
               absm, absp, '', '', '', '', ap]::text[] $$;
insert into public.agents (display_name, role) values ('Jamie Mockford', 'agent'), ('Pat Exampleton', 'agent'), ('Chris Testwell', 'agent');
insert into public.agent_name_aliases (alias, agent_id, kind, note)
select 'Jim Mockford', id, 'board', 'VERIFY' from public.agents where display_name = 'Jamie Mockford'
union all select 'Jamie 901', id, 'dialer', 'VERIFY' from public.agents where display_name = 'Jamie Mockford';
with imp as (
  insert into public.recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, hash_scheme, note)
  values ('sales_board', 'VERIFY attribution board', repeat('a', 64), 'utf-8', 'CRLF', array['Timestamp','Member ID','Date Booked','Month/Year','Active Date','Agent','Premium','Customer Name','Customer Email','Customer Phone','Source','State
','Post Date','Email','Column 36','ABS Addon?','Column 37','Deal Type','Agent','Column 38','FFM','Client Name','Carrier','State','Date Booked','Date Booked (Month/Year)','ACA Premium Amount','Premium Paid?','Income','Effective Date','NPN(listed on policy)','Premier/Neo Addon?','Premier/Neo Member ID','Premier/Neo Premium','ABS Addon?','ABS Member ID','ABS Premium','Source','Phone Number','Source','Increased Comm/Spiff Product?','Agent']::text[], 10, true, 'sha256', 'VERIFY')
  returning id)
insert into public.board_submissions (import_id, row_num, raw_fields)
select imp.id, v.n, v.f from imp, (values
  (1, pg_temp.brow('11/02/2026 09:00:01', '687000001', '  jim   MOCKFORD ', '', '', '', '', '', '120.00')),
  (2, pg_temp.brow('11/02/2026 09:00:02', '', 'Pat Exampleton', 'ACA', 'Chris Testwell', '')),
  (3, pg_temp.brow('11/02/2026 09:00:03', '', '', '', 'pat  exampleton', '')),
  (4, pg_temp.brow('11/02/2026 09:00:04', '', '', 'ABS Only', 'Chris Testwell', '', '687000004', '29.98')),
  (5, pg_temp.brow('11/02/2026 09:00:05', '', 'Pat Exampleton', 'ABS Only', 'Chris Testwell', '', '687000005', '29.98')),
  (6, pg_temp.brow('11/02/2026 09:00:06', '687000006', '', '', '', 'Unknown Person', '', '', '99.00')),
  (7, pg_temp.brow('11/02/2026 09:00:07', '687000007', '', '', '', '', '', '', '99.00', 'chris testwell')),
  (8, pg_temp.brow('11/02/2026 09:00:08', '687000008', '', '', '', '', '', '', '99.00', 'Chris Testwell / Pat Exampleton')),
  (9, pg_temp.brow('11/02/2026 09:00:09', '687000009', 'Sam Mockford', '', '', '', '', '', '99.00')),
  (10, pg_temp.brow('11/02/2026 09:00:10', '687000010', '', '', '', 'Jim Mockford', '', '', '99.00'))
) v(n, f);
select public.recon_finalize_board_import((select id from public.recon_imports where file_name = 'VERIFY attribution board'));
create temp table B as select row_num, agent_name, agent_name_typed, agent_source_col, agent_id, line_kind
  from public.board_submissions where import_id = (select id from public.recon_imports where file_name = 'VERIFY attribution board');
create temp table A as select display_name, id from public.agents where display_name in ('Jamie Mockford', 'Pat Exampleton', 'Chris Testwell');

select pg_temp.r('AT1. names match ignoring case and extra spaces: roster name and alias (board + dialer kinds)',
  public.recon_agent_id('  JAMIE    mockford ') = (select id from A where display_name = 'Jamie Mockford')
  and public.recon_agent_id('jim mockford') = (select id from A where display_name = 'Jamie Mockford')
  and public.recon_agent_id('JAMIE 901') = (select id from A where display_name = 'Jamie Mockford')
  and public.recon_agent_id('Nobody Here') is null);
select pg_temp.r('AT2. an alias typed in F pays under the STANDARD roster name (agent_pay_rules / totals key); the spelling is kept',
  (select agent_name = 'Jamie Mockford' and agent_name_typed = 'jim   MOCKFORD' and agent_source_col = 'F'
          and agent_id = (select id from A where display_name = 'Jamie Mockford') from B where row_num = 1),
  (select row(agent_name, agent_name_typed, agent_source_col)::text from B where row_num = 1));
select pg_temp.r('AT3. ACA row (Deal Type ACA) uses S even when F is filled',
  (select agent_name = 'Chris Testwell' and agent_source_col = 'S' and line_kind = 'aca' from B where row_num = 2));
select pg_temp.r('AT4. F blank + S filled = ACA row: S (case/space-insensitive -> roster name)',
  (select agent_name = 'Pat Exampleton' and agent_source_col = 'S' and line_kind = 'aca' from B where row_num = 3));
select pg_temp.r('AT5. ABS Only, F blank + S filled (the hub isAcaRow L1319 case): agent from S, line kind abs_only',
  (select agent_name = 'Chris Testwell' and agent_source_col = 'S' and line_kind = 'abs_only' from B where row_num = 4));
select pg_temp.r('AT6. ABS Only pays the ABS spiff only: one ABS line ($20 board estimate), never an ACA line / ACA flat',
  (select count(*) = 1 and bool_and(line_type = 'ABS') and sum(expected_total) = 20 from public.premier_recon_lines
    where submission_key = '20261102090004')
  and not exists (select 1 from public.premier_recon_lines where submission_key in ('20261102090004', '20261102090005') and line_type = 'ACA'),
  (select string_agg(line_key || ' ' || line_type || ' ' || coalesce(expected_total::text, 'null'), ', ') from public.premier_recon_lines
    where submission_key in ('20261102090004', '20261102090005')));
select pg_temp.r('AT7. ABS Only with F and S both filled: F (same F/S rule as the hub)',
  (select agent_name = 'Pat Exampleton' and agent_source_col = 'F' and line_kind = 'abs_only' from B where row_num = 5));
select pg_temp.r('AT8. F and S blank: the other agent header (AP); an unknown name stays as typed, agent_id NULL',
  (select agent_name = 'Unknown Person' and agent_source_col = 'AP' and agent_id is null from B where row_num = 6));
select pg_temp.r('AT9. F, S, AP blank: row scan finds exactly one known name (case-insensitive) -> that agent',
  (select agent_name = 'Chris Testwell' and agent_source_col = 'row_scan' from B where row_num = 7));
select pg_temp.r('AT10. row scan with no single exact name match: no agent (unattributed, flagged)',
  (select agent_name is null and agent_id is null from B where row_num = 8));
select pg_temp.r('AT11. High Unknown-agent flag for every unresolved row, with a last-name suggestion that is never assigned',
  (select count(*) = 3 and bool_and(severity = 'High' and flag = 'Unknown agent') from public.board_unknown_agents
    where import_id = (select id from public.recon_imports where file_name = 'VERIFY attribution board'))
  and (select suggestion = 'Jamie Mockford' from public.board_unknown_agents where name_as_typed = 'Sam Mockford')
  and (select agent_name = 'Sam Mockford' and agent_id is null from B where row_num = 9),
  (select string_agg(coalesce(name_as_typed, '(blank)') || '->' || coalesce(suggestion, '-'), ', ') from public.board_unknown_agents));
select pg_temp.r('AT12. backup column alias resolves (AP "Jim Mockford" -> Jamie Mockford)',
  (select agent_name = 'Jamie Mockford' and agent_source_col = 'AP' from B where row_num = 10));
select pg_temp.r('AT13. pay lines carry the standard name: the alias row appears under Jamie Mockford, not the typed spelling',
  (select bool_and(agent_name = 'Jamie Mockford') from public.premier_recon_lines where submission_key in ('20261102090001', '20261027090010'))
  and not exists (select 1 from public.premier_recon_lines where submission_key like '2026110209%' and lower(agent_name) like 'jim%'));
select pg_temp.r('AT14. attribution stays locked after insert (immutable board rows)',
  (select count(*) = 0 from (select 1) x where false));
do $$ begin
  begin
    update public.board_submissions set agent_name = 'Pat Exampleton' where row_num = 1
      and import_id = (select id from public.recon_imports where file_name = 'VERIFY attribution board');
    update results set pass = false, detail = 'update allowed' where check_name like 'AT14.%';
  exception when others then
    update results set pass = true, detail = sqlerrm where check_name like 'AT14.%';
  end;
end $$;
\o
select n, case when pass then 'PASS' else 'FAIL' end as result, check_name, left(coalesce(detail, ''), 200) detail from results order by n;
rollback;
