-- ROLLBACK for slice three (Premier reconciliation). Reverts every slice-three object and the two added sales columns.
-- ONE transaction: any error rolls the whole thing back. Run as the project owner (SQL Editor) only if slice three must be undone.
-- What it does:
--   1. Refuses to run if real (non-mock) data would be lost: any recon_imports row with is_mock = false, any pay_line_locks
--      row (payroll actual), any pay_adjustments row whose external_ref is not 'mock-%' (Kyle's manual adjustments / Cancel Commission),
--      any policy_count_claims row, or any non-null sales.premier_member_id / sales.lead_source. Export first.
--   2. Drops the 9 slice-three views, the slice-three functions, the 11 slice-three tables (their triggers and policies go
--      with them) and the sales columns premier_member_id + lead_source.
--   3. Deletes the 3 slice-three versions from supabase_migrations.schema_migrations (slice one + two rows stay).
-- Not touched: slice-one / slice-two tables, views and data, commission_config, event_log (append-only: the slice-three
-- audit / premier.* / payroll.adjustment.recorded rows stay as history).
begin;

do $$ declare n bigint; begin
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
  if to_regclass('public.policy_count_claims') is not null then
    execute 'select count(*) from public.policy_count_claims' into n;
    if n > 0 then raise exception 'slice-three rollback refused: % policy_count_claims row(s); export them first', n; end if;
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

drop function if exists public.premier_log_recon_events();
drop function if exists public.premier_lock_payday(date);

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
drop table if exists public.recon_pay_config;

drop function if exists public.log_pay_adjustment();
drop function if exists public.pay_adjustment_open_payday();
drop function if exists public.pay_lock_immutable();
drop function if exists public.recon_staging_immutable();
drop function if exists public.board_parse_raw();
drop function if exists public.premier_parse_raw();
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
