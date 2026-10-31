-- Slice three verification (Premier reconciliation). ONE transaction, ROLLS BACK: leaves nothing behind.
-- Requires slices one + two + the three slice-three migrations, and the two test users linked (seed.sql).
-- Loads the MOCK seed (seed_slice3_mock.sql) inside the transaction, runs the event logger, and checks every README
-- scenario against KYLE'S-RULE expected pay (not the hub v19.11 result). Rows the README / payroll-breakdown flag as
-- pending Kyle are checked as OPEN with both readings, never as a guessed number.
-- Run as the project owner from the repo root:  psql -v ON_ERROR_STOP=1 -f supabase/tests/verify_slice3.sql
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

-- T0. slice-one LIKE claim, checked against Premier's REAL labels in the mock file (before loading: use the raw CSV labels)
\ir ../seed_slice3_mock.sql
select pg_temp.r('T0. claim CONFIRMED: slice-one case-sensitive LIKE list matches only Wellness4You + ChampionCare among mock Premier labels',
  (select array_agg(distinct product_label order by product_label) from public.premier_member_products p
    where exists (select 1 from unnest((select qualifying_addon_patterns from public.commission_config where id)) pat where p.product_label like pat))
  = array['ChampionCare','Wellness4You'],
  (select 'LIKE hits: ' || coalesce(string_agg(distinct product_label, ', '), 'none') from public.premier_member_products p
    where exists (select 1 from unnest((select qualifying_addon_patterns from public.commission_config where id)) pat where p.product_label like pat))
  || ' | missed: ' || (select string_agg(distinct product_label, ', ') from public.premier_member_products p
    where (public.premier_product_addon(p.product_label, p.product_benefit, true)).qualifies
      and not exists (select 1 from unnest((select qualifying_addon_patterns from public.commission_config where id)) pat where p.product_label like pat)));

-- T1. objects + security
select pg_temp.r('T1. slice-three tables + views exist (11 tables, 9 views)',
  (select count(*) from information_schema.tables where table_schema='public' and table_name in
    ('recon_pay_config','agent_pay_rules','payroll_cutoffs','recon_imports','premier_member_products','board_submissions',
     'premier_recon_event_state','premier_addon_map','policy_count_claims','pay_line_locks','pay_adjustments')) = 11
  and (select count(*) from information_schema.views where table_schema='public' and table_name in
    ('premier_products_current','premier_member_status','premier_recon_lines','premier_recon_unmatched_board',
     'premier_recon_unmatched_premier','premier_recon_open_items','premier_policy_count_check','premier_recon_trueup',
     'sales_missing_member_id')) = 9);
select pg_temp.r('T2. RLS on every slice-three table; every slice-three view is security_invoker',
  (select bool_and(relrowsecurity) from pg_class where relnamespace='public'::regnamespace and relname in
    ('recon_pay_config','agent_pay_rules','payroll_cutoffs','recon_imports','premier_member_products','board_submissions',
     'premier_recon_event_state','premier_addon_map','policy_count_claims','pay_line_locks','pay_adjustments'))
  and (select bool_and(coalesce(reloptions @> array['security_invoker=true'], false)) from pg_class
        where relnamespace='public'::regnamespace and relkind='v' and relname in
    ('premier_products_current','premier_member_status','premier_recon_lines','premier_recon_unmatched_board',
     'premier_recon_unmatched_premier','premier_recon_open_items','premier_policy_count_check','premier_recon_trueup','sales_missing_member_id')));
select pg_temp.r('T3. anon has no SELECT on any slice-three table/view and cannot run the logger',
  not exists (select 1 from pg_class where relnamespace='public'::regnamespace and relname in
    ('recon_pay_config','agent_pay_rules','payroll_cutoffs','recon_imports','premier_member_products','board_submissions',
     'premier_recon_event_state','premier_addon_map','policy_count_claims','pay_line_locks','pay_adjustments',
     'premier_products_current','premier_member_status','premier_recon_lines','premier_recon_unmatched_board',
     'premier_recon_unmatched_premier','premier_recon_open_items','premier_policy_count_check','premier_recon_trueup','sales_missing_member_id')
    and has_table_privilege('anon', oid, 'SELECT'))
  and not has_function_privilege('anon', 'public.premier_log_recon_events()', 'EXECUTE'));
