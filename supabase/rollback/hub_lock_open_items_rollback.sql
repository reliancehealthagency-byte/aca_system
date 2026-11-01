-- ROLLBACK for migration 20261101120000_hub_lock_open_items (hub Lock Open Items import + open-item exemption).
-- ONE transaction: any error rolls the whole thing back. Run in the SQL Editor (postgres) only if the migration must be undone.
-- What it does:
--   1. Refuses once the cutover has started: any hub_paid_lock row, a recorded hub_cutover row, or any hub_lock_open_items
--      row (open items are only ever written together with the cutover). Then nothing is changed. Also refuses a non-postgres
--      caller (DDL; SQL Editor only).
--   2. Restores the pre-migration schema exactly:
--      - premier_recon_trueup and premier_lock_payday(date) back to their slice-three definitions (the blocks below are
--        byte-copies of 20261031210100_premier_recon_views.sql and 20261031210200_premier_recon_rls_events.sql;
--        create or replace keeps their grants, owner and comments, which the migration never changed);
--      - drops premier_recon_hub_open, the table hub_lock_open_items (its triggers and policy go with it) and
--        hub_lock_open_items_guard().
--   3. Deletes version 20261101120000 from supabase_migrations.schema_migrations.
--   4. Post-checks inside the transaction (raises = everything rolled back): no hub_lock_open_items objects left, the
--      true-up and lock function no longer reference them, and the true-up column list is the slice-three one.
-- Not touched: event_log (append-only history), every other table, view and row.
-- Order: run this BEFORE slice3_rollback.sql (premier_recon_hub_open depends on premier_recon_trueup).
-- Verified identical in scripts/local_test_hub_cutover.sh (group K): pg_dump --schema-only of a fresh build of main ==
-- the same build after migration + this rollback.
begin;

do $$ declare n bigint; begin
  if current_user not in ('postgres', 'supabase_admin') then
    raise exception 'hub_lock_open_items rollback refused: run it in the SQL Editor (postgres), not as %', current_user;
  end if;
  if to_regclass('public.hub_lock_open_items') is null then
    raise exception 'hub_lock_open_items rollback refused: migration 20261101120000 is not applied (nothing to roll back)';
  end if;
  select (select count(*) from public.hub_paid_lock) + (select count(*) from public.hub_cutover) into n;
  if n > 0 then
    raise exception 'hub_lock_open_items rollback refused: the hub cutover has been applied (% hub_paid_lock / hub_cutover row(s)); the clock started', n;
  end if;
  execute 'select count(*) from public.hub_lock_open_items' into n;
  if n > 0 then
    raise exception 'hub_lock_open_items rollback refused: % imported open item(s) in hub_lock_open_items; export them first', n;
  end if;
end $$;

drop view if exists public.premier_recon_hub_open;

-- ===== premier_recon_trueup: byte-copy of 20261031210100_premier_recon_views.sql =====
create or replace view public.premier_recon_trueup with (security_invoker = true) as
with cfg as (select (select h.last_hub_payday from public.hub_cutover h) as cutover_date),
last_submit as (select max(payday) payday from public.payroll_cutoffs where source = 'submit'),
lk as (select line_key,
              sum(amount) filter (where component = 'commission') commission,
              sum(amount) filter (where component = 'claimed_spiffs') claimed,
              sum(amount) filter (where component = 'missed_spiffs') missed,
              bool_or(component = 'commission') has_c, bool_or(component = 'claimed_spiffs') has_s, bool_or(component = 'missed_spiffs') has_m,
              string_agg(distinct agent_name, ', ') agents,
              string_agg(distinct component || '@' || payday::text, ', ') locked_on
         from public.pay_line_locks where public.recon_can_read() group by line_key),
adj as (select line_key, sum(amount) total, string_agg(distinct kind, ',') kinds, bool_or(kind = 'cancel_commission') cancelled
          from public.pay_adjustments where line_key is not null and public.recon_can_read() group by line_key),
