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
select pg_temp.r('T1. slice-three tables + views exist (19 tables, 20 views)',
  (select count(*) from information_schema.tables where table_schema='public' and table_name in
    ('recon_pay_config','agent_pay_rules','payroll_cutoffs','recon_imports','premier_member_products','board_submissions',
     'premier_recon_event_state','premier_addon_map','policy_count_claims','pay_line_locks','pay_adjustments',
     'missed_spiff_anchors','board_week_freezes','hub_paid_lock','hub_cutover','agent_name_aliases',
     'manual_entry_sources','manual_entries','overhead_entries')) = 19
  and (select count(*) from information_schema.views where table_schema='public' and table_name in
    ('premier_products_current','premier_member_status','premier_recon_lines','premier_recon_unmatched_board',
     'premier_recon_unmatched_premier','premier_recon_open_items','premier_policy_count_check','premier_recon_trueup',
     'sales_missing_member_id','board_submissions_current','board_export_diffs',
     'manual_entries_current','pl_manual_entry_lines','pl_projected_rep_pay_lines','pl_projected_rep_pay_daily','pl_overhead_monthly','pl_overhead_weekly',
     'pl_daily_walk','pl_weekly_walk','pl_monthly_walk')) = 20);
select pg_temp.r('T2. RLS on every slice-three table; every slice-three view is security_invoker',
  (select bool_and(relrowsecurity) from pg_class where relnamespace='public'::regnamespace and relname in
    ('recon_pay_config','agent_pay_rules','payroll_cutoffs','recon_imports','premier_member_products','board_submissions',
     'premier_recon_event_state','premier_addon_map','policy_count_claims','pay_line_locks','pay_adjustments',
     'missed_spiff_anchors','board_week_freezes','hub_paid_lock','hub_cutover','agent_name_aliases',
     'manual_entry_sources','manual_entries','overhead_entries'))
  and (select count(*) = 20 and bool_and(coalesce(reloptions @> array['security_invoker=true'], false)) from pg_class
        where relnamespace='public'::regnamespace and relkind='v' and relname in
    ('premier_products_current','premier_member_status','premier_recon_lines','premier_recon_unmatched_board',
     'premier_recon_unmatched_premier','premier_recon_open_items','premier_policy_count_check','premier_recon_trueup','sales_missing_member_id',
     'board_submissions_current','board_export_diffs',
     'manual_entries_current','pl_manual_entry_lines','pl_projected_rep_pay_lines','pl_projected_rep_pay_daily','pl_overhead_monthly','pl_overhead_weekly',
     'pl_daily_walk','pl_weekly_walk','pl_monthly_walk')));
select pg_temp.r('T3. anon has no SELECT on any slice-three table/view and cannot run the logger',
  not exists (select 1 from pg_class where relnamespace='public'::regnamespace and relname in
    ('recon_pay_config','agent_pay_rules','payroll_cutoffs','recon_imports','premier_member_products','board_submissions',
     'premier_recon_event_state','premier_addon_map','policy_count_claims','pay_line_locks','pay_adjustments',
     'missed_spiff_anchors','board_week_freezes','hub_paid_lock','hub_cutover','agent_name_aliases',
     'premier_products_current','premier_member_status','premier_recon_lines','premier_recon_unmatched_board',
     'premier_recon_unmatched_premier','premier_recon_open_items','premier_policy_count_check','premier_recon_trueup','sales_missing_member_id',
     'board_submissions_current','board_export_diffs',
     'manual_entry_sources','manual_entries','overhead_entries',
     'manual_entries_current','pl_manual_entry_lines','pl_projected_rep_pay_lines','pl_projected_rep_pay_daily','pl_overhead_monthly','pl_overhead_weekly',
     'pl_daily_walk','pl_weekly_walk','pl_monthly_walk')
    and has_table_privilege('anon', oid, 'SELECT'))
  and not has_function_privilege('anon', 'public.premier_log_recon_events()', 'EXECUTE'));
select pg_temp.r('T4. commission_config intact (single row 0.38 / 0.05)',
  (select count(*) = 1 and bool_and(base_rate = 0.38 and addon_bonus_rate = 0.05) from public.commission_config));
select pg_temp.r('T5. hours are not an input: no column like %hour% in any slice-three table',
  not exists (select 1 from information_schema.columns where table_schema='public' and column_name ilike '%hour%' and table_name in
    ('recon_pay_config','agent_pay_rules','payroll_cutoffs','recon_imports','premier_member_products','board_submissions',
     'premier_addon_map','policy_count_claims','pay_line_locks','pay_adjustments')));
select pg_temp.r('T6. ops ingest: 66 Premier rows x 68 allow-listed fields (of 132, contact kept), 35 board rows x 42 (A..AP), cp1252/utf-8 CRLF recorded',
  (select count(*) = 66 and bool_and(cardinality(raw_fields) = 68) from public.premier_member_products)
  and (select count(*) = 35 and bool_and(cardinality(raw_fields) = 42) from public.board_submissions)
  and (select bool_and(encoding = case kind when 'premier_member_products' then 'cp1252' else 'utf-8' end and line_ending = 'CRLF') from public.recon_imports),
  (select string_agg(kind || ' ' || row_count || ' ' || encoding || ' ' || line_ending || ' ' || cardinality(header) || ' cols', '; ') from public.recon_imports));
select pg_temp.r('T6b. client data (Kyle 10/31): contact kept for admin ops (Premier names/phone/email, board H/I/J); gender/company/ethnicity/height/weight/disability never stored; AC blank; salted-or-mock hashes kept',
  (select count(*) filter (where first_name is not null and phone1 is not null and email is not null) > 0 from public.premier_member_products)
  and (select count(*) filter (where customer_name is not null and customer_email is not null and customer_phone is not null) > 0 from public.board_submissions)
  and not exists (select 1 from public.recon_imports i, unnest(i.header) c where i.kind = 'premier_member_products'
               and c in ('Gender','Company Name','Position','Ethnicity','Height','Weight','Disability','Refund Comment'))
  and not exists (select 1 from public.board_submissions b where btrim(b.raw ->> 'AC') <> '')
  and (select count(*) filter (where phone_sha256 ~ '^[0-9a-f]{64}$') > 0 and count(*) filter (where email_sha256 ~ '^[0-9a-f]{64}$') > 0
         from public.premier_member_products)
  and (select bool_and(hash_scheme = 'sha256' and is_mock) from public.recon_imports));
select pg_temp.r('T6c. free text: raw Hold Reason / Source kept untouched in raw; ops copy normalized (phone, email, client name stripped)',
  public.recon_scrub_text('call Jane Doe at (512) 555-0124 or jane.doe@example.com', array['Jane','Doe']) = 'call [name] [name] at [phone] or [email]'
  and (select bool_and(p.hold_reason = public.recon_scrub_text(p.raw ->> 'Hold Reason', array[p.first_name, p.last_name])) from public.premier_member_products p where p.raw ->> 'Hold Reason' <> '')
  and (select bool_and(b.raw ->> 'K' = b.lead_source) from public.board_submissions b where b.raw ->> 'K' <> ''),
  public.recon_scrub_text('call Jane Doe at (512) 555-0124 or jane.doe@example.com', array['Jane','Doe']));
do $$ begin
  insert into public.recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, hash_scheme)
  select kind, 'VERIFY real unsalted', repeat('7', 64), encoding, line_ending, header, 0, false, 'sha256'
    from public.recon_imports where kind = 'premier_member_products';
  perform pg_temp.r('H6. a real (non-mock) import with unsalted hashes is refused', false, 'insert succeeded');
exception when others then perform pg_temp.r('H6. a real (non-mock) import with unsalted hashes is refused', sqlerrm like '%salted hashes%', sqlerrm); end $$;
do $$ begin
  insert into public.recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, hash_scheme)
  select kind, 'VERIFY no Last Payment', repeat('c', 64), encoding, line_ending, array_remove(header, 'Last Payment'), 0, true, 'sha256'
    from public.recon_imports where kind = 'premier_member_products';
  perform pg_temp.r('H1. Premier import missing a named column (Last Payment) is refused', false, 'insert succeeded');
exception when others then perform pg_temp.r('H1. Premier import missing a named column (Last Payment) is refused', sqlerrm like '%required column(s) missing: Last Payment%', sqlerrm); end $$;
do $$ begin
  insert into public.recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, hash_scheme)
  select kind, 'VERIFY with sensitive', repeat('d', 64), encoding, line_ending, header || array['Gender', 'Ethnicity'], 0, true, 'sha256'
    from public.recon_imports where kind = 'premier_member_products';
  perform pg_temp.r('H2. Premier import carrying Gender / Ethnicity (outside the ops allow-list) is refused', false, 'insert succeeded');
exception when others then perform pg_temp.r('H2. Premier import carrying Gender / Ethnicity (outside the ops allow-list) is refused', sqlerrm like '%allow-list%Gender%', sqlerrm); end $$;
do $$ begin
  insert into public.recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, hash_scheme)
  select kind, 'VERIFY moved AO', repeat('e', 64), encoding, line_ending, header[1:40] || array['Something Else', 'Agent'], 0, true, 'sha256'
    from public.recon_imports where kind = 'sales_board';
  perform pg_temp.r('H3. board import whose AO column (Increased Comm/Spiff Product?) is missing is refused', false, 'insert succeeded');
exception when others then perform pg_temp.r('H3. board import whose AO column (Increased Comm/Spiff Product?) is missing is refused', sqlerrm like '%AO Increased Comm/Spiff Product?%', sqlerrm); end $$;
insert into public.recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, hash_scheme, note)
select kind, 'VERIFY H rows (never finalized)', repeat('9', 64), encoding, line_ending, header, 0, true, 'sha256', 'VERIFY'
  from public.recon_imports where kind = 'sales_board';
do $$ begin
  insert into public.board_submissions (import_id, row_num, raw_fields)
  select (select id from public.recon_imports where file_name = 'VERIFY H rows (never finalized)'), 901,
         (b.raw_fields[1:28] || array['45000'] || b.raw_fields[30:42])
    from public.board_submissions b where b.member_id = '687990107';
  perform pg_temp.r('H4. board row with Income in AC is refused (not contact data, not needed)', false, 'insert succeeded');
exception when others then perform pg_temp.r('H4. board row with Income in AC is refused (not contact data, not needed)', sqlerrm like '%column AC (Income)%', sqlerrm); end $$;
do $$ begin
  insert into public.board_submissions (import_id, row_num, raw_fields)
  select (select id from public.recon_imports where file_name = 'VERIFY H rows (never finalized)'), g, b.raw_fields
    from public.board_submissions b, generate_series(902, 903) g where b.member_id = '687990107';
  perform pg_temp.r('H5. two rows with one Timestamp in one board file are refused (ambiguous identity)', false, 'insert succeeded');
exception when unique_violation then perform pg_temp.r('H5. two rows with one Timestamp in one board file are refused (ambiguous identity)', true, sqlerrm); end $$;
do $$ begin
  insert into public.board_submissions (import_id, row_num, raw_fields)
  select b.import_id, 904, b.raw_fields from public.board_submissions b where b.member_id = '687990107';
  perform pg_temp.r('H7. rows can''t be added to a finalized export (snapshots are immutable); delete refused too', false, 'insert succeeded');
exception when others then
  begin
    delete from public.board_submissions where member_id = '687990107';
    perform pg_temp.r('H7. rows can''t be added to a finalized export (snapshots are immutable); delete refused too', false, 'delete succeeded');
  exception when others then
    perform pg_temp.r('H7. rows can''t be added to a finalized export (snapshots are immutable); delete refused too', sqlerrm like '%immutable%', sqlerrm);
  end;
end $$;
do $$ begin
  insert into public.recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, hash_scheme)
  select kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, hash_scheme from public.recon_imports where kind = 'sales_board' and file_name not like 'VERIFY%';
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
select pg_temp.r('T9b. events by type: premium 2 (S18 247->297, S19 450->427), paid status 6, pay week 2, post date 1, addon_mismatch 7 (S05 now qualifies: ProtectLife ADD approved, AO blank), adjustment 1',
  (select count(*) from public.event_log where event_type='premium_mismatch' and table_name='board_submissions') = 2
  and (select count(*) from public.event_log where event_type='premier.paid_status_diff') = 6
  and (select count(*) from public.event_log where event_type='premier.pay_week_diff') = 2
  and (select count(*) from public.event_log where event_type='premier.post_date_diff') = 1
  and (select count(*) from public.event_log where event_type='addon_mismatch' and table_name='board_submissions') = 7
  and exists (select 1 from public.event_log where event_type='addon_mismatch' and detail->>'member_id'='687990135')
  and (select count(*) from public.event_log where event_type='payroll.adjustment.recorded') = 1,
  (select string_agg(event_type || '=' || c, ', ' order by event_type) from
     (select event_type, count(*) c from public.event_log where table_name in ('board_submissions','pay_adjustments') and action = 'EVENT' group by 1) x));

-- Scenario table: Kyle's-rule expected values; S05 per Kyle 10/31 ProtectLife ADD approval (README "Expected under Kyle's rules", MOCK files 10/31 17:13 ET).
create temp table L as select * from public.premier_recon_lines;
create temp table X(code text, member text, lt text, ac numeric, sp numeric, cpf date, spf date, note text);
insert into X values
 ('S01','687990107','P',137.56,0,'2026-11-06',null,'baseline 38%'),
 ('S02','687990114','P',214.57,75,'2026-11-06','2026-11-06','Ultra 43% + $75'),
 ('S03','687990121','P',79.50,70,'2026-11-06','2026-10-30','Kaitlyn 25%; Premier wins: Edge $50 + Wellness $20'),
 ('S04','687990128','P',162.97,0,'2026-11-06',null,'AD&D 43%, no spiff'),
 ('S05','687990135','P',119.54,0,'2026-11-06',null,'HD ProtectLife ADD approved: 43%'),
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
 ('S33','687990310','P',173.72,50,'2026-11-06',null,'same-day Edge, AO blank: missed spiff paid'),
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
  exists (select 1 from public.event_log where event_type='premium_mismatch' and detail->>'member_id'='687990240'
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
  and exists (select 1 from public.event_log where event_type='addon_mismatch' and detail->>'member_id'='687990324'));