select pg_temp.r('T4. commission_config intact (single row 0.38 / 0.05)',
  (select count(*) = 1 and bool_and(base_rate = 0.38 and addon_bonus_rate = 0.05) from public.commission_config));
select pg_temp.r('T5. hours are not an input: no column like %hour% in any slice-three table',
  not exists (select 1 from information_schema.columns where table_schema='public' and column_name ilike '%hour%' and table_name in
    ('recon_pay_config','agent_pay_rules','payroll_cutoffs','recon_imports','premier_member_products','board_submissions',
     'premier_addon_map','policy_count_claims','pay_line_locks','pay_adjustments')));
select pg_temp.r('T6. raw ingest: 66 Premier rows x 132 fields (cp1252/CRLF), 35 board rows x 42 fields, raw kept verbatim',
  (select count(*) = 66 and bool_and(cardinality(raw_fields) = 132) from public.premier_member_products)
  and (select count(*) = 35 and bool_and(cardinality(raw_fields) = 42) from public.board_submissions)
  and (select bool_and(encoding = case kind when 'premier_member_products' then 'cp1252' else 'utf-8' end and line_ending = 'CRLF') from public.recon_imports)
  and exists (select 1 from public.premier_member_products where raw_fields::text like '%Wellness Plan of America' || chr(160) || '%'),
  (select string_agg(kind || ' ' || row_count || ' ' || encoding || ' ' || line_ending, '; ') from public.recon_imports));
do $$ begin
  insert into public.recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count)
  select kind, file_name, file_sha256, encoding, line_ending, header, row_count from public.recon_imports limit 1;
  perform pg_temp.r('T7. re-importing the same file (same sha256) is refused', false, 'insert succeeded');
exception when unique_violation then perform pg_temp.r('T7. re-importing the same file (same sha256) is refused', true, sqlerrm); end $$;
\ir ../seed_slice3_mock.sql
select pg_temp.r('T7b. re-running the mock seed adds nothing', (select count(*) from public.premier_member_products) = 66
  and (select count(*) from public.board_submissions) = 35 and (select count(*) from public.pay_adjustments) = 1);
do $$ begin
  update public.board_submissions set agent_name = 'Nicholas Ziccardi' where member_id = '687990240';
  perform pg_temp.r('T8. board attribution is locked (agent_name update rejected)', false, 'update succeeded');
exception when others then perform pg_temp.r('T8. board attribution is locked (agent_name update rejected)', sqlerrm like '%locked%', sqlerrm); end $$;
do $$ begin
  update public.premier_member_products set raw_fields[47] = 'X' where row_num = 1;
  perform pg_temp.r('T8b. Premier raw fields are immutable', false, 'update succeeded');
exception when others then perform pg_temp.r('T8b. Premier raw fields are immutable', sqlerrm like '%immutable%', sqlerrm); end $$;

-- Events: first run logs, second run logs nothing.
create temp table ev as select public.premier_log_recon_events() as n1;
update ev set n1 = n1;  -- keep
alter table ev add column n2 int;
update ev set n2 = public.premier_log_recon_events();
select pg_temp.r('T9. event logger: first run logs diffs, second run is a no-op', (select n1 > 0 and n2 = 0 from ev),
  (select format('run1=%s run2=%s', n1, n2) from ev));