c as (
  select l.*, coalesce(l.actual_spiffs, 0) - coalesce(l.missed_spiffs, 0) as claimed_spiffs,
         case when lk.has_c then lk.commission end lc_commission,
         case when lk.has_s then lk.claimed end ls_spiffs,
         case when lk.has_m then lk.missed end lm_missed,
         lk.agents locked_agents, lk.locked_on,
         (select cutover_date from cfg) cutover, (select payday from last_submit) last_submit,
         coalesce(l.added_to_closed_week, false) as held
    from public.premier_recon_lines l
    left join lk on lk.line_key = l.line_key
),
d as (
  select c.*,
         case when lc_commission is not null then lc_commission
              when actual_commission is null then null
              when actual_commission = 0 then 0
              when cutover is not null and commission_pay_friday <= cutover then 0
              when cutover is null and commission_pay_friday <= last_submit then null
              when held then null
              else actual_commission end as pay_commission,
         case when ls_spiffs is not null then ls_spiffs
              when claimed_spiffs = 0 then 0
              when cutover is not null and spiff_pay_friday <= cutover then 0
              when cutover is null and spiff_pay_friday <= last_submit then null
              when held then null
              else claimed_spiffs end as pay_claimed_spiffs,
         case when lm_missed is not null then lm_missed
              when coalesce(missed_spiffs, 0) = 0 then 0
              when cutover is not null and missed_spiff_pay_friday <= cutover then 0
              when cutover is null and missed_spiff_pay_friday <= last_submit then null
              when held then null
              else missed_spiffs end as pay_missed_spiffs,
         case when cutover is null and last_submit is not null and (
                     (lc_commission is null and coalesce(actual_commission, 0) <> 0 and commission_pay_friday <= last_submit)
                  or (ls_spiffs is null and claimed_spiffs <> 0 and spiff_pay_friday <= last_submit)
                  or (lm_missed is null and coalesce(missed_spiffs, 0) <> 0 and missed_spiff_pay_friday <= last_submit))
              then 'cutover_pending_kyle'
              when cutover is not null and (
                     (lc_commission is null and coalesce(actual_commission, 0) <> 0 and commission_pay_friday <= cutover)
                  or (ls_spiffs is null and claimed_spiffs <> 0 and spiff_pay_friday <= cutover)
                  or (lm_missed is null and coalesce(missed_spiffs, 0) <> 0 and missed_spiff_pay_friday <= cutover))
              then 'paid_by_hub' end as cutover_status,
         cutover is not null and last_submit is not null and (
                (lc_commission is null and coalesce(actual_commission, 0) <> 0 and commission_pay_friday > cutover and commission_pay_friday <= last_submit)
             or (ls_spiffs is null and claimed_spiffs <> 0 and spiff_pay_friday > cutover and spiff_pay_friday <= last_submit)
             or (lm_missed is null and coalesce(missed_spiffs, 0) <> 0 and missed_spiff_pay_friday > cutover and missed_spiff_pay_friday <= last_submit))
           as due_on_submitted_payday_unlocked
    from c
)
select d.line_key, d.hub_line_id, d.agent_name, d.line_type, d.member_id, d.line_status,
       d.expected_total as stage1_board_estimate,
       d.actual_total as stage2_premier_corrected,
       coalesce(d.lc_commission, 0) as locked_commission,
       coalesce(d.ls_spiffs, 0) + coalesce(d.lm_missed, 0) as locked_spiffs,
       d.lc_commission is not null as commission_locked,
       d.ls_spiffs is not null or d.lm_missed is not null as spiffs_locked,
       case when d.lc_commission is not null or d.ls_spiffs is not null or d.lm_missed is not null
            then coalesce(d.lc_commission, 0) + coalesce(d.ls_spiffs, 0) + coalesce(d.lm_missed, 0) end as stage3_payroll_actual,
       case when d.lc_commission is not null then d.actual_commission - d.lc_commission end as true_up_commission_due,
       case when d.ls_spiffs is not null or d.lm_missed is not null
            then d.actual_spiffs - coalesce(d.ls_spiffs, 0) - coalesce(d.lm_missed, 0) end as true_up_spiffs_due,
       coalesce(a.total, 0) as adjustments_total, a.kinds as adjustment_kinds,
       coalesce(a.cancelled, false) as commission_cancelled,
       d.locked_agents as locked_agent_names,
       coalesce(d.locked_agents is not null and strpos(d.locked_agents, d.agent_name) = 0, false) as agent_changed_after_lock,
       d.cutover_status,
       d.pay_commission, d.pay_claimed_spiffs, d.pay_missed_spiffs,
       d.pay_commission + d.pay_claimed_spiffs + d.pay_missed_spiffs + coalesce(a.total, 0) as final_payable,
       d.locked_on, d.dropped_from_export, d.closed_week_change, d.added_to_closed_week,
       case when d.held and d.cutover_status is distinct from 'cutover_pending_kyle' then 'held_added_to_closed_week'
            when d.closed_week_change then 'closed_week_change_flag_only'
            when d.dropped_from_export then 'dropped_from_export_flag_only' end as hold_status,
       d.due_on_submitted_payday_unlocked
  from d left join adj a on a.line_key = d.line_key
 where public.recon_can_read();