select pg_temp.r('S36. post-dated, AD&D created before the post date counts: projected 109.22 at 43%, payday 11/13, $0 now, no spiff',
  (select projected_commission = 109.22 and commission_pay_friday = '2026-11-13' and actual_commission = 0 and projected_spiffs = 0
          and addon_cutoff_source = 'board_active_date_provisional' from L where member_id='687990331'));
select pg_temp.r('S37. Kyle''s manual adjustment +$75 to Nicholas Ziccardi on 11/06 (agent sees amount + note); rule still pays the add-on $0',
  exists (select 1 from public.pay_adjustments where member_id='687990338' and amount=75 and payday='2026-11-06' and source_entered_by='Kyle')
  and (select adjustments_total = 75 and stage2_premier_corrected = 119.32 from public.premier_recon_trueup where member_id='687990338')
  and exists (select 1 from public.event_log where event_type='payroll.adjustment.recorded' and (detail->'agent_visible'->>'amount')::numeric = 75));
select pg_temp.r('OPEN list = exactly S18 (pending Kyle); S05 resolved by the ProtectLife ADD approval',
  (select array_agg(member_id order by member_id) from public.premier_recon_open_items) = array['687990233']);
select pg_temp.r('Unmatched board list empty for the mock (every board member is in Premier)',
  (select count(*) from public.premier_recon_unmatched_board) = 0);

-- Configurability (all inside this transaction)
select pg_temp.r('C2. HD ProtectLife ADD approved (Kyle 10/31): S05 pays 119.54 at 43%; setting that ONE map row back to proposed re-opens it (105.64 / 119.54)',
  (select actual_commission = 119.54 and commission_rate = 0.43 and open_item is null from L where member_id='687990135')
  and (select status = 'approved' from public.premier_addon_map where strpos(pattern, 'protect') > 0));
update public.premier_addon_map set status = 'proposed' where strpos(pattern, 'protect') > 0;
select pg_temp.r('C2b. (config check) proposed -> OPEN, readings 105.64 / 119.54, no code change',
  (select open_item = 'proposed_addon_mapping' and actual_commission is null and open_alt_a_total = 105.64 and open_alt_b_total = 119.54
     from public.premier_recon_lines where member_id='687990135'));
update public.premier_addon_map set status = 'approved' where strpos(pattern, 'protect') > 0;
select pg_temp.r('C2c. (Kyle 7:13 PM) the ADD match is narrow: "HD ProtectLife ADD", "AD&D", "AME-AD&D", "Accidental Death & Dismemberment" qualify; "Add-On Dental", "ADD Plus" get no +5%',
  (select bool_and((public.premier_product_addon(l, null)).addon_key = 'add_type')
     from unnest(array['HD ProtectLife ADD', 'AWA SecureElite AME-AD&D', 'AD&D', 'HD SecureShield CI-AME-AD&D', 'Accidental Death & Dismemberment']) l)
  and (select bool_and((public.premier_product_addon(l, null, true)).addon_key is null)
     from unnest(array['Add-On Dental', 'ADD Plus', 'Dental ADD-On', 'Vision Add Plus', 'ADD', 'Add-On Dental AD&D Rider']) l)
  and (select count(*) = 2 from public.premier_addon_map where source = 'premier_label_exclude' and active),
  (select string_agg(l || '=' || coalesce((public.premier_product_addon(l, null, true)).addon_key, '-'), ', ')
     from unnest(array['HD ProtectLife ADD', 'AD&D', 'Accidental Death & Dismemberment', 'Add-On Dental', 'ADD Plus']) l));
do $$ declare r numeric; c numeric; begin
  begin
    insert into public.recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, note)
    select kind, 'VERIFY negative add-ons', repeat('b', 64), encoding, line_ending, header, 2, true, 'VERIFY' from public.recon_imports where kind='premier_member_products';
    insert into public.premier_member_products (import_id, row_num, raw_fields)
    select (select id from public.recon_imports where file_name='VERIFY negative add-ons'), g.n,
           (select array_agg(case h when 'Product Label' then g.lbl when 'Product ID' then g.pid when 'Product Fee' then '10.00' when 'Product Benefit' then '' else p.raw ->> h end order by o)
              from unnest(i.header) with ordinality u(h, o))
      from public.premier_member_products p join public.recon_imports i on i.id = p.import_id,
           (values (1, 'Add-On Dental', '99901'), (2, 'ADD Plus', '99902')) g(n, lbl, pid)
     where p.member_id = '687990107' and p.product_label = 'VistaWell LP';
    select commission_rate, actual_commission into r, c from public.premier_recon_lines where member_id = '687990107' and line_type = 'P';
    raise exception 'undo';
  exception when others then
    if sqlerrm <> 'undo' then r := null; end if;
  end;
  perform pg_temp.r('C2d. end to end: S01 gains "Add-On Dental" + "ADD Plus" products on its booking day and still gets NO +5% (38%)',
    r = 0.38, format('rate=%s commission=%s', r, c));
end $$;
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
select pg_temp.r('C12a. Q11 resolved (Kyle 10/31): default post-date field = Premier First Billing Date, else board Active Date; status confirmed',
  (select post_date_source = 'premier_fbd_else_board_active' and post_date_source_status = 'confirmed' from public.recon_pay_config where id));
update public.recon_pay_config set post_date_source = 'premier_fbd_only' where id;
select pg_temp.r('C12. the post-date field is still config: premier_fbd_only makes S36''s cutoff Premier''s next billing (projected)',
  (select addon_cutoff_source = 'premier_next_billing_projected' from public.premier_recon_lines where member_id='687990331'),
  (select addon_cutoff_source from public.premier_recon_lines where member_id='687990331'));
update public.recon_pay_config set post_date_source = 'premier_fbd_else_board_active' where id;
update public.commission_config set addon_bonus_rate = 0.06 where id;
select pg_temp.r('C3. +5% lives in commission_config only: setting 0.06 makes S02 0.44 / 219.56',
  (select commission_rate = 0.44 and actual_commission = 219.56 from public.premier_recon_lines where member_id='687990114'));
update public.commission_config set addon_bonus_rate = 0.05 where id;
insert into public.policy_count_claims (agent_name, week_start, typed_count) values ('Suzelaine Similien', '2026-10-25', 5), ('Chris Wilfong', '2026-10-25', 5);
select pg_temp.r('C4. policy-count check: typed 5 vs board/Premier = mismatch (Suzelaine); typed 5 = 5 = match (Chris)',
  (select flag from public.premier_policy_count_check where agent_name='Suzelaine Similien' and week_start='2026-10-25') = 'mismatch'
  and (select flag from public.premier_policy_count_check where agent_name='Chris Wilfong' and week_start='2026-10-25') = 'match',
  (select string_agg(agent_name || ':' || coalesce(typed_count::text,'-') || '/' || board_count || '/' || premier_count || '=' || flag, '; ')
     from public.premier_policy_count_check where week_start='2026-10-25'));
select pg_temp.r('C5. sales.premier_member_id + lead_source added (nullable); 5 seed sales flagged missing a member ID',
  (select count(*) from information_schema.columns where table_schema='public' and table_name='sales' and column_name in ('premier_member_id','lead_source') and is_nullable='YES') = 2
  and (select count(*) from public.sales_missing_member_id) = 5);

-- ======== Board exports (rev 3): every export is a FULL, immutable snapshot, finalized once ========
-- pg_temp.mk(name, sha) makes an import header; pg_temp.latest() = rows of the latest finalized export.
create or replace function pg_temp.mk(fname text, sha text) returns bigint language sql as $$
  insert into public.recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, hash_scheme, note)
  select kind, fname, sha, encoding, line_ending, header, 0, true, 'sha256', 'VERIFY'
    from public.recon_imports where kind = 'sales_board' and file_name not like 'VERIFY%'
  returning id $$;
create or replace function pg_temp.imp(fname text) returns bigint language sql as $$
  select id from public.recon_imports where file_name = fname $$;
create or replace function pg_temp.latest() returns table(k text, f text[]) language sql as $$
  select b.submission_key, b.raw_fields from public.board_submissions b
   where b.import_id = (select max(latest_import_id) from public.board_submissions_current) $$;
create or replace function pg_temp.srv() returns void language plpgsql as $$
begin reset role; perform set_config('request.jwt.claims', '', true); end $$;
create or replace function pg_temp.key(member text) returns text language sql as $$
  select submission_key from public.board_submissions_current where member_id = member order by submitted_at limit 1 $$;