select pg_temp.r('T9b. events by type: premium 2 (S18 247->297, S19 450->427), paid status 6, pay week 2, post date 1, addon_mismatch 6, adjustment 1',
  (select count(*) from public.event_log where event_type='premier.premium_diff') = 2
  and (select count(*) from public.event_log where event_type='premier.paid_status_diff') = 6
  and (select count(*) from public.event_log where event_type='premier.pay_week_diff') = 2
  and (select count(*) from public.event_log where event_type='premier.post_date_diff') = 1
  and (select count(*) from public.event_log where event_type='premier.addon_mismatch') = 6
  and (select count(*) from public.event_log where event_type='payroll.adjustment.recorded') = 1,
  (select string_agg(event_type || '=' || c, ', ' order by event_type) from
     (select event_type, count(*) c from public.event_log where event_type like 'premier.%' or event_type like 'payroll.%' group by 1) x));

-- Scenario table: Kyle's-rule expected values (README "Expected under Kyle's rules", MOCK files 10/31 17:13 ET).
create temp table L as select * from public.premier_recon_lines;
create temp table X(code text, member text, lt text, ac numeric, sp numeric, cpf date, spf date, note text);
insert into X values
 ('S01','687990107','P',137.56,0,'2026-11-06',null,'baseline 38%'),
 ('S02','687990114','P',214.57,75,'2026-11-06','2026-11-06','Ultra 43% + $75'),
 ('S03','687990121','P',79.50,70,'2026-11-06','2026-10-30','Kaitlyn 25%; Premier wins: Edge $50 + Wellness $20'),
 ('S04','687990128','P',162.97,0,'2026-11-06',null,'AD&D 43%, no spiff'),
 ('S06','687990142','P',244.24,0,'2026-11-06',null,'ChampionCare 43%'),
 ('S07','687990149','P',137.56,0,'2026-11-06',null,'late CS Wellness ignored'),
 ('S09','687990163','P',188.34,0,'2026-11-06',null,'post-dated by Premier: 43%, no spiff'),
 ('S12','687990184','P',0,0,null,null,'failed payment $0'),
 ('S13','687990191','P',111.37,20,'2026-11-06','2026-10-30','VOID: claw proposed, Asset kept'),
 ('S14','687990198','P',94.75,0,'2026-11-06',null,'full refund: claw proposed'),
 ('S15','687990205','P',137.56,0,'2026-11-06',null,'partial refund: no claw'),
 ('S16','687990212','P',137.56,0,'2026-11-06',null,'refunded: claw proposed'),
 ('S16b','687990219','P',137.56,0,'2026-11-06',null,'rerun replacement credited'),
 ('S17','687990226','PADD',49.50,0,'2026-11-06',null,'ACA wrap 50%'),
 ('S19','687990240','P',162.26,0,'2026-11-06',null,'paid on Premier 427 to James'),
 ('S20','687990247','P',165.12,20,'2026-11-06','2026-11-06','Premier wins: Asset 43% + $20'),
 ('S21','687990254','P',98.47,50,'2026-11-06','2026-10-30','duplicate board row: one deal'),
 ('S22','687990261','P',214.57,0,'2026-11-06',null,'Loreidy: no spiffs'),
 ('S23','687990268','P',119.32,0,'2026-11-06',null,'hold info only'),
 ('S24','687990275','P',90.06,0,'2026-11-06',null,'inactive after payment stays good'),
 ('S25','687990282','P',119.32,0,'2026-11-06',null,'agent from AP'),
 ('S26','687990289','P',47.00,20,'2026-11-06','2026-11-06','late entry rolls spiff to 11/06'),
 ('S27','687990296','P',71.06,0,'2026-11-06',null,'half policy'),
 ('S30','687990909','ABS',0,80,null,null,'ABS Only 4 x 34.98'),
 ('S31','687990912','ABS',0,20,null,null,'ABS Only 1 item, no ACA'),
 ('S33','687990310','P',173.72,50,'2026-11-06','2026-10-30','same-day Edge, AO blank: missed spiff paid'),
 ('S34','687990317','P',119.32,0,'2026-11-06',null,'Ultra created day after booking: no 43%, no spiff'),
 ('S35','687990324','P',119.32,0,'2026-11-06',null,'board-only Edge claim pays $0'),
 ('S37','687990338','P',119.32,0,'2026-10-23',null,'later CS Ultra pays nothing');
