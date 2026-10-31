-- ROLLBACK for slice three (Premier reconciliation). Reverts every slice-three object and the two added sales columns.
-- ONE transaction: any error rolls the whole thing back. Run as the project owner (SQL Editor) only if slice three must be undone.
-- What it does:
--   1. Refuses to run if real (non-mock) data would be lost: any recon_imports row with is_mock = false, any pay_line_locks
--      row (payroll actual), any pay_adjustments row whose external_ref is not 'mock-%' (Kyle's manual adjustments / Cancel Commission),
--      any policy_count_claims row, or any non-null sales.premier_member_id / sales.lead_source. Export first.
--      rev 2: also refuses when Kyle's settings would be lost: recon_pay_config differs from its shipped defaults (e.g.
--      payroll_owner_user_id, cutover_date, a decided OPEN item), agent_pay_rules or premier_addon_map differ from the seed,
--      or payroll_cutoffs holds a row that is not a MOCK seed row (real submit times).
--      rev 3: also refuses once the hub cutover was recorded (hub_cutover / hub_paid_lock rows: the clock started) or
--      agent_name_aliases holds rows (Kyle's agent links).
--   2. Drops the 11 slice-three views, the slice-three functions, the 16 slice-three tables (their triggers and policies go
--      with them) and the sales columns premier_member_id + lead_source.
--   3. Deletes the 3 slice-three versions from supabase_migrations.schema_migrations (slice one + two rows stay).
-- Not touched: slice-one / slice-two tables, views and data, commission_config, event_log (append-only: the slice-three
-- audit / premier.* / payroll.adjustment.recorded rows stay as history).
begin;

do $$ declare n bigint; fp text; begin
  if to_regclass('public.recon_imports') is not null then
    execute 'select count(*) from public.recon_imports where not is_mock' into n;
    if n > 0 then raise exception 'slice-three rollback refused: % non-mock import(s) in recon_imports; export them first', n; end if;
  end if;
  if to_regclass('public.pay_line_locks') is not null then
    execute 'select count(*) from public.pay_line_locks' into n;
    if n > 0 then raise exception 'slice-three rollback refused: % payroll-actual lock row(s) in pay_line_locks; export them first', n; end if;
  end if;
  if to_regclass('public.pay_adjustments') is not null then
    execute $q$select count(*) from public.pay_adjustments where coalesce(external_ref, '') not like 'mock-%'$q$ into n;
    if n > 0 then raise exception 'slice-three rollback refused: % non-mock pay adjustment(s); export them first', n; end if;
  end if;
  if to_regclass('public.hub_cutover') is not null then
    execute 'select (select count(*) from public.hub_cutover) + (select count(*) from public.hub_paid_lock)' into n;
    if n > 0 then raise exception 'slice-three rollback refused: the hub cutover is recorded (% hub row(s)): the clock started; export first', n; end if;
  end if;
  if to_regclass('public.agent_name_aliases') is not null then
    execute 'select count(*) from public.agent_name_aliases' into n;
    if n > 0 then raise exception 'slice-three rollback refused: % agent_name_aliases row(s) (Kyle''s agent links); export them first', n; end if;
  end if;
  if to_regclass('public.policy_count_claims') is not null then
    execute 'select count(*) from public.policy_count_claims' into n;
    if n > 0 then raise exception 'slice-three rollback refused: % policy_count_claims row(s); export them first', n; end if;
  end if;
  if to_regclass('public.recon_pay_config') is not null then
    -- compare with a freshly defaulted row (same table definition), ignoring id / note / updated_at
    create temp table slice3_rb_default (like public.recon_pay_config including defaults) on commit drop;
    insert into slice3_rb_default default values;
    execute $q$select count(*) from public.recon_pay_config c, slice3_rb_default d
                where (to_jsonb(c) - 'id' - 'note' - 'updated_at') is distinct from (to_jsonb(d) - 'id' - 'note' - 'updated_at')$q$ into n;
    if n > 0 then raise exception 'slice-three rollback refused: recon_pay_config was changed from its defaults (owner / cutover / decisions); export it first'; end if;
  end if;
  if to_regclass('public.agent_pay_rules') is not null then
    execute $q$select count(*) from (
                 (select agent_name, base_rate_override, addon_bonus_override, no_spiff from public.agent_pay_rules
                  except select * from (values ('Kaitlyn Romine', 0.25::numeric, 0.00::numeric, false), ('Loreidy Martinez', null::numeric, null::numeric, true)) v)
                 union all
                 (select * from (values ('Kaitlyn Romine', 0.25::numeric, 0.00::numeric, false), ('Loreidy Martinez', null::numeric, null::numeric, true)) v
                  except select agent_name, base_rate_override, addon_bonus_override, no_spiff from public.agent_pay_rules)) x$q$ into n;
    if n > 0 then raise exception 'slice-three rollback refused: agent_pay_rules differ from the seed; export them first'; end if;
  end if;
  if to_regclass('public.premier_addon_map') is not null then
    -- fingerprint of the 13 seeded mapping rows (Payroll's list as shipped; rev 3: ProtectLife ADD 'approved', Kyle 10/31)
    execute $q$select md5(string_agg(concat_ws('|', source, pattern, addon_key, tier, qualifies_bonus, status, active, owner), E'\n' order by source, pattern))
                 from public.premier_addon_map$q$ into fp;
    if fp is distinct from '5024317934ad56f2705667df8447ac65' then
      raise exception 'slice-three rollback refused: premier_addon_map differs from the seeded list (Payroll / Kyle edits); export it first';
    end if;
  end if;
  if to_regclass('public.payroll_cutoffs') is not null then
    execute $q$select count(*) from public.payroll_cutoffs where coalesce(note, '') not like 'MOCK seed:%'$q$ into n;
    if n > 0 then raise exception 'slice-three rollback refused: % real payroll cutoff(s) (Kyle''s submit times); export them first', n; end if;
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='sales' and column_name='premier_member_id') then
    execute 'select count(*) from public.sales where premier_member_id is not null' into n;
    if n > 0 then raise exception 'slice-three rollback refused: % sales row(s) have premier_member_id; export first', n; end if;
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='sales' and column_name='lead_source') then
    execute 'select count(*) from public.sales where lead_source is not null' into n;
    if n > 0 then raise exception 'slice-three rollback refused: % sales row(s) have lead_source; export first', n; end if;
  end if;
