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
--      rev 4: also refuses when manual_entries / overhead_entries hold rows (admins' entries) or manual_entry_sources
--      differs from its seed (owner edits).
--   2. Drops the 19 slice-three views, the slice-three functions, the 19 slice-three tables (their triggers and policies go
--      with them) and the sales columns premier_member_id + lead_source.
--      rev 4: removes the owner-only write trigger from slice one's commission_config (commission_config_owner_write);
--      its slice-one policies were never changed, so it is back to the slice-one state (any admin may update).
--      rev 4 (Kyle 7:35 PM): recreates slice two's five P&L views (pl_line_items, pl_daily, pl_weekly, pl_monthly,
--      pl_unpriced_sales) exactly, with their comments and grants, after the slice-three objects are gone.
--   3. Deletes the 5 slice-three versions from supabase_migrations.schema_migrations (slice one + two rows stay).
-- Not touched: slice-one / slice-two tables, views and data, commission_config rows, event_log (append-only: the
-- slice-three audit / premier.* / payroll.adjustment.recorded rows stay as history).
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
    -- fingerprint of the seeded mapping rows (Payroll's list as shipped; rev 4: ADD narrowed + 2 exclusions, Kyle 7:13 PM)
    execute $q$select md5(string_agg(concat_ws('|', source, pattern, addon_key, tier, qualifies_bonus, status, active, owner), E'\n' order by source, pattern))
                 from public.premier_addon_map$q$ into fp;
    if fp is distinct from '6a13c04a6a6c7e4e0e62724bcfbf181a' then
      raise exception 'slice-three rollback refused: premier_addon_map differs from the seeded list (Payroll / Kyle edits); export it first';
    end if;
  end if;
  if to_regclass('public.manual_entries') is not null then
    execute 'select (select count(*) from public.manual_entries) + (select count(*) from public.overhead_entries)' into n;
    if n > 0 then raise exception 'slice-three rollback refused: % manual / overhead entr(ies) (admins'' P&L inputs); export them first', n; end if;
    execute $q$select md5(string_agg(concat_ws('|', kind, code, label, pl_line, active), E'\n' order by kind, code))
                 from public.manual_entry_sources$q$ into fp;
    if fp is distinct from '96301a55b8c11d2c89b2c4f06f8291bd' then
      raise exception 'slice-three rollback refused: manual_entry_sources differs from the seed (owner edits); export it first';
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

drop view if exists public.pl_monthly_walk;
drop view if exists public.pl_weekly_walk;
drop view if exists public.pl_daily_walk;
drop view if exists public.pl_overhead_weekly;
drop view if exists public.pl_overhead_monthly;
drop view if exists public.pl_projected_rep_pay_daily;
drop view if exists public.pl_projected_rep_pay_lines;
drop view if exists public.pl_manual_entry_lines;
drop view if exists public.manual_entries_current;
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

drop trigger if exists commission_config_owner_write on public.commission_config;
drop table if exists public.overhead_entries;
drop table if exists public.manual_entries;
drop table if exists public.manual_entry_sources;
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

drop function if exists public.overhead_entry_before_insert();
drop function if exists public.manual_entry_before_insert();
drop function if exists public.manual_entry_immutable();
drop function if exists public.recon_owner_write_guard();
drop function if exists public.recon_owner_or_break_glass();
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
drop function if exists public.recon_line_pays(text, boolean);
drop function if exists public.recon_line_status_pays(text);
drop function if exists public.recon_can_read();
drop function if exists public.recon_col_letter(int);
drop function if exists public.recon_digits(text);
drop function if exists public.recon_yes(text);
drop function if exists public.recon_parse_money(text);
drop function if exists public.recon_parse_ts_et(text);
drop function if exists public.recon_parse_date(text);

alter table public.sales drop column if exists premier_member_id;
alter table public.sales drop column if exists lead_source;

-- rev 4: restore slice two's five P&L views exactly as slice two created them (Kyle 7:35 PM retired them; the
-- text below is migration 20261031200100_pl_line_item_views.sql verbatim, then the view grants of 20261031200200).
-- Slice two, part 2 of 3: line-item P&L views.
-- P&L = revenue lines - commission lines - expense lines. Every summary row is the sum of its lines in pl_line_items.
-- Revenue per sale is the same PLACEHOLDER as slice one: premium (Premier when present, else board claim).
-- Commission lines use the slice-one sales_commission view unchanged (commission_config, pay_premium, attribution as-is),
-- split into a base line and an add-on bonus line that add up exactly to commission_estimate.
-- Admin only: every branch is filtered by is_admin(), and the views run as the caller (security_invoker) so table RLS applies.
-- Periods: week starts Sunday (same as slice one weekly_pl), month = calendar month.