do $$ declare x record; l record; ok boolean; begin
  for x in select * from X order by code loop
    select * into l from L where member_id = x.member and line_type = x.lt and line_status <> 'duplicate_board_row';
    ok := l.line_key is not null and l.actual_commission = x.ac and l.actual_spiffs = x.sp
          and (x.cpf is null or l.commission_pay_friday = x.cpf) and (x.spf is null or l.spiff_pay_friday = x.spf)
          and l.open_item is null;
    perform pg_temp.r(x.code || '. ' || x.note || format(' (commission %s, spiffs %s)', x.ac, x.sp), ok,
      format('got commission=%s spiffs=%s pay=%s spiff_pay=%s status=%s rate=%s', l.actual_commission, l.actual_spiffs,
             l.commission_pay_friday, l.spiff_pay_friday, l.line_status, l.commission_rate));
  end loop;
end $$;
-- scenario-specific extras
select pg_temp.r('S01/S29. duplicated Premier row deduped: member 687990107 has 4 current products, premium 362',
  (select count(*) from public.premier_products_current where member_id='687990107') = 4
  and (select premier_premium from L where member_id='687990107' and line_type='P') = 362.00);
select pg_temp.r('S02. ABS $29.98 on the Premier row = 1 item $20 (11/06)',
  (select abs_items = 1 and actual_spiffs = 20 and spiff_pay_friday = '2026-11-06' from L where member_id='687990903'));
select pg_temp.r('S05. OPEN (proposed "HD ProtectLife ADD" match, Q13): actual NULL, readings 105.64 / 119.54',
  (select open_item = 'proposed_addon_mapping' and actual_commission is null and open_alt_a_total = 105.64 and open_alt_b_total = 119.54
     from L where member_id='687990135'));
select pg_temp.r('S06. ABS $169.90 = 5 items $100 (1 x 29.98 + 4 x 34.98), 10/30 cycle',
  (select abs_items = 5 and actual_spiffs = 100 and spiff_pay_friday = '2026-10-30' and not abs_flagged from L where member_id='687990906'));
select pg_temp.r('S07. no pay-the-difference flag for the late CS add-on (no event other than none)',
  not exists (select 1 from public.event_log e join L on L.line_key = e.row_id where L.member_id='687990149' and e.event_type like 'premier.%'));
select pg_temp.r('S08. post-dated, not billed: $0 now, 52.25 projected, payday 11/13 (week of Premier billing 11/05), no Asset spiff',
  (select actual_commission = 0 and projected_commission = 52.25 and commission_pay_friday = '2026-11-13' and projected_spiffs = 0
          and line_status = 'awaiting_first_payment' from L where member_id='687990156'));
select pg_temp.r('S09. post_date_diff event logged (board No, Premier first bill 10/28)',
  exists (select 1 from public.event_log e join L on L.line_key = e.row_id where L.member_id='687990163' and e.event_type='premier.post_date_diff'));
select pg_temp.r('S10. never billed, not on board: unmatched Premier "cancelled_enrollment", $0, no event',
  exists (select 1 from public.premier_recon_unmatched_premier where member_id='687990170' and category='cancelled_enrollment' and pay_now=0)
  and not exists (select 1 from public.event_log where detail->>'member_id' = '687990170'));
select pg_temp.r('S11. PHS-only billed member: unmatched Premier "phs_only_pending_kyle", $0, premium 314 (no agent picked)',
  exists (select 1 from public.premier_recon_unmatched_premier where member_id='687990177' and category='phs_only_pending_kyle' and pay_now=0 and premier_premium=314));