-- ===== premier_lock_payday: byte-copy of 20261031210200_premier_recon_rls_events.sql =====
create or replace function public.premier_lock_payday(p_payday date) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int; cf record;
begin
  -- rev 4 (Kyle 7:14 PM ET 10/31): locking is owner-only (payroll owner or SQL Editor break-glass); service_role refused.
  if public.recon_owner_or_break_glass() is not true then
    raise exception 'premier_lock_payday: owner only (the payroll owner or the SQL Editor; caller %)', coalesce(public.audit_actor_role(), current_user);
  end if;
  if extract(dow from p_payday) <> 5 then raise exception 'payday must be a Friday'; end if;
  select (select h.last_hub_payday from public.hub_cutover h) as cutover_date into cf;
  if cf.cutover_date is null then
    raise exception 'premier_lock_payday: the hub cutover is not imported yet; nothing is locked until the hub file starts the clock';
  end if;
  if not exists (select 1 from public.payroll_cutoffs where payday = p_payday and source = 'submit') then
    raise exception 'premier_lock_payday: payday % has no recorded payroll submit (payroll_cutoffs source = submit); record Kyle''s submit time first', p_payday;
  end if;
  if p_payday <= cf.cutover_date then
    raise exception 'premier_lock_payday: payday % is on or before the cutover % (paid by the hub)', p_payday, cf.cutover_date;
  end if;
  perform public.premier_anchor_missed_spiffs();
  insert into public.pay_line_locks (line_key, component, payday, agent_name, agent_id, amount, board_estimate, premier_corrected, note)
  select l.line_key, v.component, p_payday, l.agent_name, l.agent_id, v.amount, l.expected_total, l.actual_total, 'locked by premier_lock_payday'
    from public.premier_recon_lines l
    cross join lateral (values ('commission', l.commission_pay_friday, l.actual_commission),
                               ('claimed_spiffs', l.spiff_pay_friday, coalesce(l.actual_spiffs, 0) - coalesce(l.missed_spiffs, 0)),
                               ('missed_spiffs', l.missed_spiff_pay_friday, coalesce(l.missed_spiffs, 0))) v(component, due, amount)
   where l.agent_name is not null and l.actual_commission is not null and l.actual_spiffs is not null
     and public.recon_line_pays(l.line_status, l.added_to_closed_week)   -- same predicate as the P&L rep pay (rev 4)
     and v.due = p_payday
  on conflict (line_key, component) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

drop table if exists public.hub_lock_open_items;
drop function if exists public.hub_lock_open_items_guard();

do $$ begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261101120000';
  end if;
end $$;

do $$ declare cols text; begin
  if to_regclass('public.hub_lock_open_items') is not null or to_regclass('public.premier_recon_hub_open') is not null
     or exists (select 1 from pg_proc where proname = 'hub_lock_open_items_guard') then
    raise exception 'hub_lock_open_items rollback post-check failed: objects left behind';
  end if;
  if pg_get_viewdef('public.premier_recon_trueup'::regclass) like '%hub_lock_open_items%'
     or (select prosrc from pg_proc where oid = 'public.premier_lock_payday(date)'::regprocedure) like '%hub_lock_open_items%' then
    raise exception 'hub_lock_open_items rollback post-check failed: true-up / lock function still reference the open items';
  end if;
  select string_agg(attname, ',' order by attnum) into cols from pg_attribute
   where attrelid = 'public.premier_recon_trueup'::regclass and attnum > 0 and not attisdropped;
  if md5(cols) <> '56ceb427a6b4661ad7583833c62cdcd8' then
    raise exception 'hub_lock_open_items rollback post-check failed: premier_recon_trueup columns differ from slice three';
  end if;
  raise notice 'hub_lock_open_items rollback OK: schema back to before 20261101120000';
end $$;

commit;
notify pgrst, 'reload schema';