create or replace view public.pl_line_items with (security_invoker = true) as
with sc as (
  select c.*, r.base_rate,
         coalesce(c.premier_premium, c.board_premium) as premium_basis,
         round(coalesce(c.premier_premium, c.board_premium) * r.base_rate, 2) as base_commission
    from public.sales_commission c cross join public.commission_rates() r
   where public.is_admin() and coalesce(c.premier_premium, c.board_premium) is not null
),
lines as (
  -- revenue: one line per sale
  select sc.sale_date as line_date, 'revenue'::text as line_type,
         case when sc.premier_premium is not null then 'premium_premier' else 'premium_board_claim' end as category,
         concat_ws(' ', 'Sale premium', sc.carrier, '(' || sc.plan_type || ')',
                   case when cardinality(sc.addon_products) > 0 then '+ add-ons: ' || array_to_string(sc.addon_products, ', ') end)
           as description,
         coalesce(sc.premium_source, 'unknown') as source,
         sc.premium_basis as amount, 'sales'::text as ref_table, sc.id as ref_id, sc.agent_name
    from sc
  union all
  -- revenue: manual adjustments (signed)
  select ra.date, 'revenue', ra.category, ra.description, ra.source, ra.amount, 'revenue_adjustments', ra.id, null
    from public.revenue_adjustments ra where public.is_admin()
  union all
  -- commission: base rate on the premium basis
  select sc.sale_date, 'commission', 'agent_commission_base',
         format('Base %s%% of %s', trim(to_char(sc.base_rate * 100, 'FM990.##')), to_char(sc.premium_basis, 'FM999999990.00')),
         case when sc.premier_premium is not null then 'premier' else 'board_claim_estimate' end,
         sc.base_commission, 'sales', sc.id, sc.agent_name
    from sc
  union all
  -- commission: add-on bonus (difference to the configured total, so lines sum exactly to commission_estimate)
  select sc.sale_date, 'commission', 'agent_commission_addon_bonus',
         'Add-on bonus: ' || array_to_string(sc.addon_products, ', '),
         case when sc.premier_premium is not null then 'premier' else 'board_claim_estimate' end,
         sc.commission_estimate - sc.base_commission, 'sales', sc.id, sc.agent_name
    from sc where sc.qualifying_addon and sc.commission_estimate - sc.base_commission <> 0
  union all
  -- expenses
  select e.date, 'expense', e.category,
         concat_ws(' - ', e.description, e.vendor), e.source, e.amount, 'expenses', e.id, null
    from public.expenses e where public.is_admin()
)
select l.line_date,
       (l.line_date - extract(dow from l.line_date)::int)      as week_start,   -- Sunday
       date_trunc('month', l.line_date)::date                    as month_start,
       l.line_type, l.category,
       coalesce(ec.label, case l.category
         when 'premium_premier' then 'Premium (Premier)'
         when 'premium_board_claim' then 'Premium (board claim, Premier pending)'
         when 'carrier_bonus' then 'Carrier bonus' when 'override' then 'Override'
         when 'chargeback' then 'Chargeback' when 'other_revenue' then 'Other revenue'
         when 'agent_commission_base' then 'Agent commission (base)'
         when 'agent_commission_addon_bonus' then 'Agent commission (add-on bonus)'
         else l.category end)                                     as category_label,
       l.description, l.source,
       l.amount::numeric(12,2)                                    as amount,
       (case when l.line_type = 'revenue' then l.amount else -l.amount end)::numeric(12,2) as signed_amount,
       l.ref_table, l.ref_id, l.agent_name
  from lines l
  left join public.expense_categories ec on l.line_type = 'expense' and ec.code = l.category;