select pg_temp.r('S12. failed payment: paid_status_diff event to failed_payment',
  exists (select 1 from public.event_log where event_type='premier.paid_status_diff' and detail->>'member_id'='687990184' and detail->>'to'='failed_payment'));
select pg_temp.r('S13. VOID claw -111.37 proposed (needs Kyle), not deducted; Asset $20 kept',
  (select clawback_proposed = -111.37 and actual_spiffs = 20 and line_status='void' from L where member_id='687990191'));
select pg_temp.r('S14. refund claw -94.75 proposed, netted on 11/06 if approved',
  (select clawback_proposed = -94.75 and clawback_pay_friday = '2026-11-06' from L where member_id='687990198'));
select pg_temp.r('S15/S24. no claw on partial refund or inactive-after-payment',
  (select bool_and(clawback_proposed is null) from L where member_id in ('687990205','687990275')));
select pg_temp.r('S16. claw -137.56 proposed + possible_rerun event to 687990219',
  (select clawback_proposed = -137.56 from L where member_id='687990212')
  and exists (select 1 from public.event_log where detail->>'kind'='possible_rerun' and detail->>'new_member_id'='687990219'));
select pg_temp.r('S17. ACA plus addons: ACA $30 + wrap $49.50 = $79.50',
  (select sum(actual_total) from L where board_row = (select board_row from L where member_id='687990226' and line_type='PADD')) = 79.50);
select pg_temp.r('S18. OPEN (one-time enrollment fee in premium): actual NULL, readings 93.86 / 112.86',
  (select open_item = 'one_time_fee_in_premium' and actual_commission is null and open_alt_a_total = 93.86 and open_alt_b_total = 112.86
     from L where member_id='687990233'));
select pg_temp.r('S19. premium_diff event 450 -> 427, attribution unchanged; Premier label (Nick) logged as reference only',
  exists (select 1 from public.event_log where event_type='premier.premium_diff' and detail->>'member_id'='687990240'
          and (detail->>'from')::numeric = 450 and (detail->>'to')::numeric = 427 and detail->>'attribution'='unchanged')
  and (select agent_name = 'James Carangelo' from L where member_id='687990240')
  and exists (select 1 from public.event_log where detail->>'kind'='premier_agent_label_differs' and detail->>'member_id'='687990240'));
select pg_temp.r('S21. duplicate board row pays $0 and is logged; deal total 148.47 once',
  (select count(*) = 2 and sum(actual_total) = 148.47 from L where member_id='687990254')
  and exists (select 1 from public.event_log where detail->>'kind'='duplicate_board_row' and detail->>'member_id'='687990254'));
select pg_temp.r('S27. half policy: 187 < 200 counts 0.5 (Premier and board)',
  (select premier_policy_count = 0.5 and board_policy_count = 0.5 from L where member_id='687990296'));
select pg_temp.r('S28. blank Member ID: ignored, $0, data-quality row + event',
  exists (select 1 from public.premier_recon_unmatched_premier where category='blank_member_id' and pay_now=0)
  and exists (select 1 from public.event_log where detail->>'kind'='blank_member_id'));
select pg_temp.r('S30/S31. ABS Only: Nick (AP) $80, Kaitlyn (S) $20, ABS never a percentage, no ACA $30 on ABS Only rows',
  (select agent_name='Nicholas Ziccardi' and actual_commission=0 from L where member_id='687990909')
  and (select agent_name='Kaitlyn Romine' and actual_commission=0 from L where member_id='687990912')
  and not exists (select 1 from L a join L b on a.board_row = b.board_row where a.member_id in ('687990909','687990912') and b.line_type='ACA'));
select pg_temp.r('S32. ACA Only: $30 flat',
  (select actual_total = 30 and line_type = 'ACA' from L where board_row = (select max(board_row) from L where line_type='ACA'
     and board_id not in (select board_id from L where line_type='PADD'))));
