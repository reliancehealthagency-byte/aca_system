-- ROLLBACK for migration 20261101120000_hub_lock_open_items (hub Lock Open Items import + open-item exemption).
-- ONE transaction: any error rolls the whole thing back. Run in the SQL Editor (postgres) only if the migration must be undone.
-- What it does:
--   1. Refuses once the cutover has started: any hub_paid_lock row, a recorded hub_cutover row, or any hub_lock_open_items /
--      hub_paid_elsewhere row (only ever written together with the cutover); and when slice 4a is applied on top. Then nothing is changed. Also refuses a non-postgres
--      caller (DDL; SQL Editor only).
--   2. Restores the pre-migration schema exactly:
--      - premier_recon_trueup, premier_lock_payday(date) and premier_log_recon_events() back to their slice-three definitions (the blocks below are
--        byte-copies of 20261031210100_premier_recon_views.sql and 20261031210200_premier_recon_rls_events.sql;
--        create or replace keeps their grants, owner and comments, which the migration never changed);
--      - drops premier_recon_hub_open, the tables hub_lock_open_items and hub_paid_elsewhere (their triggers and
--        policies go with them), their guard functions, and the rerun guard (trigger pay_line_locks_hub_schema_guard,
--        pay_line_locks_hub_schema_guard(), hub_open_items_schema_ok()), the views premier_recon_clawbacks and
--        premier_recon_paid_elsewhere_drift, and the clawback guard (trigger + pay_adjustments_hub_clawback_guard()).
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
  if to_regclass('public.closed_week_carry_anchors') is not null or to_regclass('public.ledger_accounts') is not null then
    raise exception 'hub_lock_open_items rollback refused: slice 4a is applied on top; restoring the slice-three true-up / lock function would drop 4a''s carry';
  end if;
  if to_regclass('public.hub_paid_elsewhere') is not null then
    execute 'select count(*) from public.hub_paid_elsewhere' into n;
    if n > 0 then raise exception 'hub_lock_open_items rollback refused: % paid-elsewhere marker(s) in hub_paid_elsewhere; export them first', n; end if;
  end if;
  execute 'select count(*) from public.hub_lock_open_items' into n;
  if n > 0 then
    raise exception 'hub_lock_open_items rollback refused: % imported open item(s) in hub_lock_open_items; export them first', n;
  end if;
end $$;

drop view if exists public.premier_recon_hub_open;
drop trigger if exists pay_adjustments_hub_clawback_guard on public.pay_adjustments;
drop function if exists public.pay_adjustments_hub_clawback_guard();
drop trigger if exists pay_line_locks_hub_schema_guard on public.pay_line_locks;
drop function if exists public.pay_line_locks_hub_schema_guard();
drop function if exists public.hub_open_items_schema_ok();

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

-- ===== premier_log_recon_events: byte-copy of 20261031210200_premier_recon_rls_events.sql =====
create or replace function public.premier_log_recon_events() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r record; prev jsonb; cur jsonb; n int := 0; uid uuid := public.audit_actor_uid(); rl text := public.audit_actor_role();
  base jsonb;