-- Export B = previous export + (1) a row with a blank Member ID; (2) an ACA + wrap row with an ABS add-on whose wrap member
-- (S10's, never billed) is not paid.
select pg_temp.mk('VERIFY export B (extra rows)', repeat('f', 64));
insert into public.board_submissions (import_id, row_num, raw_fields)
select pg_temp.imp('VERIFY export B (extra rows)'), row_number() over (order by x.f[1]), x.f from (
  select f from pg_temp.latest()
  union all select array['10/30/2026 15:00:00', ''] || b.raw_fields[3:42] from public.board_submissions_current b where b.member_id = '687990107'
  union all select array['10/30/2026 15:05:00'] || b.raw_fields[2:20] || array['9990001111'] || b.raw_fields[22:32]
       || array['687990170'] || b.raw_fields[34:34] || array['Yes', '687990915', '29.98'] || b.raw_fields[38:42]
    from public.board_submissions_current b where b.wrap_member_id = '687990226') x;
select public.recon_finalize_board_import(pg_temp.imp('VERIFY export B (extra rows)'));
select pg_temp.r('C1. board row with blank Member ID shows in unmatched board as missing_member_id',
  exists (select 1 from public.premier_recon_unmatched_board where reason='missing_member_id'));
select pg_temp.r('N1. ABS on an ACA + wrap row resolves its parent to the PADD line (wrap not paid -> ABS parent_not_paid, not NOID)',
  (select line_status = 'parent_not_paid' from public.premier_recon_lines where line_key = '20261030150500-ABS'),
  (select line_status || ' / PADD ' || (select line_status from public.premier_recon_lines where line_key = '20261030150500-PADD')
     from public.premier_recon_lines where line_key = '20261030150500-ABS'));
select pg_temp.r('X1. export diff: export B shows exactly the 2 added rows, nothing changed or removed',
  (select count(*) filter (where change = 'added') = 2 and count(*) filter (where change <> 'added') = 0
     from public.board_export_diffs where import_id = pg_temp.imp('VERIFY export B (extra rows)')),
  (select string_agg(change || ' ' || submission_key, ', ') from public.board_export_diffs where import_id = pg_temp.imp('VERIFY export B (extra rows)')));

-- RE1. Export C (full): S01 with a corrected agent, S02 with an edited premium; every other row unchanged.
create temp table before_re as select line_key, agent_name, actual_total from public.premier_recon_lines;
create temp table ev_before as select count(*) n from public.event_log where detail ->> 'kind' = 'board_submission_revised';
select pg_temp.mk('VERIFY export C (S01 agent, S02 premium)', repeat('1', 64));
insert into public.board_submissions (import_id, row_num, raw_fields)
select pg_temp.imp('VERIFY export C (S01 agent, S02 premium)'), row_number() over (order by k),
       case k when pg_temp.key('687990107') then f[1:5] || array['Chris Wilfong'] || f[7:42]
              when pg_temp.key('687990114') then f[1:6] || array['499.00'] || f[8:42]
              else f end
  from pg_temp.latest();
select public.recon_finalize_board_import(pg_temp.imp('VERIFY export C (S01 agent, S02 premium)'));
select pg_temp.r('RE1a. line IDs stay unique after the re-export (lines and true-up)',
  (select count(*) = count(distinct line_key) from public.premier_recon_lines)
  and (select count(*) = count(distinct line_key) from public.premier_recon_trueup)
  and (select count(*) from public.premier_recon_lines) = (select count(*) from before_re),
  (select format('lines=%s distinct=%s before=%s', count(*), count(distinct line_key), (select count(*) from before_re)) from public.premier_recon_lines));
select pg_temp.r('RE1b. S02 premium edit: one P line (board claim 499, still paid on Premier 214.57) and ABS paid ONCE ($20)',
  (select count(*) = 1 and bool_and(board_premium = 499.00 and actual_commission = 214.57) from public.premier_recon_lines where member_id = '687990114' and line_type = 'P')
  and (select count(*) = 1 and sum(actual_spiffs) = 20 from public.premier_recon_lines where member_id = '687990903' and line_type = 'ABS'),
  (select string_agg(line_key || ' ' || actual_total, ', ') from public.premier_recon_lines where member_id in ('687990114', '687990903')));
select pg_temp.r('RE1c. S01 agent correction in the OPEN week: pay moves to the corrected agent (Chris Wilfong 137.56), nothing left with Nicholas',
  (select count(*) = 1 and bool_and(agent_name = 'Chris Wilfong' and actual_total = 137.56) from public.premier_recon_lines where member_id = '687990107')
  and not exists (select 1 from public.premier_recon_trueup where member_id = '687990107' and agent_name <> 'Chris Wilfong'),
  (select string_agg(agent_name || ' ' || actual_total, ', ') from public.premier_recon_lines where member_id = '687990107'));
select pg_temp.r('RE1d. total pay unchanged by the re-export (no double pay anywhere); S37 adjustment still +75 once',
  (select sum(coalesce(actual_total, 0)) from public.premier_recon_lines) = (select sum(coalesce(actual_total, 0)) from before_re)
  and (select adjustments_total = 75 from public.premier_recon_trueup where member_id = '687990338'),
  (select format('after=%s before=%s', (select sum(coalesce(actual_total, 0)) from public.premier_recon_lines), sum(coalesce(actual_total, 0))) from before_re));
select public.premier_log_recon_events();
select pg_temp.r('RE1e. (rev-2 item 4) "revised" is logged ONLY for the 2 rows whose content changed, not for every row in the export',
  (select count(*) from public.event_log where detail ->> 'kind' = 'board_submission_revised') - (select n from ev_before) = 2
  and (select count(*) filter (where change = 'changed') = 2 and count(*) filter (where change <> 'changed') = 0
         from public.board_export_diffs where import_id = pg_temp.imp('VERIFY export C (S01 agent, S02 premium)')),
  (select format('revised events=%s', count(*)) from public.event_log where detail ->> 'kind' = 'board_submission_revised'));

-- ST. (rev-2 item 4) an OLDER export imported after a newer one must not pay stale data.
do $$ begin
  perform pg_temp.mk('VERIFY stale export (older download)', repeat('3', 64));
  insert into public.board_submissions (import_id, row_num, raw_fields)
  select pg_temp.imp('VERIFY stale export (older download)'), row_number() over (order by b.submission_key), b.raw_fields
    from public.board_submissions b join public.recon_imports i on i.id = b.import_id
   where i.file_name not like 'VERIFY%' and b.submitted_at < '2026-10-31';
  perform public.recon_finalize_board_import(pg_temp.imp('VERIFY stale export (older download)'));
  perform pg_temp.r('ST1. an export whose newest Timestamp is older than the latest import''s is refused', false, 'finalized');
exception when others then perform pg_temp.r('ST1. an export whose newest Timestamp is older than the latest import''s is refused', sqlerrm like '%STALE%', sqlerrm); end $$;
do $$ begin
  perform pg_temp.mk('VERIFY revert export (original content)', repeat('4', 64));
  insert into public.board_submissions (import_id, row_num, raw_fields)
  select pg_temp.imp('VERIFY revert export (original content)'), row_number() over (order by x.f[1]), x.f from (
    select b.raw_fields f from public.board_submissions b join public.recon_imports i on i.id = b.import_id where i.file_name not like 'VERIFY%'
    union all select f from pg_temp.latest() where k in ('20261030150000', '20261030150500')) x;
  perform public.recon_finalize_board_import(pg_temp.imp('VERIFY revert export (original content)'));
  perform pg_temp.r('ST2. an export (same newest Timestamp) that would revert S01 to Nicholas / S02 to its old premium is refused', false, 'finalized');
exception when others then perform pg_temp.r('ST2. an export (same newest Timestamp) that would revert S01 to Nicholas / S02 to its old premium is refused', sqlerrm like '%revert%', sqlerrm); end $$;
select pg_temp.r('ST3. after both refusals S01 still pays Chris Wilfong 137.56 (no stale data, nothing imported)',
  (select agent_name = 'Chris Wilfong' and actual_total = 137.56 from public.premier_recon_lines where member_id = '687990107')
  and pg_temp.imp('VERIFY stale export (older download)') is null and pg_temp.imp('VERIFY revert export (original content)') is null);

-- TS. (rev-2 item 3) export D, OPEN week: S30 (ABS Only) and S32 (ACA Only) re-timestamped by an edit; S31 removed.
create temp table before_ts as select sum(coalesce(actual_total, 0)) t from public.premier_recon_lines;
select pg_temp.mk('VERIFY export D (timestamps edited, S31 removed)', repeat('5', 64));
insert into public.board_submissions (import_id, row_num, raw_fields)
select pg_temp.imp('VERIFY export D (timestamps edited, S31 removed)'), row_number() over (order by k),
       case k when '20261030121103' then array['10/30/2026 12:11:33'] || f[2:42]
              when '20261030152041' then array['10/30/2026 15:21:11'] || f[2:42]
              else f end
  from pg_temp.latest() where k <> '20261030130255';
select public.recon_finalize_board_import(pg_temp.imp('VERIFY export D (timestamps edited, S31 removed)'));
select pg_temp.r('TS1. S30 ABS Only after a Timestamp edit pays ONCE ($80, deduped on the ABS member ID); old key = duplicate, flagged dropped',
  (select sum(actual_total) = 80 and count(*) filter (where line_status <> 'duplicate_board_row') = 1 from public.premier_recon_lines where member_id = '687990909')
  and (select line_status = 'duplicate_board_row' and dropped_from_export from public.premier_recon_lines where line_key = '20261030121103-ABS'),
  (select string_agg(line_key || ' ' || line_status || ' ' || actual_total, ', ') from public.premier_recon_lines where member_id = '687990909'));
select pg_temp.r('TS2. S32 ACA Only after a Timestamp edit pays ONCE ($30, deduped on the FFM); old key = duplicate',
  (select sum(actual_total) = 30 from public.premier_recon_lines where line_key in ('20261030152041-ACA', '20261030152111-ACA'))
  and (select line_status = 'duplicate_board_row' from public.premier_recon_lines where line_key = '20261030152041-ACA')
  and (select actual_total = 30 from public.premier_recon_lines where line_key = '20261030152111-ACA'),
  (select string_agg(line_key || ' ' || line_status || ' ' || actual_total, ', ') from public.premier_recon_lines where line_key like '2026103015%-ACA'));
select pg_temp.r('TS3. total pay unchanged by the timestamp edits (the Orchestrator''s +$80 / +$30 double pay is gone)',
  (select sum(coalesce(actual_total, 0)) from public.premier_recon_lines) = (select t from before_ts),
  (select format('after=%s before=%s', (select sum(coalesce(actual_total, 0)) from public.premier_recon_lines), t) from before_ts));
select pg_temp.r('DR1. S31 removed from the newest export in the OPEN week: flagged dropped_from_export, still pays $20 (no automatic unpay)',
  (select dropped_from_export and actual_total = 20 from public.premier_recon_lines where line_key = '20261030130255-ABS')
  and (select hold_status = 'dropped_from_export_flag_only' from public.premier_recon_trueup where line_key = '20261030130255-ABS'));
select public.premier_log_recon_events();
select pg_temp.r('DR2. the drop is logged once as board.dropped_from_export (Kyle corrects by hand if he meant it)',
  (select count(*) from public.event_log where event_type = 'board.dropped_from_export' and row_id like '20261030130255%') = 1
  and (select count(*) filter (where change = 'removed') from public.board_export_diffs where import_id = pg_temp.imp('VERIFY export D (timestamps edited, S31 removed)')) = 3,
  (select string_agg(change || ' ' || submission_key, ', ') from public.board_export_diffs where import_id = pg_temp.imp('VERIFY export D (timestamps edited, S31 removed)')));

-- ======== Hub cutover (rev-2 item 2 / Kyle 10/31): importing the hub file starts the clock, once ========
select pg_temp.r('CUT1. no hub file imported yet: S37 (hub-paid week 10/23) is NOT payable: pay NULL, flagged cutover_pending_kyle',
  (select pay_commission is null and final_payable is null and cutover_status = 'cutover_pending_kyle' from public.premier_recon_trueup where member_id = '687990338'),
  (select format('pay=%s final=%s status=%s', pay_commission, final_payable, cutover_status) from public.premier_recon_trueup where member_id = '687990338'));
do $$ begin
  perform public.premier_lock_payday('2026-11-06');
  perform pg_temp.r('LK0. locking any payday before the hub file is imported is refused', false, 'locked');
exception when others then perform pg_temp.r('LK0. locking any payday before the hub file is imported is refused', sqlerrm like '%hub%', sqlerrm); end $$;
select pg_temp.act('authenticated','admin.test@example.com');
do $$ begin
  insert into public.hub_paid_lock (file_sha256, row_num, payday, agent_name, paid_total, system_total, note)
  values (repeat('6', 64), 1, '2026-10-30', 'Kaitlyn Romine', 1, 1, 'VERIFY admin');
  reset role; perform pg_temp.r('O1. an admin (owner not set) cannot import the hub file / start the clock', false, 'insert succeeded');
exception when others then reset role; perform pg_temp.r('O1. an admin (owner not set) cannot import the hub file / start the clock', sqlerrm like '%hub cutover%', sqlerrm); end $$;
select pg_temp.act('service_role','admin.test@example.com');
do $$ begin
  insert into public.hub_paid_lock (file_sha256, row_num, payday, agent_name, paid_total, system_total, note)
  values (repeat('6', 64), 1, '2026-10-30', 'Kaitlyn Romine', 1, 1, 'VERIFY service');
  reset role; perform pg_temp.r('O1b. the admin key (service_role) cannot start the clock either', false, 'insert succeeded');
exception when others then reset role; perform pg_temp.r('O1b. the admin key (service_role) cannot start the clock either', true, sqlerrm); end $$;
select pg_temp.srv();
do $$ begin
  insert into public.hub_paid_lock (file_sha256, row_num, payday, agent_name, paid_total, system_total, locked_at, note)
  values (repeat('8', 64), 1, '2026-10-23', 'Kaitlyn Romine', 100, 100, '2026-10-22 14:46', 'VERIFY short file');
  insert into public.hub_cutover (file_name, file_sha256, note) values ('VERIFY hub short', repeat('8', 64), 'VERIFY');
  perform pg_temp.r('O2. a hub file ending 10/23 is refused: 10/30 is already submitted (the cutover can''t move backwards)', false, 'recorded');
exception when others then perform pg_temp.r('O2. a hub file ending 10/23 is refused: 10/30 is already submitted (the cutover can''t move backwards)', sqlerrm like '%already submitted%', sqlerrm); end $$;
-- rev-3 B1 repros (Orchestrator): bad hub rows must never reach the immutable cutover
create temp table pay_before_hb as select sum(coalesce(final_payable, 0)) t from public.premier_recon_trueup;
do $$ begin
  insert into public.hub_paid_lock (file_sha256, row_num, payday, agent_name, paid_total, system_total, locked_at, note) values
    (repeat('7', 64), 1, '2026-10-30', 'Kaitlyn Romine', 129.50, 129.50, '2026-10-29 14:07', 'VERIFY repro 1'),
    (repeat('7', 64), 2, '2026-11-06', 'James Carangelo', 0, null, null, 'VERIFY repro 1');
  insert into public.hub_cutover (file_name, file_sha256, note) values ('VERIFY hub repro 1', repeat('7', 64), 'VERIFY');
  perform pg_temp.r('HB1. (repro 1) a hub file with 10/30 locked plus "11/06, James, 0, blank Locked At" is refused', false, 'recorded');
exception when others then perform pg_temp.r('HB1. (repro 1) a hub file with 10/30 locked plus "11/06, James, 0, blank Locked At" is refused', sqlerrm like '%Locked At is blank%', sqlerrm); end $$;
do $$ begin
  insert into public.hub_paid_lock (file_sha256, row_num, payday, agent_name, paid_total, system_total, locked_at, note) values
    (repeat('6', 64), 1, '2026-10-30', 'Kaitlyn Romine', 129.50, 129.50, '2026-10-29 14:07', 'VERIFY repro 2'),
    (repeat('6', 64), 2, '2027-10-29', 'Kaitlyn Romine', 10, 10, '2026-10-29 14:07', 'VERIFY repro 2 typo');
  insert into public.hub_cutover (file_name, file_sha256, note) values ('VERIFY hub repro 2', repeat('6', 64), 'VERIFY');
  perform pg_temp.r('HB2. (repro 2) one typo row dated 10/29/2027 is refused (after today and after last submit + 7)', false, 'recorded');
exception when others then perform pg_temp.r('HB2. (repro 2) one typo row dated 10/29/2027 is refused (after today and after last submit + 7)', sqlerrm like '%Pay Friday 2027-10-29 is after%', sqlerrm); end $$;
do $$ begin
  insert into public.hub_paid_lock (file_sha256, row_num, payday, agent_name, paid_total, system_total, locked_at, note) values
    (repeat('5', 64), 1, '2026-11-13', 'Kaitlyn Romine', 10, 10, '2026-10-29 14:07', 'VERIFY +7');
  perform pg_temp.r('HB3. a Pay Friday after the last recorded submit (10/30) + 7 days is refused, even with Locked At filled', false, 'inserted');
exception when others then perform pg_temp.r('HB3. a Pay Friday after the last recorded submit (10/30) + 7 days is refused, even with Locked At filled', sqlerrm like '%after%', sqlerrm); end $$;
do $$ begin
  insert into public.hub_paid_lock (file_sha256, row_num, payday, agent_name, paid_total, system_total, locked_at, note) values
    (repeat('4', 64), 1, '2026-10-30', 'Kaitlyn Romine', null, null, '2026-10-29 14:07', 'VERIFY blank paid');
  perform pg_temp.r('HB4. a hub row with a blank Paid Total is refused', false, 'inserted');
exception when others then perform pg_temp.r('HB4. a hub row with a blank Paid Total is refused', sqlerrm like '%Paid Total is blank%', sqlerrm); end $$;
select pg_temp.r('HB5. after the refusals nothing was written: no hub rows, no cutover, open-week payable unchanged',
  not exists (select 1 from public.hub_paid_lock) and not exists (select 1 from public.hub_cutover)
  and (select sum(coalesce(final_payable, 0)) from public.premier_recon_trueup) = (select t from pay_before_hb),
  (select format('payable=%s before=%s', (select sum(coalesce(final_payable, 0)) from public.premier_recon_trueup), t) from pay_before_hb));
-- the real (mock) hub "Paid Lock" import, run in the SQL Editor (postgres) as the script emits it
insert into public.hub_paid_lock (file_sha256, row_num, payday, agent_name, paid_total, system_total, locked_at, note) values
  (repeat('e', 64), 1, '2026-10-23', 'Nicholas Ziccardi', 119.32, 119.32, '2026-10-22 14:46', 'VERIFY mock'),
  (repeat('e', 64), 2, '2026-10-30', 'Kaitlyn Romine', 129.50, 129.50, '2026-10-29 14:07', 'VERIFY mock');
insert into public.hub_cutover (file_name, file_sha256, note) values ('VERIFY hub Paid Lock export', repeat('e', 64), 'VERIFY');
select pg_temp.r('CUT0. hub cutover recorded once: paydays 10/23 + 10/30 paid_by_hub, last 10/30, weeks frozen, event logged',
  (select last_hub_payday = '2026-10-30' and paydays = array['2026-10-23','2026-10-30']::date[] and row_count = 2 from public.hub_cutover)
  and exists (select 1 from public.event_log where event_type = 'payroll.hub_cutover.recorded')
  and exists (select 1 from public.board_week_freezes where submission_key = pg_temp.key('687990338') and week_payday = '2026-10-23')
  and not exists (select 1 from public.board_week_freezes where week_payday > '2026-10-30'),
  (select format('last=%s paydays=%s rows=%s ev=%s frozen=%s', last_hub_payday, paydays, row_count,
          (select count(*) from public.event_log where event_type = 'payroll.hub_cutover.recorded'),
          (select string_agg(submission_key || ':' || reason, ',') from public.board_week_freezes)) from public.hub_cutover));
do $$ begin
  insert into public.hub_cutover (file_name, file_sha256, note) values ('VERIFY hub again', repeat('e', 64), 'VERIFY');
  perform pg_temp.r('O3. a second hub cutover is refused (one-time event)', false, 'recorded');
exception when others then perform pg_temp.r('O3. a second hub cutover is refused (one-time event)', true, sqlerrm); end $$;
do $$ begin
  update public.hub_cutover set last_hub_payday = '2026-10-23' where true;
  perform pg_temp.r('O4. the cutover can''t be moved or reset, even by postgres (update + delete refused)', false, 'updated');
exception when others then
  begin
    delete from public.hub_cutover where true;
    perform pg_temp.r('O4. the cutover can''t be moved or reset, even by postgres (update + delete refused)', false, 'deleted');
  exception when others then perform pg_temp.r('O4. the cutover can''t be moved or reset, even by postgres (update + delete refused)', sqlerrm like '%immutable%', sqlerrm);
  end;
end $$;
do $$ begin
  insert into public.hub_paid_lock (file_sha256, row_num, payday, agent_name, paid_total, system_total, note)
  values (repeat('e', 64), 3, '2026-10-30', 'Kaitlyn Romine', 1, 1, 'VERIFY late row');
  perform pg_temp.r('O4b. no hub rows can be added after the cutover', false, 'insert succeeded');
exception when others then perform pg_temp.r('O4b. no hub rows can be added after the cutover', sqlerrm like '%already recorded%', sqlerrm); end $$;
select pg_temp.r('CUT2. hub cutover 10/30: S37 commission paid_by_hub ($0 here), final = Kyle''s +$75 only; S03 10/30 Edge $0, its 11/06 missed $20 still payable',
  (select pay_commission = 0 and final_payable = 75 and cutover_status = 'paid_by_hub' and not added_to_closed_week from public.premier_recon_trueup where member_id = '687990338')
  and (select pay_claimed_spiffs = 0 and pay_missed_spiffs = 20 from public.premier_recon_trueup where member_id = '687990121'),
  (select format('S37 final=%s status=%s added=%s', final_payable, cutover_status, added_to_closed_week) from public.premier_recon_trueup where member_id = '687990338')
   || (select format(' | S03 claimed=%s missed=%s', pay_claimed_spiffs, pay_missed_spiffs) from public.premier_recon_trueup where member_id = '687990121'));
do $$ begin
  perform public.premier_lock_payday('2026-10-30');
  perform pg_temp.r('LK1. a payday the hub paid (10/30) can''t be locked here', false, 'locked');
exception when others then perform pg_temp.r('LK1. a payday the hub paid (10/30) can''t be locked here', sqlerrm like '%hub%', sqlerrm); end $$;
do $$ begin
  perform public.premier_lock_payday('2026-11-06');
  perform pg_temp.r('LK2. a payday with no recorded submit (11/06 still provisional) can''t be locked', false, 'locked');
exception when others then perform pg_temp.r('LK2. a payday with no recorded submit (11/06 still provisional) can''t be locked', sqlerrm like '%submit%', sqlerrm); end $$;

-- ======== Submit 11/06 (SQL Editor; owner not set yet) ========
select pg_temp.act('authenticated','admin.test@example.com');
do $$ begin
  update public.payroll_cutoffs set source = 'submit', cutoff_at = '2026-11-05 14:30-05' where payday = '2026-11-06';
  reset role; perform pg_temp.r('O5. an admin (not the owner) cannot record a payroll submit', false, 'updated');
exception when others then reset role; perform pg_temp.r('O5. an admin (not the owner) cannot record a payroll submit', true, sqlerrm); end $$;
select pg_temp.srv();
update public.payroll_cutoffs set source = 'submit', cutoff_at = '2026-11-05 14:30-05', note = 'VERIFY submit' where payday = '2026-11-06';
select pg_temp.r('Q12d. recording the 11/06 submit anchors every missed spiff due on it (S33 $50, S03 $20, S20 $20 -> 11/06) and freezes its weeks',
  (select count(*) from public.missed_spiff_anchors a join public.premier_recon_lines l using (line_key)
     where a.payday = '2026-11-06' and l.member_id in ('687990310', '687990121', '687990247')) = 3
  and exists (select 1 from public.board_week_freezes where reason = 'payroll_submit' and week_payday = '2026-11-06'),
  (select string_agg(line_key || '@' || payday, ', ') from public.missed_spiff_anchors));
select pg_temp.act('authenticated','admin2.test@example.com');
do $$ declare n int; begin
  n := public.premier_lock_payday('2026-11-06');
  reset role; perform pg_temp.r('W0f. (Orchestrator repro) owner UNSET, after the postgres cutover + submit: an admin cannot lock 11/06', false, 'locked ' || n || ' rows');
exception when others then reset role; perform pg_temp.r('W0f. (Orchestrator repro) owner UNSET, after the postgres cutover + submit: an admin cannot lock 11/06', sqlerrm like '%owner only%', sqlerrm); end $$;
select pg_temp.srv();
select pg_temp.act('authenticated','admin.test@example.com');
do $$ begin
  update public.payroll_cutoffs set cutoff_at = cutoff_at + interval '1 day' where payday = '2026-11-06';
  reset role; perform pg_temp.r('O6. a recorded submit is final for admins (no edit, no delete)', false, 'updated');
exception when others then reset role; perform pg_temp.r('O6. a recorded submit is final for admins (no edit, no delete)', true, sqlerrm); end $$;
select pg_temp.srv();
create temp table lk as select public.premier_lock_payday('2026-11-06') n1, public.premier_lock_payday('2026-11-06') n2;
select pg_temp.r('C6. lock 11/06 writes payroll-actual rows once (second call 0); OPEN and held rows are not locked',
  (select n1 > 0 and n2 = 0 from lk) and not exists (select 1 from public.pay_line_locks k join L on L.line_key = k.line_key where L.open_item is not null),
  (select format('locked=%s again=%s', n1, n2) from lk));
do $$ begin
  update public.pay_line_locks set amount = 0 where true;
  perform pg_temp.r('C7. locks are immutable', false, 'update succeeded');
exception when others then perform pg_temp.r('C7. locks are immutable', sqlerrm like '%immutable%', sqlerrm); end $$;

-- RE2. Export E AFTER the 11/06 submit + lock (closed week): S01's agent changes again; S31 comes back with a new Timestamp.
select pg_temp.mk('VERIFY export E (closed-week edits)', repeat('2', 64));
insert into public.board_submissions (import_id, row_num, raw_fields)
select pg_temp.imp('VERIFY export E (closed-week edits)'), row_number() over (order by x.f[1]), x.f from (
  select case k when pg_temp.key('687990107') then f[1:5] || array['Suzelaine Similien'] || f[7:42] else f end f from pg_temp.latest()
  union all select array['10/30/2026 13:03:25'] || b.raw_fields[2:42] from public.board_submissions b where b.submission_key = '20261030130255' and b.import_id = pg_temp.imp('VERIFY export C (S01 agent, S02 premium)')
  union all select array['10/30/2026 16:30:00', '687990177'] || b.raw_fields[3:42] from public.board_submissions_current b where b.member_id = '687990107') x;
select public.recon_finalize_board_import(pg_temp.imp('VERIFY export E (closed-week edits)'));
select pg_temp.r('RE2. closed week: S01 change NOT applied (frozen: Chris 137.56, one commission lock), flagged closed_week_change',
  (select count(*) from public.premier_recon_trueup where member_id = '687990107') = 1
  and (select count(*) from public.pay_line_locks where component = 'commission' and line_key = (select line_key from public.premier_recon_lines where member_id = '687990107')) = 1
  and (select agent_name = 'Chris Wilfong' and locked_commission = 137.56 and final_payable = 137.56 and closed_week_change
         from public.premier_recon_trueup where member_id = '687990107'),
  (select format('agent=%s locked_by=%s final=%s flag=%s', agent_name, locked_agent_names, final_payable, closed_week_change)
     from public.premier_recon_trueup where member_id = '687990107'));
select pg_temp.r('RE2b. S31 re-added to a closed week with a new Timestamp: held + flagged, pays nothing extra (duplicate of the locked deal); old frozen row keeps its $20 lock once',
  (select added_to_closed_week and coalesce(final_payable, 0) = 0 and hold_status = 'held_added_to_closed_week' from public.premier_recon_trueup where line_key = '20261030130325-ABS')
  and (select count(*) from public.pay_line_locks where line_key like '20261030130%-ABS') = 1
  and (select sum(final_payable) from public.premier_recon_trueup where line_key like '20261030130%-ABS') = 20,
  (select string_agg(line_key || ' ' || coalesce(final_payable::text, 'NULL') || ' ' || coalesce(hold_status, '-'), ', ') from public.premier_recon_trueup where line_key like '20261030130%-ABS'));
select pg_temp.r('RE2d. a brand-new deal first seen in a closed week (S11''s member, 10/30) is held: pay NULL, not locked, Kyle decides',
  (select added_to_closed_week and final_payable is null and hold_status = 'held_added_to_closed_week' and not commission_locked
     from public.premier_recon_trueup where line_key = '20261030163000-P'),
  (select format('final=%s hold=%s status=%s actual=%s', final_payable, hold_status, line_status, stage2_premier_corrected) from public.premier_recon_trueup where line_key = '20261030163000-P'));
select public.premier_log_recon_events();
select pg_temp.r('RE2c. closed-week changes are flags only: board.closed_week_change + board.added_to_closed_week logged, no revised event',
  exists (select 1 from public.event_log where event_type = 'board.closed_week_change' and row_id like pg_temp.key('687990107') || '%')
  and exists (select 1 from public.event_log where event_type = 'board.added_to_closed_week' and row_id like '20261030130325%')
  and not exists (select 1 from public.event_log where detail ->> 'kind' = 'board_submission_revised' and detail::text like '%Suzelaine Similien%'));

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
select pg_temp.r('C8b. that premium change is logged once as premium_mismatch 427 -> 448',
  exists (select 1 from public.event_log where event_type='premium_mismatch' and detail->>'member_id'='687990240' and (detail->>'from')::numeric=427 and (detail->>'to')::numeric=448));
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

-- Q12 missed spiffs (Kyle 10/31: next open payday, anchored at first detection)
select pg_temp.r('Q12a. S33 missed Edge $50 (board AO blank) is anchored to 11/06, the next open payday when first seen',
  (select missed_spiffs = 50 and missed_spiff_pay_friday = '2026-11-06' and missed_spiff_anchored from public.premier_recon_lines where member_id = '687990310')
  and (select missed_spiff_payday_status = 'confirmed' from public.recon_pay_config where id));
select pg_temp.r('Q12b. S03: board-claimed Edge $50 stays on 10/30, missed Wellness $20 on 11/06; S20 missed Asset $20 on 11/06',
  (select actual_spiffs = 70 and missed_spiffs = 20 and spiff_pay_friday = '2026-10-30' and missed_spiff_pay_friday = '2026-11-06'
     from public.premier_recon_lines where member_id = '687990121')
  and (select missed_spiffs = 20 and missed_spiff_pay_friday = '2026-11-06' from public.premier_recon_lines where member_id = '687990247'));
update public.recon_pay_config set missed_spiff_payday = 'booked_cycle' where id;
select pg_temp.r('Q12c. config booked_cycle puts S33''s missed spiff back on its Date Booked cycle (10/30)',
  (select missed_spiff_pay_friday = '2026-10-30' from public.premier_recon_lines where member_id = '687990310'));
update public.recon_pay_config set missed_spiff_payday = 'next_open_payday' where id;
select pg_temp.r('N2. imported hub adjustment: component from the file (S37: no Covers -> other); admin-key path refused, entered as audited postgres break-glass',
  (select component = 'other' and entered_by = 'break-glass:postgres' and source_entered_by = 'Kyle' from public.pay_adjustments where member_id = '687990338')
  and exists (select 1 from public.event_log where event_type = 'payroll.adjustment.break_glass'),
  (select entered_by from public.pay_adjustments where member_id = '687990338'));

-- ======== Payroll owner (rev-2 item 2): only the current owner, or postgres in the SQL Editor, may set it ========
insert into auth.users (email) values ('admin2.test@example.com');
insert into public.agents (display_name, email, role, user_id)
select 'Second Admin (fake)', 'admin2.test@example.com', 'admin', id from auth.users where email = 'admin2.test@example.com';
select pg_temp.act('authenticated','admin.test@example.com');
insert into public.pay_adjustments (agent_name, payday, kind, amount, reason, entered_by, entered_by_uid, created_by, agent_id, source_entered_by, external_ref)
values ('Chris Wilfong', '2026-11-13', 'manual', 5, 'VERIFY owner unset', 'Kyle', '00000000-0000-0000-0000-0000000000b1',
        '00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000b3', 'Kyle (file text)', 'verify-k1');
select pg_temp.srv();
select pg_temp.r('K1. (rev 4) any admin CAN record an adjustment (owner not set); spoofed entered_by / entered_by_uid / created_by / agent_id ignored (auth.uid() + server-side agent lookup); file text kept apart',
  (select entered_by = 'Test Admin (fake)' and entered_by_uid = (select id from auth.users where email = 'admin.test@example.com')
          and created_by = entered_by_uid and agent_id is null and source_entered_by = 'Kyle (file text)'
     from public.pay_adjustments where external_ref = 'verify-k1'),
  (select format('entered_by=%s agent_id=%s', entered_by, agent_id) from public.pay_adjustments where external_ref = 'verify-k1'));
select pg_temp.r('K1b. every adjustment is audited twice: the row audit (INSERT) and payroll.adjustment.recorded',
  exists (select 1 from public.event_log e join public.pay_adjustments a on a.id::text = e.row_id
           where e.event_type = 'payroll.adjustment.recorded' and a.external_ref = 'verify-k1')
  and exists (select 1 from public.event_log e join public.pay_adjustments a on a.id::text = e.row_id
               where e.table_name = 'pay_adjustments' and e.action = 'INSERT' and a.external_ref = 'verify-k1'),
  (select string_agg(e.event_type || '/' || e.action, ', ') from public.event_log e join public.pay_adjustments a on a.id::text = e.row_id where a.external_ref = 'verify-k1'));
do $$ begin
  update public.pay_adjustments set amount = 500 where external_ref = 'verify-k1';
  perform pg_temp.r('K1c. an adjustment row is immutable (update refused, even for postgres)', false, 'updated');
exception when others then perform pg_temp.r('K1c. an adjustment row is immutable (update refused, even for postgres)', true, sqlerrm); end $$;
select pg_temp.r('K2b. the RLS insert policy and the trigger agree: the policy checks is_admin() (no owner condition)',
  (select count(*) = 1 and bool_and(with_check like '%is_admin()%' and with_check not like '%payroll_owner%')
     from pg_policies where tablename = 'pay_adjustments' and cmd = 'INSERT'),
  (select string_agg(policyname || ': ' || with_check, '; ') from pg_policies where tablename = 'pay_adjustments' and cmd = 'INSERT'));
select pg_temp.act('anon','agent.test@example.com');
do $$ begin
  insert into public.pay_adjustments (agent_name, payday, kind, amount, reason) values ('Test', '2026-11-13', 'manual', 5, 'anon write');
  reset role; perform pg_temp.r('K2c. anon is refused', false, 'insert succeeded');
exception when others then reset role; perform pg_temp.r('K2c. anon is refused', true, sqlerrm); end $$;
select pg_temp.act('authenticated','admin2.test@example.com');
do $$ begin
  perform public.recon_freeze_closed_weeks('2026-11-06', 'payroll_submit');
  reset role; perform pg_temp.r('K3c. freezing weeks stays owner / postgres only (a non-owner admin is refused)', false, 'ran');
exception when others then reset role; perform pg_temp.r('K3c. freezing weeks stays owner / postgres only (a non-owner admin is refused)', sqlerrm like '%owner or SQL Editor%', sqlerrm); end $$;
select pg_temp.act('authenticated','admin2.test@example.com');
do $$ begin
  update public.recon_pay_config set payroll_owner_user_id = auth.uid() where id;
  reset role; perform pg_temp.r('O7. owner NULL: an admin cannot make themselves the payroll owner', false, 'updated');
exception when others then reset role; perform pg_temp.r('O7. owner NULL: an admin cannot make themselves the payroll owner', sqlerrm like '%payroll owner%', sqlerrm); end $$;
select pg_temp.act('service_role','admin2.test@example.com');
do $$ begin
  update public.recon_pay_config set payroll_owner_user_id = '00000000-0000-0000-0000-0000000000a2' where id;
  reset role; perform pg_temp.r('O8. owner NULL: the admin key (service_role) cannot set the owner either', false, 'updated');
exception when others then reset role; perform pg_temp.r('O8. owner NULL: the admin key (service_role) cannot set the owner either', sqlerrm like '%payroll owner%', sqlerrm); end $$;
select pg_temp.srv();
-- ======== rev 4: owner-only actions with the payroll owner UNSET (Orchestrator review of 2b5187d, B1: must fail CLOSED) ========
select pg_temp.srv();
insert into public.agent_name_aliases (alias, agent_id) select 'VERIFY seed alias', id from public.agents where role = 'agent' limit 1;
insert into public.payroll_cutoffs (payday, cutoff_at, source, note) values ('2026-12-04', '2026-12-03 14:00-05', 'provisional', 'VERIFY provisional');
create temp table wstmts (t text, op text, sql text);
insert into wstmts values
 ('commission_config','insert','insert into public.commission_config (id) values (false)'),
 ('commission_config','update','update public.commission_config set base_rate = 0.40 where id'),
 ('commission_config','delete','delete from public.commission_config where id'),
 ('premier_addon_map','insert','insert into public.premier_addon_map (source, pattern, addon_key) values (''premier_label'', ''vw'', ''add_type'')'),
 ('premier_addon_map','update','update public.premier_addon_map set status = ''proposed'' where strpos(pattern, ''protect'') > 0'),
 ('premier_addon_map','delete','delete from public.premier_addon_map where strpos(pattern, ''protect'') > 0'),
 ('agent_pay_rules','insert','insert into public.agent_pay_rules (agent_name, base_rate_override) values (''VERIFY agent'', 0.5)'),
 ('agent_pay_rules','update','update public.agent_pay_rules set base_rate_override = 0.5 where agent_name = ''Kaitlyn Romine'''),
 ('agent_pay_rules','delete','delete from public.agent_pay_rules where agent_name = ''Kaitlyn Romine'''),
 ('agent_name_aliases','insert','insert into public.agent_name_aliases (alias, agent_id) select ''VERIFY alias 2'', id from public.agents limit 1'),
 ('agent_name_aliases','update','update public.agent_name_aliases set note = ''x'' where alias = ''VERIFY seed alias'''),
 ('agent_name_aliases','delete','delete from public.agent_name_aliases where alias = ''VERIFY seed alias'''),
 ('recon_pay_config','insert','insert into public.recon_pay_config (id) values (false)'),
 ('recon_pay_config','update','update public.recon_pay_config set spiff_cc_edge = 99 where id'),
 ('recon_pay_config','delete','delete from public.recon_pay_config where id'),
 ('payroll_cutoffs','insert','insert into public.payroll_cutoffs (payday, cutoff_at, source) values (''2027-01-01'', ''2026-12-31 14:00-05'', ''provisional'')'),
 ('payroll_cutoffs','update','update public.payroll_cutoffs set cutoff_at = cutoff_at + interval ''1 hour'' where payday = ''2026-12-04'''),
 ('payroll_cutoffs','delete','delete from public.payroll_cutoffs where payday = ''2026-12-04'''),
 ('manual_entry_sources','insert','insert into public.manual_entry_sources (kind, code, label, pl_line) values (''transfer'', ''vw'', ''VW'', ''transfers_ringba'')'),
 ('manual_entry_sources','update','update public.manual_entry_sources set label = ''X'' where code = ''ringba'''),
 ('manual_entry_sources','delete','delete from public.manual_entry_sources where code = ''ringba''');
select pg_temp.r('W0. (precondition) payroll owner is NULL here', (select payroll_owner_user_id is null from public.recon_pay_config where id));
do $$ declare w record; who text; ok int; bad text; msg text; begin
  foreach who in array array['admin.test@example.com', 'admin2.test@example.com'] loop
    ok := 0; bad := null;
    for w in select * from wstmts loop
      perform pg_temp.act('authenticated', who);
      begin
        execute w.sql;
        bad := concat_ws(', ', bad, w.t || ' ' || w.op);
      exception when others then
        msg := sqlerrm;
        if msg ~ '(owner-only|permission denied)' then ok := ok + 1;
        else bad := concat_ws(', ', bad, w.t || ' ' || w.op || ': ' || msg); end if;
      end;
      perform pg_temp.srv();
    end loop;
    perform pg_temp.r('W0a. owner UNSET: admin ' || who || ' is refused on insert, update and delete of every pay-config table (7 x 3)',
      ok = 21 and bad is null, format('refused=%s/21 not refused: %s', ok, coalesce(bad, 'none')));
  end loop;
end $$;
do $$ declare st text; who text; bad text; msg text; n int := 0; begin
  foreach who in array array['admin.test@example.com', 'admin2.test@example.com'] loop
    foreach st in array array[
      'select public.premier_lock_payday(''2026-11-06'')',
      'update public.payroll_cutoffs set source = ''submit'', cutoff_at = ''2026-11-05 14:30-05'' where payday = ''2026-11-06''',
      'insert into public.payroll_cutoffs (payday, cutoff_at, source) values (''2026-12-11'', ''2026-12-10 14:00-05'', ''submit'')',
      'insert into public.hub_paid_lock (file_sha256, row_num, payday, agent_name, paid_total, locked_at) values (repeat(''d'', 64), 1, ''2026-10-30'', ''Chris Wilfong'', 1, now())',
      'insert into public.hub_cutover (file_name, file_sha256, note) values (''VERIFY'', repeat(''d'', 64), ''VERIFY'')',
      'select public.recon_freeze_closed_weeks(''2026-11-06'', ''payroll_submit'')',
      'update public.recon_pay_config set payroll_owner_user_id = auth.uid() where id'] loop
      perform pg_temp.act('authenticated', who);
      begin
        execute st;
        bad := concat_ws(' | ', bad, who || ': ' || st);
      exception when others then
        msg := sqlerrm;
        if msg ~* '(owner|SQL Editor|permission denied)' then n := n + 1;
        else bad := concat_ws(' | ', bad, who || ': ' || left(st, 40) || ' -> ' || msg); end if;
      end;
      perform pg_temp.srv();
    end loop;
  end loop;
  perform pg_temp.r('W0b. owner UNSET: lock, submit (update + insert), hub cutover (rows + record), freeze and taking ownership are refused for both admins',
    n = 14 and bad is null, format('refused=%s/14 not refused: %s', n, coalesce(bad, 'none')));
end $$;
select pg_temp.srv();
do $$ declare w record; n int := 0; bad text; ws text[][]; begin
  select array_agg(array[t, op, sql]) into ws from wstmts where (op = 'insert' and t not in ('commission_config', 'recon_pay_config')) or op = 'update';
  begin
    for w in select ws[i][1] t, ws[i][2] op, ws[i][3] sql from generate_subscripts(ws, 1) i loop
      begin execute w.sql; n := n + 1;
      exception when others then bad := concat_ws(', ', bad, w.t || ' ' || w.op || ': ' || sqlerrm); end;
    end loop;
    raise exception 'undo';
  exception when others then
    if sqlerrm <> 'undo' then bad := concat_ws(', ', bad, sqlerrm); end if;
  end;
  perform pg_temp.r('W0c. owner UNSET: postgres in the SQL Editor (break-glass) can still write every pay-config table (changes undone)',
    bad is null and n = 12, format('ok=%s problems: %s', n, coalesce(bad, 'none')));
end $$;
select pg_temp.act('service_role', 'admin2.test@example.com');
do $$ begin
  update public.commission_config set base_rate = 0.50 where id;
  reset role; perform pg_temp.r('W0d. owner UNSET: the admin key (service_role) cannot change commission_config either', false, 'updated');
exception when others then reset role; perform pg_temp.r('W0d. owner UNSET: the admin key (service_role) cannot change commission_config either', sqlerrm like '%owner-only%', sqlerrm); end $$;
select pg_temp.srv();
select pg_temp.r('W0e. owner UNSET: nothing the admins tried changed (rate 0.38, both ADD exclusions active, Kaitlyn rule, no owner)',
  (select base_rate = 0.38 from public.commission_config where id)
  and (select count(*) = 2 from public.premier_addon_map where source = 'premier_label_exclude' and active)
  and exists (select 1 from public.agent_pay_rules where agent_name = 'Kaitlyn Romine')
  and (select payroll_owner_user_id is null from public.recon_pay_config where id));

-- the apply step does this in the SQL Editor (from /workspace/secrets/payroll_owner_user_id.txt once Kyle has an account)
update public.recon_pay_config set payroll_owner_user_id = (select id from auth.users where email = 'admin.test@example.com') where id;
select pg_temp.act('authenticated','admin2.test@example.com');
do $$ begin
  update public.recon_pay_config set payroll_owner_user_id = auth.uid() where id;
  insert into public.pay_adjustments (agent_name, payday, kind, amount, reason, entered_by) values ('Chris Wilfong', '2026-11-13', 'manual', 5, 'VERIFY takeover', 'Kyle');
  reset role; perform pg_temp.r('O9. (Orchestrator repro) another admin still cannot take ownership (the whole attempt rolls back)', false, 'took over');
exception when others then reset role; perform pg_temp.r('O9. (Orchestrator repro) another admin still cannot take ownership (the whole attempt rolls back)', sqlerrm like '%payroll owner%', sqlerrm); end $$;
select pg_temp.act('authenticated','admin2.test@example.com');
insert into public.pay_adjustments (agent_name, payday, kind, amount, reason, entered_by, external_ref)
values ('Chris Wilfong', '2026-11-13', 'manual', 5, 'VERIFY other admin', 'Kyle', 'verify-k3');
select pg_temp.srv();
select pg_temp.r('K3. (rev 4) another admin (not the owner) CAN record one; claiming entered_by = Kyle is ignored (stamped as that admin), audited',
  (select entered_by = 'Second Admin (fake)' and entered_by_uid = (select id from auth.users where email = 'admin2.test@example.com')
     from public.pay_adjustments where external_ref = 'verify-k3')
  and exists (select 1 from public.event_log e join public.pay_adjustments a on a.id::text = e.row_id
               where e.event_type = 'payroll.adjustment.recorded' and a.external_ref = 'verify-k3'),
  (select format('entered_by=%s', entered_by) from public.pay_adjustments where external_ref = 'verify-k3'));
select pg_temp.r('K3b. the admin is still not the owner: payroll_owner_user_id unchanged (Kyle''s / the configured owner)',
  (select payroll_owner_user_id = (select id from auth.users where email = 'admin.test@example.com') from public.recon_pay_config where id));
select pg_temp.act('authenticated','admin.test@example.com');
insert into public.pay_adjustments (agent_name, payday, kind, amount, reason, entered_by, external_ref)
values ('Chris Wilfong', '2026-11-13', 'manual', 5, 'VERIFY owner entry', 'Somebody Else', 'verify-owner-1');
select pg_temp.srv();
select pg_temp.r('K2. the owner (Kyle) can record one too; a spoofed entered_by is ignored (set from auth.uid() server-side)',
  (select entered_by = 'Test Admin (fake)' and entered_by_uid = (select id from auth.users where email = 'admin.test@example.com')
     from public.pay_adjustments where external_ref = 'verify-owner-1'),
  (select format('entered_by=%s', entered_by) from public.pay_adjustments where external_ref = 'verify-owner-1'));
select pg_temp.act('authenticated','agent.test@example.com');
do $$ begin
  insert into public.pay_adjustments (agent_name, payday, kind, amount, reason, entered_by) values ('Alex Testagent (fake)', '2026-11-13', 'manual', 50, 'VERIFY self-pay', 'Kyle');
  reset role; perform pg_temp.r('K6. a signed-in non-admin (agent) is refused, even claiming entered_by = Kyle', false, 'insert succeeded');
exception when others then reset role; perform pg_temp.r('K6. a signed-in non-admin (agent) is refused, even claiming entered_by = Kyle', true, sqlerrm); end $$;
select pg_temp.act('authenticated','admin2.test@example.com');
do $$ begin
  insert into public.payroll_cutoffs (payday, cutoff_at, source, note) values ('2026-11-20', '2026-11-19 14:30-05', 'submit', 'VERIFY admin2 submit');
  reset role; perform pg_temp.r('K7. owner-only stays owner-only: a non-owner admin still can''t record a payroll submit', false, 'inserted');
exception when others then reset role; perform pg_temp.r('K7. owner-only stays owner-only: a non-owner admin still can''t record a payroll submit', sqlerrm like '%payroll owner%', sqlerrm); end $$;
select pg_temp.act('service_role','admin.test@example.com');
do $$ begin
  insert into public.pay_adjustments (agent_name, payday, kind, amount, reason, entered_by) values ('Chris Wilfong', '2026-11-13', 'manual', 5, 'VERIFY admin key', 'Kyle');
  reset role; perform pg_temp.r('K4. adjustments with the admin key (service_role) are refused (Kyle 10/31)', false, 'insert succeeded');
exception when others then reset role; perform pg_temp.r('K4. adjustments with the admin key (service_role) are refused (Kyle 10/31)', sqlerrm like '%service_role%', sqlerrm); end $$;
select pg_temp.act('authenticated','admin.test@example.com');
update public.recon_pay_config set adjustment_server_path = 'off' where id;   -- the owner may switch the break-glass path off
select pg_temp.srv();
do $$ begin
  insert into public.pay_adjustments (agent_name, payday, kind, amount, reason, entered_by) values ('Chris Wilfong', '2026-11-13', 'manual', 5, 'VERIFY break glass off', 'Kyle');
  perform pg_temp.r('K5. with the break-glass path off, even postgres is refused; only the owner can turn it back on', false, 'insert succeeded');
exception when others then perform pg_temp.r('K5. with the break-glass path off, even postgres is refused; only the owner can turn it back on', sqlerrm like '%off%', sqlerrm); end $$;
select pg_temp.act('authenticated','admin2.test@example.com');
do $$ begin
  update public.recon_pay_config set adjustment_server_path = 'postgres_break_glass' where id;
  reset role; perform pg_temp.r('K5b. a non-owner admin can''t change the break-glass setting', false, 'updated');
exception when others then reset role; perform pg_temp.r('K5b. a non-owner admin can''t change the break-glass setting', true, sqlerrm); end $$;
select pg_temp.act('authenticated','admin.test@example.com');
update public.recon_pay_config set adjustment_server_path = 'postgres_break_glass' where id;
select pg_temp.srv();

-- Agents see their own adjustment (amount + note), never the internal note, only after the payday's submit; linked by agent id
insert into public.pay_adjustments (agent_name, payday, kind, amount, reason, internal_note, external_ref) values
  ('Alex Testagent (fake)', '2026-10-30', 'manual', 12.5, 'VERIFY visible note', 'VERIFY SECRET internal', 'verify-agent-1'),
  ('Alex Testagent (fake)', '2026-11-13', 'manual', 7, 'VERIFY not yet visible', null, 'verify-agent-2'),
  ('Chris Wilfong', '2026-10-30', 'manual', 9, 'VERIFY someone else', null, 'verify-agent-3');
update public.agents set display_name = 'Alex Renamed (fake)' where email = 'agent.test@example.com';   -- rename after entry
select pg_temp.act('authenticated','agent.test@example.com');
create temp table mine as select * from public.my_pay_adjustments();
select pg_temp.srv();
select pg_temp.r('V1. agent sees only their own released adjustment: amount 12.50 + note; no internal note, no other agent, not the 11/13 one',
  (select count(*) = 1 and bool_and(amount = 12.5 and note = 'VERIFY visible note') from mine)
  and not exists (select 1 from mine m where to_jsonb(m)::text like '%SECRET%')
  and (select count(*) from information_schema.columns where table_name = 'mine' and column_name in ('internal_note', 'entered_by')) = 0,
  (select string_agg(to_jsonb(m)::text, '; ') from mine m));
select pg_temp.r('N3. agents are linked by agent id, not display name: the row stays the agent''s after a rename; unknown names get no id',
  (select agent_id = (select id from public.agents where email = 'agent.test@example.com') from public.pay_adjustments where external_ref = 'verify-agent-1')
  and (select agent_id is null from public.pay_adjustments where external_ref = 'verify-agent-3'));
insert into public.agent_name_aliases (alias, agent_id, note)
select 'Chris Wilfong', id, 'VERIFY alias' from public.agents where email = 'admin.test@example.com';
select pg_temp.r('N3b. an alias row links a board/hub spelling to an agent id (new adjustments + board rows resolve through it)',
  public.recon_agent_id('Chris Wilfong') = (select id from public.agents where email = 'admin.test@example.com'));

-- ======== Rev-2 item 1 repro: missed spiffs must not be paid twice ========
select pg_temp.act('authenticated','admin.test@example.com');   -- the owner records the 11/13 submit
insert into public.payroll_cutoffs (payday, cutoff_at, source, note) values ('2026-11-13', '2026-11-12 14:30-05', 'submit', 'VERIFY submit 11/13');
select pg_temp.srv();
select pg_temp.r('Q12R1. after the 11/13 submit S33''s missed $50 stays on 11/06 (anchored; rev 2 moved it to 11/13)',
  (select missed_spiff_pay_friday = '2026-11-06' from public.premier_recon_lines where member_id = '687990310'),
  (select missed_spiff_pay_friday::text from public.premier_recon_lines where member_id = '687990310'));
create temp table lk13 as select public.premier_lock_payday('2026-11-13') n;
select pg_temp.r('Q12R2. locking 11/13 adds NO second missed-spiff lock: S33 and S03 each have exactly one, on 11/06',
  (select count(*) = 2 and bool_and(payday = '2026-11-06') from public.pay_line_locks k join public.premier_recon_lines l using (line_key)
     where k.component = 'missed_spiffs' and l.member_id in ('687990310', '687990121')),
  (select string_agg(l.member_id || ' ' || k.payday || ' ' || k.amount, ', ') from public.pay_line_locks k join public.premier_recon_lines l using (line_key) where k.component = 'missed_spiffs'));
select pg_temp.r('Q12R3. true-up pays S33 $50 missed once and S03 $20 missed once (locks summed across paydays)',
  (select pay_missed_spiffs = 50 from public.premier_recon_trueup where member_id = '687990310')
  and (select pay_missed_spiffs = 20 from public.premier_recon_trueup where member_id = '687990121'),
  (select string_agg(member_id || ' missed=' || pay_missed_spiffs || ' on ' || coalesce(locked_on, '-'), ', ') from public.premier_recon_trueup where member_id in ('687990310', '687990121')));
do $$ begin
  insert into public.pay_line_locks (line_key, component, payday, agent_name, stage, amount)
  select line_key, 'missed_spiffs', '2026-11-13', agent_name, 'payroll_actual', 50 from public.premier_recon_lines where member_id = '687990310';
  perform pg_temp.r('Q12R4. the database itself refuses a second lock of the same line + component (unique constraint)', false, 'insert succeeded');
exception when unique_violation then perform pg_temp.r('Q12R4. the database itself refuses a second lock of the same line + component (unique constraint)', true, sqlerrm); end $$;
do $$ begin
  perform public.premier_lock_payday('2026-11-20');
  perform pg_temp.r('LK3. 11/20 (no submit recorded) can''t be locked', false, 'locked');
exception when others then perform pg_temp.r('LK3. 11/20 (no submit recorded) can''t be locked', sqlerrm like '%submit%', sqlerrm); end $$;

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
create temp table seen as select count(*) n from public.premier_recon_lines;
reset role;
select pg_temp.r('R4. admin user sees the same reconciliation lines as the owner role',
  (select n from seen) = (select count(*) from public.premier_recon_lines) and (select n from seen) > 0,
  (select format('admin=%s owner=%s', (select n from seen), count(*)) from public.premier_recon_lines));


-- ======== rev 4: owner-only pay config (Kyle 7:14 PM ET), owner SET ========
do $$ declare w record; who text; em text; ok int; bad text; msg text; begin
  foreach who in array array['admin2', 'service_role'] loop
    ok := 0; bad := null;
    for w in select * from wstmts loop
      perform pg_temp.act(case when who = 'service_role' then 'service_role' else 'authenticated' end, 'admin2.test@example.com');
      begin
        execute w.sql;
        bad := concat_ws(', ', bad, w.t || ' ' || w.op);
      exception when others then
        msg := sqlerrm;
        if msg ~ '(owner-only|permission denied|service_role)' then ok := ok + 1;
        else bad := concat_ws(', ', bad, w.t || ' ' || w.op || ': ' || msg); end if;
      end;
      perform pg_temp.srv();
    end loop;
    perform pg_temp.r(case who when 'admin2' then 'W1. a second (non-owner) admin is refused on insert, update and delete of every pay-config table (7 tables x 3)'
                      else 'W2. the admin key (service_role) is refused on insert, update and delete of every pay-config table' end,
      ok = 21 and bad is null, format('refused=%s/21 not refused: %s', ok, coalesce(bad, 'none')));
  end loop;
end $$;
select pg_temp.act('authenticated','admin2.test@example.com');
do $$ begin
  perform public.premier_lock_payday('2026-11-13');
  reset role; perform pg_temp.r('W3. a second admin cannot lock a payday (owner only)', false, 'locked');
exception when others then reset role; perform pg_temp.r('W3. a second admin cannot lock a payday (owner only)', sqlerrm like '%owner only%', sqlerrm); end $$;
select pg_temp.act('service_role','admin2.test@example.com');
do $$ begin
  perform public.premier_lock_payday('2026-11-13');
  reset role; perform pg_temp.r('W3b. the admin key (service_role) cannot lock a payday', false, 'locked');
exception when others then reset role; perform pg_temp.r('W3b. the admin key (service_role) cannot lock a payday', sqlerrm like '%owner only%', sqlerrm); end $$;
select pg_temp.srv();
do $$ declare w record; n int := 0; bad text; ws text[][]; begin
  select array_agg(array[t, op, sql]) into ws from wstmts where (op = 'insert' and t not in ('commission_config', 'recon_pay_config')) or op = 'update';
  begin
    perform pg_temp.act('authenticated', 'admin.test@example.com');   -- the payroll owner
    for w in select ws[i][1] t, ws[i][2] op, ws[i][3] sql from generate_subscripts(ws, 1) i loop
      begin execute w.sql; n := n + 1;
      exception when others then bad := concat_ws(', ', bad, w.t || ' ' || w.op || ': ' || sqlerrm); end;
    end loop;
    perform public.premier_lock_payday('2026-11-13');
    n := n + 1;
    raise exception 'undo';
  exception when others then
    if sqlerrm <> 'undo' then bad := concat_ws(', ', bad, 'lock: ' || sqlerrm); end if;
  end;
  perform pg_temp.srv();
  perform pg_temp.r('W4. the payroll owner can write every pay-config table and lock a payday (changes undone)',
    bad is null and n = 13, format('ok=%s problems: %s', n, coalesce(bad, 'none')));
end $$;
select pg_temp.act('authenticated','admin2.test@example.com');
create temp table wread as select
  (select count(*) from public.commission_config) cc, (select count(*) from public.premier_addon_map) am,
  (select count(*) from public.agent_pay_rules) apr, (select count(*) from public.agent_name_aliases) ali,
  (select count(*) from public.recon_pay_config) rpc, (select count(*) from public.payroll_cutoffs) pc,
  (select count(*) from public.manual_entry_sources) mes;
reset role; select pg_temp.srv();
select pg_temp.r('W5. a second admin still reads every pay-config table',
  (select cc = 1 and am > 0 and apr > 0 and ali > 0 and rpc = 1 and pc > 0 and mes = 9 from wread),
  (select format('commission_config=%s addon_map=%s pay_rules=%s aliases=%s recon_pay_config=%s cutoffs=%s entry_sources=%s', cc, am, apr, ali, rpc, pc, mes) from wread));

-- ======== rev 4: manual entries + the P&L walk (Kyle 7:15 / 7:19 / 7:20 PM ET) ========
select pg_temp.act('authenticated','admin2.test@example.com');
insert into public.manual_entries (kind, source, entry_date, period, amount, note, entered_by) values
  ('credit',      null,             '2026-10-30', 'day',  500,  'VERIFY credits', 'Kyle'),
  ('debit',       null,             '2026-10-30', 'day',  120,  'VERIFY debits', 'Kyle'),
  ('transfer',    'ringba',         '2026-10-30', 'day',  300,  'VERIFY ringba', null),
  ('transfer',    'acme',           '2026-10-30', 'day',  200,  'VERIFY acme', null),
  ('lead_spend',  'keystone_data',  '2026-10-30', 'day',  150,  'VERIFY spend', null),
  ('lead_spend',  'ppc_data',       '2026-10-30', 'day',  50,   'VERIFY spend 2', null),
  ('deposit_box', 'allstate_earned','2026-10-25', 'week', 1000, 'VERIFY allstate', null),
  ('deposit_box', 'premier_book',   '2026-10-25', 'week', 400,  'VERIFY premier book', null),
  ('deposit_box', 'neo_book',       '2026-10-25', 'week', 250,  'VERIFY neo (monthly, put in this week)', null),
  ('deposit_box', 'oneil_aca',      '2026-10-25', 'week', 100,  'VERIFY oneil', null),
  ('premier_premium', null,         '2026-10-30', 'day',  999,  'VERIFY premium entered', null),
  ('policy_count', null,            '2026-10-30', 'day',  3.5,  'VERIFY count', null);
reset role; select pg_temp.srv();
select pg_temp.r('ME1. any admin (not the owner) enters every kind; entered_by comes from the login (spoofed "Kyle" ignored), audit rows written',
  (select count(*) = 12 and bool_and(entered_by = 'Second Admin (fake)') and bool_and(entered_by_uid = (select id from auth.users where email = 'admin2.test@example.com'))
     from public.manual_entries where note like 'VERIFY%')
  and (select count(*) >= 12 from public.event_log where table_name = 'manual_entries' and action = 'INSERT'),
  (select string_agg(distinct entered_by, ',') from public.manual_entries));
select pg_temp.act('authenticated','agent.test@example.com');
do $$ begin
  insert into public.manual_entries (kind, entry_date, period, amount) values ('credit', '2026-10-30', 'day', 1);
  reset role; perform pg_temp.r('ME2. an agent cannot enter', false, 'inserted');
exception when others then reset role; perform pg_temp.r('ME2. an agent cannot enter', true, sqlerrm); end $$;
select pg_temp.act('authenticated','agent.test@example.com');
create temp table meag as select (select count(*) from public.manual_entries) + (select count(*) from public.manual_entries_current)
  + (select count(*) from public.pl_daily_walk) + (select count(*) from public.pl_weekly_walk) + (select count(*) from public.pl_monthly_walk)
  + (select count(*) from public.pl_projected_rep_pay_daily) + (select count(*) from public.manual_entry_sources)
  + (select count(*) from public.overhead_entries) + (select count(*) from public.pl_overhead_weekly) n;
reset role; select pg_temp.srv();
select pg_temp.r('ME2b. an agent sees 0 rows of manual entries, sources and the P&L walk', (select n = 0 from meag), (select 'rows=' || n from meag));
select pg_temp.act('service_role','admin2.test@example.com');
do $$ begin
  insert into public.manual_entries (kind, entry_date, period, amount) values ('credit', '2026-10-30', 'day', 1);
  reset role; perform pg_temp.r('ME3. the admin key (service_role) cannot enter', false, 'inserted');
exception when others then reset role; perform pg_temp.r('ME3. the admin key (service_role) cannot enter', sqlerrm like '%service_role%', sqlerrm); end $$;
select pg_temp.act('authenticated','admin2.test@example.com');
do $$ begin
  insert into public.manual_entry_sources (kind, code, label, pl_line) values ('lead_spend', 'google', 'Google', 'lead_spend');
  reset role; perform pg_temp.r('ME4. a non-owner admin cannot add a source / box name (config is owner-only)', false, 'inserted');
exception when others then reset role; perform pg_temp.r('ME4. a non-owner admin cannot add a source / box name (config is owner-only)', sqlerrm like '%owner-only%', sqlerrm); end $$;
do $$ declare st text; bad text; begin
  perform pg_temp.act('authenticated','admin2.test@example.com');
  foreach st in array array[
    'insert into public.manual_entries (kind, entry_date, period, amount) values (''credit'', ''2026-10-25'', ''week'', 1)',
    'insert into public.manual_entries (kind, source, entry_date, period, amount) values (''deposit_box'', ''neo_book'', ''2026-10-30'', ''day'', 1)',
    'insert into public.manual_entries (kind, source, entry_date, period, amount) values (''deposit_box'', ''neo_book'', ''2026-10-27'', ''week'', 1)',
    'insert into public.manual_entries (kind, source, entry_date, period, amount) values (''transfer'', ''google'', ''2026-10-30'', ''day'', 1)',
    'insert into public.manual_entries (kind, entry_date, period, amount) values (''transfer'', ''2026-10-30'', ''day'', 1)'] loop
    begin execute st; bad := concat_ws(' | ', bad, st); exception when others then null; end;
  end loop;
  perform pg_temp.srv();
  perform pg_temp.r('ME5. granularity and sources enforced: credits/transfers/spend daily, earned lines weekly on a Sunday, transfer source must be Ringba/Acme',
    bad is null, coalesce(bad, 'all 5 refused'));
end $$;
select pg_temp.act('authenticated','admin2.test@example.com');
insert into public.manual_entries (kind, entry_date, period, amount, note, correction_of, correction_kind)
  select 'debit', '2026-10-30', 'day', 130, 'VERIFY debit corrected', id, 'supersede' from public.manual_entries where note = 'VERIFY debits';
insert into public.manual_entries (kind, source, entry_date, period, amount, note, correction_of, correction_kind)
  select 'lead_spend', 'ppc_data', '2026-10-30', 'day', -50, 'VERIFY spend 2 reversed', id, 'reverse' from public.manual_entries where note = 'VERIFY spend 2';
do $$ declare bad text; st text; ok boolean; begin
  foreach st in array array[
    'insert into public.manual_entries (kind, source, entry_date, period, amount, correction_of, correction_kind) select ''transfer'', ''acme'', ''2026-10-30'', ''day'', -10, id, ''reverse'' from public.manual_entries where note = ''VERIFY acme''',
    'update public.manual_entries set amount = 1 where note = ''VERIFY ringba''',
    'delete from public.manual_entries where note = ''VERIFY ringba'''] loop
    begin execute st; bad := concat_ws(' | ', bad, st); exception when others then null; end;
  end loop;
  perform pg_temp.srv();
  begin update public.manual_entries set amount = 1 where note = 'VERIFY ringba'; bad := concat_ws(' | ', bad, 'postgres update');
  exception when others then null; end;
  perform pg_temp.act('authenticated', 'admin.test@example.com');
  ok := (select count(*) = 0 from public.manual_entries_current where note = 'VERIFY debits')
        and exists (select 1 from public.manual_entries_current where note = 'VERIFY debit corrected' and amount = 130);
  perform pg_temp.srv();
  perform pg_temp.r('ME6. corrections are new rows: supersede replaces, reverse must be exactly the negative; no edits or deletes (not even postgres)',
    bad is null and ok, coalesce(bad, 'refusals ok') || ' current_ok=' || ok);
end $$;
-- monthly overhead (Kyle directly 7:24 PM ET)
select pg_temp.act('authenticated','admin2.test@example.com');
insert into public.overhead_entries (month, source_name, amount, note, entered_by) values
  ('2026-10-01', 'Rent', 3100, 'VERIFY rent', 'Kyle'), ('2026-10-01', 'Software', 300, 'VERIFY software', null),
  ('2026-11-01', 'Rent', 3000, 'VERIFY rent nov', null);
insert into public.overhead_entries (month, source_name, amount, note, correction_of, correction_kind)
  select '2026-10-01', 'Software', 310.10, 'VERIFY software corrected', id, 'supersede' from public.overhead_entries where note = 'VERIFY software';
reset role; select pg_temp.srv();
select pg_temp.r('OH1. any admin enters monthly overhead by source name; entered_by from the login; supersede corrects',
  (select count(*) = 4 and bool_and(entered_by = 'Second Admin (fake)') from public.overhead_entries where note like 'VERIFY%')
  and (select count(*) >= 4 from public.event_log where table_name = 'overhead_entries' and action = 'INSERT'),
  (select string_agg(source_name || '=' || amount, ', ' order by id) from public.overhead_entries));
do $$ declare bad text; who text; begin
  foreach who in array array['agent', 'service_role', 'admin-edit'] loop
    if who = 'agent' then perform pg_temp.act('authenticated', 'agent.test@example.com');
    elsif who = 'service_role' then perform pg_temp.act('service_role', 'admin2.test@example.com');
    else perform pg_temp.act('authenticated', 'admin2.test@example.com'); end if;
    begin
      if who = 'admin-edit' then update public.overhead_entries set amount = 1 where note = 'VERIFY rent';
      else insert into public.overhead_entries (month, source_name, amount) values ('2026-10-01', 'X', 1); end if;
      bad := concat_ws(', ', bad, who);
    exception when others then null; end;
    perform pg_temp.srv();
  end loop;
  perform pg_temp.r('OH2. overhead: agents and the admin key are refused; no edits (corrections are new rows)', bad is null, coalesce(bad, 'all refused'));
end $$;
select pg_temp.act('authenticated','admin.test@example.com');
create temp table oh as select
  (select sum(amount) from public.pl_overhead_weekly where month_start = '2026-10-01' and source_name = 'Rent') oct_rent,
  (select sum(amount) from public.pl_overhead_weekly where month_start = '2026-10-01' and source_name = 'Software') oct_sw,
  (select sum(amount) from public.pl_overhead_weekly where month_start = '2026-11-01') nov,
  (select string_agg(format('%s %s %s/%s=%s', week_start, source_name, days_in_month, days_of_month, amount), '; ' order by week_start, source_name)
     from public.pl_overhead_weekly where month_start = '2026-10-01') detail,
  (select amount from public.pl_overhead_weekly where week_start = '2026-09-27' and source_name = 'Rent') w0927_rent,
  (select days_in_month from public.pl_overhead_weekly where week_start = '2026-09-27' and source_name = 'Rent') w0927_days,
  (select amount from public.pl_overhead_monthly where month_start = '2026-10-01' and source_name = 'Software') m_sw,
  (select string_agg(column_name, ',') from information_schema.columns where table_schema = 'public' and table_name = 'pl_daily_walk'
      and column_name ~ '(allstate|premier_book|neo|oneil|earned|overhead)') daily_bad_cols;
reset role; select pg_temp.srv();
select pg_temp.r('OH3. overhead prorated by days (DEFAULT): the 9/27 week gets 3/31 of October, and October''s weekly shares add up exactly to the monthly amounts (3100.00 / 310.10)',
  (select oct_rent = 3100 and oct_sw = 310.10 and nov = 3000 and w0927_days = 3 and w0927_rent = 300 and m_sw = 310.10 from oh),
  (select detail from oh));
select pg_temp.r('OH4. earned sources and overhead are absent from the daily view (Kyle 7:24 PM: weekly only)',
  (select daily_bad_cols is null from oh), (select coalesce(daily_bad_cols, 'none') from oh));
select pg_temp.act('authenticated','admin.test@example.com');
create temp table walk as
  select (select row(d.*)::text from public.pl_daily_walk d where day = '2026-10-30') dtxt,
         d.credits, d.debits, d.credit_revenue, d.transfers_ringba, d.transfers_acme, d.transfer_revenue, d.total_spend,
         d.deal_commission, d.spiffs, d.abs_pay, d.projected_commission, d.net,
         (select sum(net) from public.pl_daily_walk where week_start = '2026-10-25') wk_daily_sum,
         (select sum(net) from public.pl_daily_walk where month_start = '2026-10-01') mo_daily_sum,
         w.daily_net w_daily_net, w.overhead w_oh, w.earned_total w_earned, w.neo_book w_neo, w.allstate_earned w_allstate, w.net w_net,
         m.daily_net m_daily_net, m.overhead m_oh, m.earned_total m_earned, m.net m_net, m.projected_commission m_pc,
         (select sum(projected_commission) from public.pl_daily_walk where month_start = '2026-10-01') mo_pc_sum,
         (select (sum(projected_commission) filter (where line_type <> 'ABS'))::numeric(12,2) from public.premier_recon_lines where date_booked = '2026-10-30' and public.recon_line_status_pays(line_status)) eng_comm,
         (select (sum(projected_spiffs) filter (where line_type = 'ABS'))::numeric(12,2) from public.premier_recon_lines where date_booked = '2026-10-30' and public.recon_line_status_pays(line_status)) eng_abs,
         (select (sum(projected_spiffs) filter (where line_type <> 'ABS'))::numeric(12,2) from public.premier_recon_lines where date_booked = '2026-10-30' and public.recon_line_status_pays(line_status)) eng_sp,
         (select count(*) from public.pl_manual_entry_lines where description in ('VERIFY premium entered', 'VERIFY count')) ml,
         -- rev 4 B2: rep pay with NO pay predicate (what 2b5187d summed), for the 10/29 day, the 10/25 week and October
         (select sum(coalesce(projected_commission, 0) + coalesce(projected_spiffs, 0)) from public.premier_recon_lines
           where coalesce(date_booked, (submitted_at at time zone 'America/New_York')::date) = '2026-10-29') raw_1029,
         (select sum(coalesce(projected_commission, 0) + coalesce(projected_spiffs, 0)) from public.premier_recon_lines
           where coalesce(date_booked, (submitted_at at time zone 'America/New_York')::date) between '2026-10-25' and '2026-10-31') raw_wk,
         (select sum(coalesce(projected_commission, 0) + coalesce(projected_spiffs, 0)) from public.premier_recon_lines
           where coalesce(date_booked, (submitted_at at time zone 'America/New_York')::date) between '2026-10-01' and '2026-10-31') raw_oct,
         (select projected_commission from public.pl_daily_walk where day = '2026-10-29') pc_1029,
         (select sum(projected_commission) from public.pl_daily_walk where week_start = '2026-10-25') pc_wk,
         (select (projected_commission + projected_spiffs)::numeric(12,2) from public.premier_recon_lines where line_key = '20261029114007-P') dup_amt,
         (select line_status from public.premier_recon_lines where line_key = '20261029114007-P') dup_status,
         (select count(*) from public.pl_projected_rep_pay_lines where line_key = '20261029114007-P') dup_in_pl,
         (select count(*) from public.pl_projected_rep_pay_lines p join public.premier_recon_lines l using (line_key)
           where not public.recon_line_status_pays(l.line_status)) pl_nonpay,
         (select count(*) from public.premier_recon_lines l
           where public.recon_line_status_pays(l.line_status)
             and coalesce(l.date_booked, (l.submitted_at at time zone 'America/New_York')::date) is not null
             and not exists (select 1 from public.pl_projected_rep_pay_lines p where p.line_key = l.line_key)) pay_missing,
         -- parity with payroll pay: every line payroll has a corrected pay figure for (Premier collected), P&L rep pay = that pay
         (select count(*) from public.pl_projected_rep_pay_lines p join public.premier_recon_trueup t using (line_key)
            join public.premier_recon_lines l using (line_key)
           where l.actual_commission is not null and t.stage2_premier_corrected is not null
             and l.line_status not in ('awaiting_first_payment', 'failed_payment', 'never_paid', 'not_in_premier')
             and not p.added_to_closed_week) par_n,
         -- Kyle direct 8:03 PM: the closed-week added rows count in their booked week on the P&L (payroll doesn't pay them)
         (select count(*) from public.pl_projected_rep_pay_lines where added_to_closed_week) cw_n,
         (select count(*) from public.pl_projected_rep_pay_lines p join public.premier_recon_lines l using (line_key)
           where p.added_to_closed_week and public.recon_line_pays(l.line_status, l.added_to_closed_week)) cw_payroll_pays,
         (select format('%s|%s|%s', p.day, p.deal_commission + p.spiffs + p.abs_pay, p.added_to_closed_week)
            from public.pl_projected_rep_pay_lines p where p.line_key = '20261030163000-P') cw_line,
         (select (projected_commission + coalesce(projected_spiffs, 0))::numeric(12,2) from public.premier_recon_lines where line_key = '20261030163000-P') cw_amt,
         (select public.recon_line_pays(line_status, added_to_closed_week) from public.premier_recon_lines where line_key = '20261030163000-P') cw_recon_pays,
         (select count(*) from public.pay_line_locks where line_key = '20261030163000-P') cw_locks,
         (select format('stage2=%s final_payable=%s hold=%s', stage2_premier_corrected, final_payable, hold_status) from public.premier_recon_trueup where line_key = '20261030163000-P') cw_trueup,
         (select sum(deal_commission + spiffs + abs_pay) from public.pl_projected_rep_pay_lines where day between '2026-10-25' and '2026-10-31' and not added_to_closed_week) pc_wk_open,
         (select sum(p.deal_commission + p.spiffs + p.abs_pay) from public.pl_projected_rep_pay_lines p join public.premier_recon_trueup t using (line_key)
            join public.premier_recon_lines l using (line_key)
           where l.actual_commission is not null and t.stage2_premier_corrected is not null
             and l.line_status not in ('awaiting_first_payment', 'failed_payment', 'never_paid', 'not_in_premier')
             and not p.added_to_closed_week) par_pl,
         (select sum(t.stage2_premier_corrected) from public.pl_projected_rep_pay_lines p join public.premier_recon_trueup t using (line_key)
            join public.premier_recon_lines l using (line_key)
           where l.actual_commission is not null and t.stage2_premier_corrected is not null
             and l.line_status not in ('awaiting_first_payment', 'failed_payment', 'never_paid', 'not_in_premier')
             and not p.added_to_closed_week) par_pay,
         (select count(*) from public.pl_projected_rep_pay_lines p join public.premier_recon_trueup t using (line_key)
            join public.premier_recon_lines l using (line_key)
           where l.actual_commission is not null and t.stage2_premier_corrected is not null
             and l.line_status not in ('awaiting_first_payment', 'failed_payment', 'never_paid', 'not_in_premier')
             and not p.added_to_closed_week
             and p.deal_commission + p.spiffs + p.abs_pay <> t.stage2_premier_corrected) par_bad,
         (select coalesce(t.stage2_premier_corrected, 0) from public.premier_recon_trueup t where t.line_key = '20261029114007-P') dup_payroll
    from public.pl_daily_walk d, public.pl_weekly_walk w, public.pl_monthly_walk m
   where d.day = '2026-10-30' and w.week_start = '2026-10-25' and m.month_start = '2026-10-01';
reset role; select pg_temp.srv();
select pg_temp.r('PL1. daily walk 10/30: credit revenue = credits 500 - debits 130 (superseded 120) = 370; transfers Ringba 300 + Acme 200 = 500; spend 150 (PPC reversed)',
  (select credits = 500 and debits = 130 and credit_revenue = 370 and transfers_ringba = 300 and transfers_acme = 200 and transfer_revenue = 500 and total_spend = 150 from walk),
  (select dtxt from walk));
select pg_temp.r('PL2. projected commission is a COST: deal commission + spiffs + ABS pay (engine, by Date Booked), and the daily net subtracts all three',
  (select deal_commission = eng_comm and abs_pay = eng_abs and spiffs = eng_sp
          and projected_commission = deal_commission + spiffs + abs_pay
          and deal_commission > 0 and spiffs > 0 and abs_pay > 0
          and net = 370 + 500 - 150 - (deal_commission + spiffs + abs_pay) from walk),
  (select format('deal=%s spiffs=%s abs=%s projected=%s net=%s', deal_commission, spiffs, abs_pay, projected_commission, net) from walk));
select pg_temp.r('PL3. weekly net = sum of daily nets + four earned lines (Allstate 1000, Premier Book 400, Neo 250 in the admin''s week, O''Neil 100) - overhead (7 Oct days: 700.00 rent + 70.02 software)',
  (select w_daily_net = wk_daily_sum and w_earned = 1750 and w_neo = 250 and w_allstate = 1000 and w_oh = 770.02
          and w_net = wk_daily_sum + 1750 - 770.02 from walk),
  (select format('daily_net=%s earned=%s overhead=%s net=%s', w_daily_net, w_earned, w_oh, w_net) from walk));
select pg_temp.r('PL4. monthly rollup: October = every October daily net + earned lines of weeks starting in October - the full October overhead (3410.10)',
  (select m_daily_net = mo_daily_sum and m_earned = 1750 and m_oh = 3410.10 and m_net = mo_daily_sum + 1750 - 3410.10 and m_pc = mo_pc_sum from walk),
  (select format('daily_net=%s earned=%s overhead=%s net=%s projected_commission=%s', m_daily_net, m_earned, m_oh, m_net, m_pc) from walk));
select pg_temp.r('PL5. entered Premier premium / policy counts are visible lines, not in the walk net',
  (select ml = 2 from walk), (select 'lines=' || ml from walk));
select pg_temp.r('PL6. (B2) P&L rep pay uses payroll''s status rule: the duplicate board row 20261029114007-P (98.47 + 50.00 spiff) is out, no non-paying status is in, no line with a paying status is missing; the lock uses recon_line_pays() = recon_line_status_pays() + not added to a closed week, the P&L uses recon_line_status_pays()',
  (select dup_status = 'duplicate_board_row' and dup_amt = 148.47 and dup_in_pl = 0 and pl_nonpay = 0 and pay_missing = 0 and dup_payroll = 0 from walk)
  and (select prosrc ~ 'recon_line_pays' from pg_proc where proname = 'premier_lock_payday')
  and (select prosrc ~ 'recon_line_status_pays' from pg_proc where proname = 'recon_line_pays')
  and (select pg_get_viewdef('public.pl_projected_rep_pay_lines'::regclass) ~ 'recon_line_status_pays'
          and pg_get_viewdef('public.pl_projected_rep_pay_lines'::regclass) !~ 'recon_line_pays\('),
  (select format('dup=%s %s in_pl=%s nonpay_in_pl=%s paying_missing=%s payroll_pays_dup=%s', dup_status, dup_amt, dup_in_pl, pl_nonpay, pay_missing, dup_payroll) from walk));
select pg_temp.r('PL7. (B2) parity: for every line Premier has collected, P&L rep pay = payroll pay (premier_recon_trueup.stage2_premier_corrected), line by line and in total, EXCEPT the documented closed-week added rows (on the P&L in their booked week, never paid by payroll: PL9); uncollected lines carry the projected cost by Date Booked, payroll pays 0 until collected',
  (select par_n > 20 and par_bad = 0 and par_pl = par_pay and cw_n >= 1 from walk),
  (select format('lines=%s pl=%s payroll=%s mismatched=%s; excluded closed-week added rows=%s', par_n, par_pl, par_pay, par_bad, cw_n) from walk));
select pg_temp.r('PL8. (B2) corrected figures: 10/29, the 10/25 week and October rep pay are each exactly 148.47 lower than the unfiltered sum 2b5187d used (only the duplicate row is out; the closed-week added row stays in, Kyle 8:03 PM); mock-only figures: local suite D4',
  (select raw_1029 - pc_1029 = 148.47 and raw_wk - pc_wk = 148.47 and raw_oct - m_pc = 148.47 from walk),
  (select format('10/29 %s (unfiltered %s); week rep pay %s (unfiltered %s); week net %s; October rep pay %s (unfiltered %s), net %s',
          pc_1029, raw_1029, pc_wk, raw_wk, w_net, m_pc, raw_oct, m_net) from walk));
select pg_temp.r('PL9. (Kyle direct 8:03 PM "No sales count to the week it happen, they don''t move for payroll") the 119.32 row verify adds to the closed week (20261030163000-P, booked 10/30) is in the 10/30 day and the 10/25 week rep pay; payroll still does not pay it (recon_line_pays false, no pay locks, true-up final payable empty, hold = held_added_to_closed_week); no separate held line',
  (select cw_line = '2026-10-30|119.32|t' and cw_amt = 119.32 and cw_recon_pays = false and cw_locks = 0 and cw_payroll_pays = 0
          and cw_trueup ~ 'final_payable= hold=held_added_to_closed_week'
          and pc_wk - pc_wk_open = 119.32 from walk)
  and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name in ('pl_daily_walk', 'pl_weekly_walk', 'pl_monthly_walk') and column_name ~ 'held'),
  (select format('P&L line=%s; week rep pay %s incl. it, %s without; payroll: recon_line_pays=%s locks=%s %s', cw_line, pc_wk, pc_wk_open, cw_recon_pays, cw_locks, cw_trueup) from walk));
select pg_temp.r('RV1. slice-two P&L views retired (Kyle directly 7:35 PM): pl_line_items / pl_daily / pl_weekly / pl_monthly / pl_unpriced_sales are gone',
  to_regclass('public.pl_line_items') is null and to_regclass('public.pl_daily') is null and to_regclass('public.pl_weekly') is null
  and to_regclass('public.pl_monthly') is null and to_regclass('public.pl_unpriced_sales') is null);
select pg_temp.r('RV2. kept: slice-two tables expense_categories / revenue_adjustments (data; drop in a later cleanup migration, Kyle direct 8:03 PM), touch_updated_at(), slice-one sales_commission / commission_rates() / daily_pl / weekly_pl / monthly_pl',
  to_regclass('public.expense_categories') is not null and to_regclass('public.revenue_adjustments') is not null
  and to_regprocedure('public.touch_updated_at()') is not null and to_regclass('public.sales_commission') is not null
  and to_regprocedure('public.commission_rates()') is not null and to_regclass('public.daily_pl') is not null
  and to_regclass('public.weekly_pl') is not null and to_regclass('public.monthly_pl') is not null);

reset role;
\o
select n, case when pass then 'PASS' else 'FAIL' end as result, check_name, detail from results order by n;
rollback;