select pg_temp.r('S35. board-only Edge claim: expected (board) 185.02 vs actual 119.32, addon_mismatch logged',
  (select expected_total = 185.02 and actual_total = 119.32 from L where member_id='687990324')
  and exists (select 1 from public.event_log where event_type='premier.addon_mismatch' and detail->>'member_id'='687990324'));
select pg_temp.r('S36. post-dated, AD&D created before the post date counts: projected 109.22 at 43%, payday 11/13, $0 now, no spiff',
  (select projected_commission = 109.22 and commission_pay_friday = '2026-11-13' and actual_commission = 0 and projected_spiffs = 0
          and addon_cutoff_source = 'board_active_date_provisional (Q11 pending Kyle)' from L where member_id='687990331'));
select pg_temp.r('S37. Kyle''s manual adjustment +$75 to Nicholas Ziccardi on 11/06 (agent sees amount + note); rule still pays the add-on $0',
  exists (select 1 from public.pay_adjustments where member_id='687990338' and amount=75 and payday='2026-11-06' and entered_by='Kyle')
  and (select adjustments_total = 75 and stage2_premier_corrected = 119.32 from public.premier_recon_trueup where member_id='687990338')
  and exists (select 1 from public.event_log where event_type='payroll.adjustment.recorded' and (detail->'agent_visible'->>'amount')::numeric = 75));
select pg_temp.r('OPEN list = exactly S05 + S18 (pending Kyle)',
  (select array_agg(member_id order by member_id) from public.premier_recon_open_items) = array['687990135','687990233']);
select pg_temp.r('Unmatched board list empty for the mock (every board member is in Premier)',
  (select count(*) from public.premier_recon_unmatched_board) = 0);

-- Configurability + true-up + locks (all inside this transaction)
insert into public.board_submissions (import_id, row_num, raw_fields)
select id, 999, array_fill(''::text, array[42]) from public.recon_imports where kind='sales_board';
update public.board_submissions set raw_fields = raw_fields where false;  -- no-op
select pg_temp.r('C1. board row with blank Member ID shows in unmatched board as missing_member_id',
  exists (select 1 from public.premier_recon_unmatched_board where reason='missing_member_id'));
update public.premier_addon_map set status = 'approved' where pattern = '(^|[^a-z])add([^a-z]|$)';
select pg_temp.r('C2. approving the proposed ADD mapping (one row) makes S05 pay 119.54, no code change',
  (select actual_commission = 119.54 and open_item is null from public.premier_recon_lines where member_id='687990135'));
update public.premier_addon_map set status = 'proposed' where pattern = '(^|[^a-z])add([^a-z]|$)';
select pg_temp.r('I1. no date-range filter: S37 board row booked 10/16 (outside the file''s 10/25-10/31) is ingested and paid',
  (select date_booked = '2026-10-16' and actual_commission = 119.32 from public.premier_recon_lines where member_id='687990338'),
  (select format('date_booked=%s', date_booked) from public.premier_recon_lines where member_id='687990338'));
update public.recon_pay_config set one_time_fee_policy = 'exclude' where id;
select pg_temp.r('C11a. S18 one-time-fee policy is config: exclude -> paid on recurring only (reading A 93.86), no longer OPEN',
  (select actual_total = 93.86 and open_item is null from public.premier_recon_lines where member_id='687990233'));
update public.recon_pay_config set one_time_fee_policy = 'include' where id;
select pg_temp.r('C11b. include -> recurring + enrollment fee (reading B 112.86)',
  (select actual_total = 112.86 and open_item is null from public.premier_recon_lines where member_id='687990233'));
update public.recon_pay_config set one_time_fee_policy = 'pending_kyle' where id;
update public.recon_pay_config set post_date_source = 'premier_fbd_only' where id;
select pg_temp.r('C12. Q11 post-date field is config: premier_fbd_only makes S36''s cutoff Premier''s next billing (projected), still flagged pending',
  (select addon_cutoff_source = 'premier_next_billing_projected (Q11 pending Kyle)' from public.premier_recon_lines where member_id='687990331'),
  (select addon_cutoff_source from public.premier_recon_lines where member_id='687990331'));