begin
  if not (public.is_admin() or rl in ('service_role', 'postgres', 'supabase_admin')) then
    raise exception 'premier_log_recon_events: admin only';
  end if;
  perform public.premier_anchor_missed_spiffs();

  for r in select * from public.premier_recon_lines
            where line_type in ('P', 'PADD') and line_status not in ('duplicate_board_row', 'not_in_premier') loop
    cur := jsonb_build_object('premium', r.premier_premium_incl_one_time, 'paid_status', r.paid_status,
                              'pay_friday', r.commission_pay_friday, 'post_dated', r.premier_post_dated);
    select state into prev from public.premier_recon_event_state where state_key = 'line:' || r.line_key;
    base := coalesce(prev, jsonb_build_object('premium', r.board_premium, 'paid_status', 'board_claim',
                                               'pay_friday', r.expected_pay_friday, 'post_dated', r.board_post_date));
    if (base->>'premium') is distinct from (cur->>'premium')
       and abs(coalesce((base->>'premium')::numeric, 0) - coalesce((cur->>'premium')::numeric, 0)) > 0.01 then
      insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, detail)
      values ('premium_mismatch', uid, rl, 'board_submissions', r.line_key, 'EVENT',
              jsonb_build_object('source', 'premier_recon', 'line_key', r.line_key, 'member_id', r.member_id, 'agent', r.agent_name, 'attribution', 'unchanged',
                                 'from', base->'premium', 'from_source', case when prev is null then 'board_claim' else 'premier_previous' end,
                                 'to', cur->'premium', 'premier_excl_one_time', r.premier_premium_excl_one_time,
                                 'paid_on', 'premier_premium', 'open_item', r.open_item));
      n := n + 1;
    end if;
    if (base->>'paid_status') is distinct from (cur->>'paid_status')
       and not (prev is null and r.paid_status in ('confirmed', 'confirmed_inactive')) then
      insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, detail)
      values ('premier.paid_status_diff', uid, rl, 'board_submissions', r.line_key, 'EVENT',
              jsonb_build_object('member_id', r.member_id, 'agent', r.agent_name, 'from', base->'paid_status', 'to', cur->'paid_status',
                                 'hold', r.hold_reasons, 'refund_pending', r.refund_pending));
      n := n + 1;
    end if;
    if (base->>'pay_friday') is distinct from (cur->>'pay_friday') then
      insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, detail)
      values ('premier.pay_week_diff', uid, rl, 'board_submissions', r.line_key, 'EVENT',
              jsonb_build_object('member_id', r.member_id, 'agent', r.agent_name, 'from', base->'pay_friday', 'to', cur->'pay_friday',
                                 'premier_first_billing_date', r.premier_first_billing_date, 'keyed_off', 'premier_billing_date'));
      n := n + 1;
    end if;
    if (base->>'post_dated') is distinct from (cur->>'post_dated') then
      insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, detail)
      values ('premier.post_date_diff', uid, rl, 'board_submissions', r.line_key, 'EVENT',
              jsonb_build_object('member_id', r.member_id, 'agent', r.agent_name, 'from', base->'post_dated', 'to', cur->'post_dated',
                                 'board_post_date', r.board_post_date, 'premier_first_billing_date', r.premier_first_billing_date));
      n := n + 1;
    end if;
    insert into public.premier_recon_event_state(state_key, state, updated_at) values ('line:' || r.line_key, cur, now())
    on conflict (state_key) do update set state = excluded.state, updated_at = now()
      where premier_recon_event_state.state is distinct from excluded.state;
  end loop;

  -- one-off info items
  for r in
    select 'duplicate_board_row:' || line_key k, line_key ref,
           jsonb_build_object('kind', 'duplicate_board_row', 'member_id', member_id, 'agent', agent_name, 'pay', 0,
                              'note', 'same member already on an earlier board row; this row pays nothing') d
      from public.premier_recon_lines where line_status = 'duplicate_board_row'
    union all
    select 'agent_ref:' || line_key, line_key,
           jsonb_build_object('kind', 'premier_agent_label_differs', 'member_id', member_id, 'board_agent', agent_name,
                              'premier_agent_label', premier_agent_label, 'attribution', 'unchanged (board)')
      from public.premier_recon_lines
     where premier_agent_label is not null and agent_name is not null and line_status <> 'duplicate_board_row'
       and lower(regexp_replace(premier_agent_label, '^.*-\s*', '')) <> lower(agent_name)
    union all
    select 'addon_mismatch:' || line_key, line_key,
           jsonb_build_object('kind', 'addon_mismatch', 'member_id', member_id, 'agent', agent_name,
                              'board_answer', board_addon_answer, 'paid_on', 'premier_products',
                              'note', case when board_addon_answer is null then 'board AO blank: Premier add-on on the original deal is paid (missed spiff caught)'
                                           else 'board AO is a claim only; Premier products on the original deal decide +5% and spiffs' end)
      from public.premier_recon_lines where board_vs_premier_products_differ and line_status <> 'duplicate_board_row'
    union all
    select 'blank_created:' || line_key, line_key,
           jsonb_build_object('kind', 'blank_product_created_date', 'member_id', member_id, 'rows', blank_created,
                              'note', 'product with no Created Date never counts toward the original deal (Q11 working rule)')
      from public.premier_recon_lines where coalesce(blank_created, 0) > 0
    union all
    select 'open:' || line_key, line_key,
           jsonb_build_object('kind', 'open_decision', 'member_id', member_id, 'agent', agent_name, 'open_item', open_item,
                              'reading_a', open_alt_a_total, 'reading_b', open_alt_b_total, 'status', 'pending Kyle decision')
      from public.premier_recon_open_items
    union all
    select 'clawback:' || line_key, line_key,
           jsonb_build_object('kind', 'clawback_proposed', 'member_id', member_id, 'agent', agent_name, 'amount', clawback_proposed,
                              'payday', clawback_pay_friday, 'status', 'needs Kyle approve; spiffs kept')
      from public.premier_recon_lines where clawback_proposed is not null
    union all
    select 'abs_flag:' || line_key, line_key,
           jsonb_build_object('kind', 'abs_amount_flag', 'member_id', member_id, 'agent', agent_name, 'amount', board_premium, 'items', abs_items)
      from public.premier_recon_lines where abs_flagged
    union all
    select 'unmatched_premier:' || coalesce(member_id, 'blank:' || md5(coalesce(note, ''))), coalesce(member_id, 'blank'),
           jsonb_build_object('kind', category, 'member_id', member_id, 'premier_agent_label_reference', premier_agent_label_reference,
                              'premium', premier_premium, 'note', note)
      from public.premier_recon_unmatched_premier where category <> 'cancelled_enrollment'
    union all
    select 'rerun:' || o.member_id || ':' || n.member_id, o.member_id,
           jsonb_build_object('kind', 'possible_rerun', 'refunded_member_id', o.member_id, 'new_member_id', n.member_id,
                              'note', 'flag only: the new ID is credited only if it is on the board')
      from public.premier_member_status o
      join public.premier_member_status n on n.member_id <> o.member_id
       and (n.phone_sha256 = o.phone_sha256 or n.email_sha256 = o.email_sha256)
       and n.member_created_date between o.member_created_date and o.member_created_date + (select rerun_match_days from public.recon_pay_config where id)
     where o.paid_status = 'refunded' and n.paid_status in ('confirmed', 'confirmed_inactive')
    union all
    -- rev 3: only when the content really changed (an unchanged copy in a re-export logs nothing), once per new content
    select 'revised:' || b.submission_key || ':' || md5(b.raw_fields::text), b.submission_key || '-P',
           jsonb_build_object('kind', 'board_submission_revised', 'submission_key', b.submission_key, 'member_id', b.member_id,
                              'agent', b.agent_name, 'versions', b.versions, 'current_import_id', b.import_id,
                              'changed_columns', (select string_agg(public.recon_col_letter(g - 1), ',' order by g)
                                                    from generate_series(1, cardinality(b.raw_fields)) g
                                                   where b.raw_fields[g] is distinct from b.prev_raw_fields[g]),
                              'note', 'a later board export changed this submission; only the latest version is paid')
      from public.board_submissions_current b where b.changed_from_previous and not b.frozen
    union all
    select 'dropped:' || b.submission_key || ':' || b.latest_import_id, b.submission_key || '-P',
           jsonb_build_object('kind', 'dropped_from_export', 'submission_key', b.submission_key, 'member_id', b.member_id,
                              'agent', b.agent_name, 'last_import_id', b.import_id, 'latest_import_id', b.latest_import_id,
                              'note', 'missing from the newest board export inside its Timestamp range (deleted or re-timestamped row). Flag only: its last version still pays; removing it is a manual Kyle correction')
      from public.board_submissions_current b where b.dropped_from_export and not b.frozen
    union all
    select 'closed_week:' || b.submission_key || ':' || b.newest_id || ':' || b.dropped_from_export, b.submission_key || '-P',
           jsonb_build_object('kind', 'closed_week_change', 'submission_key', b.submission_key, 'member_id', b.member_id,
                              'agent', b.agent_name, 'week_payday', b.week_payday, 'frozen_board_id', b.id,
                              'newest_board_id', b.newest_id, 'dropped', b.dropped_from_export,
                              'note', 'a later export changed or removed a submission of a closed week: flag only, pay stays on the frozen version')
      from public.board_submissions_current b where b.closed_week_change
    union all
    select 'added_closed:' || b.submission_key, b.submission_key || '-P',
           jsonb_build_object('kind', 'added_to_closed_week', 'submission_key', b.submission_key, 'member_id', b.member_id,
                              'agent', b.agent_name, 'week_payday', b.week_payday,
                              'note', 'first seen in an already-closed week: held, never paid automatically (Kyle decides)')
      from public.board_submissions_current b where b.added_to_closed_week
  loop
    if not exists (select 1 from public.premier_recon_event_state where state_key = 'info:' || r.k) then
      insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, detail)
      values (case when r.d->>'kind' = 'addon_mismatch' then 'addon_mismatch'
                   when r.d->>'kind' in ('closed_week_change', 'added_to_closed_week', 'dropped_from_export') then 'board.' || (r.d->>'kind')
                   else 'premier.info' end,
              uid, rl, 'board_submissions', r.ref, 'EVENT', r.d);
      insert into public.premier_recon_event_state(state_key, state) values ('info:' || r.k, r.d);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