comment on view public.pl_line_items is
  'Every P&L line (revenue / commission / expense) with day, Sunday week_start and month_start keys. signed_amount: revenue +, commission and expense -. Admin only.';

-- Summaries: straight sums of pl_line_items, so a drill-down always adds back to the summary row.
create or replace view public.pl_daily with (security_invoker = true) as
select line_date as day, week_start, month_start,
       count(distinct ref_id) filter (where ref_table = 'sales')                    as sales_count,
       count(*)                                                                     as line_count,
       coalesce(sum(amount) filter (where line_type = 'revenue'), 0)::numeric(12,2)   as revenue,
       coalesce(sum(amount) filter (where line_type = 'commission'), 0)::numeric(12,2) as commission,
       coalesce(sum(amount) filter (where line_type = 'expense'), 0)::numeric(12,2)    as expenses,
       sum(signed_amount)::numeric(12,2)                                            as net
  from public.pl_line_items group by line_date, week_start, month_start;

create or replace view public.pl_weekly with (security_invoker = true) as
select week_start, (week_start + 6) as week_end,
       count(distinct ref_id) filter (where ref_table = 'sales')                    as sales_count,
       count(*)                                                                     as line_count,
       coalesce(sum(amount) filter (where line_type = 'revenue'), 0)::numeric(12,2)   as revenue,
       coalesce(sum(amount) filter (where line_type = 'commission'), 0)::numeric(12,2) as commission,
       coalesce(sum(amount) filter (where line_type = 'expense'), 0)::numeric(12,2)    as expenses,
       sum(signed_amount)::numeric(12,2)                                            as net
  from public.pl_line_items group by week_start;

create or replace view public.pl_monthly with (security_invoker = true) as
select month_start, (month_start + interval '1 month' - interval '1 day')::date as month_end,
       count(distinct ref_id) filter (where ref_table = 'sales')                    as sales_count,
       count(*)                                                                     as line_count,
       coalesce(sum(amount) filter (where line_type = 'revenue'), 0)::numeric(12,2)   as revenue,
       coalesce(sum(amount) filter (where line_type = 'commission'), 0)::numeric(12,2) as commission,
       coalesce(sum(amount) filter (where line_type = 'expense'), 0)::numeric(12,2)    as expenses,
       sum(signed_amount)::numeric(12,2)                                            as net
  from public.pl_line_items group by month_start;

comment on view public.pl_daily   is 'Line-item P&L per day (sum of pl_line_items). Admin only.';
comment on view public.pl_weekly  is 'Line-item P&L per Sun-Sat week (sum of pl_line_items). Admin only.';
comment on view public.pl_monthly is 'Line-item P&L per calendar month (sum of pl_line_items). Admin only.';

-- Sales with neither a Premier nor a board premium produce no P&L line. They are listed here instead of
-- disappearing silently; /pl shows the count. Admin only.
create or replace view public.pl_unpriced_sales with (security_invoker = true) as
select c.id as sale_id, c.sale_date,
       (c.sale_date - extract(dow from c.sale_date)::int) as week_start,
       date_trunc('month', c.sale_date)::date             as month_start,
       c.agent_name, c.carrier, c.plan_type, c.post_dated, c.application_status
  from public.sales_commission c
 where public.is_admin() and c.premier_premium is null and c.board_premium is null;
comment on view public.pl_unpriced_sales is
  'Sales with no Premier premium and no board premium: not in pl_line_items until one is recorded. Admin only.';
revoke all on public.pl_line_items, public.pl_daily, public.pl_weekly, public.pl_monthly, public.pl_unpriced_sales
  from public, anon, authenticated;
grant select on public.pl_line_items, public.pl_daily, public.pl_weekly, public.pl_monthly, public.pl_unpriced_sales to authenticated;

do $$ begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$delete from supabase_migrations.schema_migrations
                where version in ('20261031210000','20261031210100','20261031210200','20261031210300','20261031210400')$q$;
  end if;
end $$;

commit;