update public.recon_pay_config set post_date_source = 'premier_fbd_else_board_active' where id;
update public.commission_config set addon_bonus_rate = 0.06 where id;
select pg_temp.r('C3. +5% lives in commission_config only: setting 0.06 makes S02 0.44 / 219.56',
  (select commission_rate = 0.44 and actual_commission = 219.56 from public.premier_recon_lines where member_id='687990114'));
update public.commission_config set addon_bonus_rate = 0.05 where id;
insert into public.policy_count_claims (agent_name, week_start, typed_count) values ('Suzelaine Similien', '2026-10-25', 5), ('Chris Wilfong', '2026-10-25', 5);
select pg_temp.r('C4. policy-count check: typed 5 vs board/Premier 4.5 = mismatch (Suzelaine); typed 5 = 5 = match (Chris)',
  (select flag from public.premier_policy_count_check where agent_name='Suzelaine Similien' and week_start='2026-10-25') = 'mismatch'
  and (select flag from public.premier_policy_count_check where agent_name='Chris Wilfong' and week_start='2026-10-25') = 'match',
  (select string_agg(agent_name || ':' || coalesce(typed_count::text,'-') || '/' || board_count || '/' || premier_count || '=' || flag, '; ')
     from public.premier_policy_count_check where week_start='2026-10-25'));
select pg_temp.r('C5. sales.premier_member_id + lead_source added (nullable); 5 seed sales flagged missing a member ID',
  (select count(*) from information_schema.columns where table_schema='public' and table_name='sales' and column_name in ('premier_member_id','lead_source') and is_nullable='YES') = 2
  and (select count(*) from public.sales_missing_member_id) = 5);
create temp table lk as select public.premier_lock_payday('2026-11-06') n1, public.premier_lock_payday('2026-11-06') n2;
select pg_temp.r('C6. lock 11/06 writes payroll-actual rows once (second call 0); OPEN rows are not locked',
  (select n1 > 0 and n2 = 0 from lk) and not exists (select 1 from public.pay_line_locks k join L on L.line_key = k.line_key where L.open_item is not null),
  (select format('locked=%s again=%s', n1, n2) from lk));
do $$ begin
  update public.pay_line_locks set commission = 0 where true;
  perform pg_temp.r('C7. locks are immutable', false, 'update succeeded');
exception when others then perform pg_temp.r('C7. locks are immutable', sqlerrm like '%immutable%', sqlerrm); end $$;
-- Premier later shows S19 at a different premium: the lock keeps 162.26, the true-up shows the difference.
insert into public.recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, note)
select kind, 'VERIFY later file', repeat('a', 64), encoding, line_ending, header, 1, true, 'VERIFY' from public.recon_imports where kind='premier_member_products';
insert into public.premier_member_products (import_id, row_num, raw_fields)
select (select id from public.recon_imports where file_name='VERIFY later file'), 1,
       (select array_agg(case when h = 'Product Fee' then '400.00' else p.raw ->> h end order by o)
          from unnest(i.header) with ordinality u(h, o))
  from public.premier_member_products p join public.recon_imports i on i.id = p.import_id
 where p.member_id = '687990240' and p.product_label = 'AdvantCare 9';
select pg_temp.r('C8. after lock, a new Premier premium (400+48) changes stage 2 only; lock stays 162.26, true-up due +7.98',
  (select stage2_premier_corrected = 170.24 and locked_commission = 162.26 and true_up_commission_due = 7.98
     from public.premier_recon_trueup where member_id='687990240'),
  (select format('stage2=%s locked=%s due=%s', stage2_premier_corrected, locked_commission, true_up_commission_due) from public.premier_recon_trueup where member_id='687990240'));