drop view if exists public.premier_recon_clawbacks;
drop view if exists public.premier_recon_paid_elsewhere_drift;
drop table if exists public.hub_lock_open_items;
drop function if exists public.hub_lock_open_items_guard();
drop table if exists public.hub_paid_elsewhere;
drop function if exists public.hub_paid_elsewhere_guard();

do $$ begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations where version = '20261101120000';
  end if;
end $$;

do $$ declare cols text; begin
  if to_regclass('public.hub_lock_open_items') is not null or to_regclass('public.premier_recon_hub_open') is not null
     or to_regclass('public.hub_paid_elsewhere') is not null or to_regclass('public.premier_recon_clawbacks') is not null
     or to_regclass('public.premier_recon_paid_elsewhere_drift') is not null
     or exists (select 1 from pg_proc where proname in ('hub_lock_open_items_guard', 'hub_paid_elsewhere_guard',
                                                         'hub_open_items_schema_ok', 'pay_line_locks_hub_schema_guard',
                                                         'pay_adjustments_hub_clawback_guard'))
     or exists (select 1 from pg_trigger where tgname in ('pay_line_locks_hub_schema_guard', 'pay_adjustments_hub_clawback_guard'))
     or (select prosrc from pg_proc where oid = 'public.premier_log_recon_events()'::regprocedure) like '%premier_recon_clawbacks%' then
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