end $$;

drop view if exists public.sales_missing_member_id;
drop view if exists public.premier_recon_trueup;
drop view if exists public.premier_policy_count_check;
drop view if exists public.premier_recon_open_items;
drop view if exists public.premier_recon_unmatched_premier;
drop view if exists public.premier_recon_unmatched_board;
drop view if exists public.premier_recon_lines;
drop view if exists public.premier_member_status;
drop view if exists public.premier_products_current;
drop view if exists public.board_export_diffs;
drop view if exists public.board_submissions_current;

drop function if exists public.premier_log_recon_events();
drop function if exists public.premier_lock_payday(date);
drop function if exists public.my_pay_adjustments();
drop function if exists public.recon_finalize_board_import(bigint, boolean);

drop table if exists public.hub_cutover;
drop table if exists public.hub_paid_lock;
drop table if exists public.board_week_freezes;
drop table if exists public.missed_spiff_anchors;
drop table if exists public.pay_adjustments;
drop table if exists public.pay_line_locks;
drop table if exists public.policy_count_claims;
drop table if exists public.premier_addon_map;
drop table if exists public.premier_recon_event_state;
drop table if exists public.board_submissions;
drop table if exists public.premier_member_products;
drop table if exists public.recon_imports;
drop table if exists public.payroll_cutoffs;
drop table if exists public.agent_pay_rules;
drop table if exists public.agent_name_aliases;
drop table if exists public.recon_pay_config;

drop function if exists public.log_pay_adjustment();
drop function if exists public.hub_cutover_guard();
drop function if exists public.hub_cutover_recorded();
drop function if exists public.hub_paid_lock_guard();
drop function if exists public.payroll_cutoffs_guard();
drop function if exists public.premier_anchor_missed_spiffs();
drop function if exists public.recon_freeze_closed_weeks(date, text);
drop function if exists public.recon_owner_or_sql_editor(text);
drop function if exists public.recon_pay_config_guard();
drop function if exists public.recon_cutover_bounds();
drop function if exists public.recon_payroll_owner();
drop function if exists public.recon_imports_immutable();
drop function if exists public.recon_agent_id(text);
drop function if exists public.recon_scrub_text(text, text[]);
drop function if exists public.pay_adjustment_open_payday();
drop function if exists public.pay_lock_immutable();
drop function if exists public.recon_staging_immutable();
drop function if exists public.board_parse_raw();
drop function if exists public.premier_parse_raw();
drop function if exists public.recon_import_check();
drop function if exists public.recon_premier_required_cols();
drop function if exists public.recon_premier_allowed_cols();
drop function if exists public.recon_board_expected_cols();
drop function if exists public.recon_spiff_payday(timestamptz, date);
drop function if exists public.abs_item_count(numeric);
drop function if exists public.board_answer_addons(text);
drop function if exists public.premier_product_addon(text, text, boolean);
drop function if exists public.premier_row_fees(jsonb, text);
drop function if exists public.recon_friday_after_week(date);
drop function if exists public.recon_can_read();
drop function if exists public.recon_col_letter(int);
drop function if exists public.recon_digits(text);
drop function if exists public.recon_yes(text);
drop function if exists public.recon_parse_money(text);
drop function if exists public.recon_parse_ts_et(text);
drop function if exists public.recon_parse_date(text);

alter table public.sales drop column if exists premier_member_id;
alter table public.sales drop column if exists lead_source;

do $$ begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$delete from supabase_migrations.schema_migrations
                where version in ('20261031210000','20261031210100','20261031210200')$q$;
  end if;
end $$;

commit;