select public.premier_log_recon_events();
select pg_temp.r('C8b. that premium change is logged once as premier.premium_diff 427 -> 448',
  exists (select 1 from public.event_log where event_type='premier.premium_diff' and detail->>'member_id'='687990240' and (detail->>'from')::numeric=427 and (detail->>'to')::numeric=448));
do $$ begin
  insert into public.pay_adjustments (agent_name, payday, kind, amount, reason, entered_by) values ('James Carangelo', '2026-11-06', 'manual', 10, 'late', 'Kyle');
  perform pg_temp.r('C8c. adjustment on a locked (submitted) payday is refused', false, 'insert succeeded');
exception when others then perform pg_temp.r('C8c. adjustment on a locked (submitted) payday is refused', sqlerrm like '%locked%', sqlerrm); end $$;
do $$ begin
  insert into public.pay_adjustments (line_key, agent_name, payday, kind, amount, reason) values ('x', 'James Carangelo', '2026-11-13', 'cancel_commission', 10, 'bad');
  perform pg_temp.r('C9. Cancel Commission must be negative (positive rejected)', false, 'insert succeeded');
exception when check_violation then perform pg_temp.r('C9. Cancel Commission must be negative (positive rejected)', true, sqlerrm); end $$;
insert into public.pay_adjustments (line_key, member_id, agent_name, payday, kind, amount, reason, entered_by)
select line_key, member_id, agent_name, '2026-11-13', 'cancel_commission', -locked_commission, 'VERIFY cancel commission', 'Kyle'
  from public.premier_recon_trueup where member_id='687990240';
select public.premier_log_recon_events();
select pg_temp.r('C10. Cancel Commission survives a re-run: final = locked 162.26 + 0 spiff - 162.26 = 0, cancelled flag set',
  (select final_payable = 0 and commission_cancelled from public.premier_recon_trueup where member_id='687990240'),
  (select format('final=%s cancelled=%s', final_payable, commission_cancelled) from public.premier_recon_trueup where member_id='687990240'));

-- RLS as users
select pg_temp.act('authenticated','agent.test@example.com');
do $$ declare n int; begin
  select (select count(*) from public.premier_recon_lines) + (select count(*) from public.premier_member_products)
       + (select count(*) from public.board_submissions) + (select count(*) from public.pay_adjustments)
       + (select count(*) from public.premier_recon_trueup) + (select count(*) from public.recon_pay_config)
       + (select count(*) from public.premier_recon_unmatched_premier) into n;
  reset role;
  perform pg_temp.r('R1. agent sees 0 rows of reconciliation / pay data', n = 0, format('rows=%s', n));
end $$;
select pg_temp.act('authenticated','agent.test@example.com');
do $$ begin
  insert into public.pay_adjustments (agent_name, payday, kind, amount, reason) values ('Test', '2026-11-06', 'manual', 5, 'agent write');
  reset role; perform pg_temp.r('R2. agent cannot record an adjustment (Kyle/admin only)', false, 'insert succeeded');
exception when others then reset role; perform pg_temp.r('R2. agent cannot record an adjustment (Kyle/admin only)', true, sqlerrm); end $$;
select pg_temp.act('authenticated','agent.test@example.com');
do $$ begin
  perform public.premier_log_recon_events();
  reset role; perform pg_temp.r('R3. agent cannot run the event logger', false, 'ran');
exception when others then reset role; perform pg_temp.r('R3. agent cannot run the event logger', true, sqlerrm); end $$;
select pg_temp.act('authenticated','admin.test@example.com');
do $$ declare n int; begin
  select count(*) into n from public.premier_recon_lines;
  reset role;
  perform pg_temp.r('R4. admin user sees the reconciliation (38 mock lines + 1 VERIFY blank board row = 39)', n = 39, format('lines=%s', n));
end $$;

reset role;
\o
select n, case when pass then 'PASS' else 'FAIL' end as result, check_name, detail from results order by n;
rollback;
