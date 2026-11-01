-- Hub cutover follow-up (11/01): the hub's "Lock Open Items" are imported with the one-time cutover, so the deals the
-- hub held open at its last lock (post dates awaiting first payment; deals unconfirmed in PHS) are NOT treated as
-- paid_by_hub. Mirrors hub v19.11 loadLock_ / applyLockLines_ / unconfLock_: once payable they pay ONCE, on the next
-- open payday. post_date items move the commission only; unconfirmed items move commission and spiffs. Rows with a
-- Paid On (paid by the hub at a later lock) stay paid_by_hub.
-- One-time: rows go in only in the same transaction as the hub_cutover row (refused once it exists); owner / SQL Editor
-- only (service_role refused); immutable; audited. Idempotent DDL (re-running the file changes nothing).
create table if not exists public.hub_lock_open_items (
  id                  bigint generated always as identity primary key,
  file_sha256         text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  row_num             int not null check (row_num >= 1),
  line_id             text not null unique check (line_id ~ '^[0-9]{14}-[^-]+-(P|PADD|ACA|ABS)$'),
  agent_name          text not null,
  member_id           text,
  line_type           text not null,
  original_pay_friday date not null check (extract(dow from original_pay_friday) = 5),
  est_commission      numeric(12,2) not null,
  status_at_lock      text,
  locked_through      date not null check (extract(dow from locked_through) = 5),
  paid_on             date check (paid_on is null or extract(dow from paid_on) = 5),
  kind                text not null check (kind in ('post_date', 'unconfirmed')),
  source              text not null default 'lock_open_items_tab' check (source in ('lock_open_items_tab', 'hub_code_seed')),
  note                text,
  unique (file_sha256, row_num)
);
comment on table public.hub_lock_open_items is
  'Hub Lock Open Items at the one-time cutover. paid_on NULL = still open: exempt from paid_by_hub, pays once on the next open payday when payable. Immutable.';

create or replace function public.hub_lock_open_items_guard() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  perform public.recon_owner_or_sql_editor('hub cutover');
  if exists (select 1 from public.hub_cutover) then
    raise exception 'hub cutover already recorded: Lock Open Items go in only with the one-time cutover (no more rows)';
  end if;
  if new.original_pay_friday > new.locked_through then
    raise exception 'hub open item %: original pay Friday % is after Locked Through %', new.line_id, new.original_pay_friday, new.locked_through;
  end if;
  if new.paid_on is not null and new.paid_on <= new.locked_through then
    raise exception 'hub open item %: Paid On % is not after Locked Through %', new.line_id, new.paid_on, new.locked_through;
  end if;
  return new;
end $$;
drop trigger if exists hub_lock_open_items_guard on public.hub_lock_open_items;
create trigger hub_lock_open_items_guard before insert on public.hub_lock_open_items
  for each row execute function public.hub_lock_open_items_guard();
drop trigger if exists hub_lock_open_items_immutable on public.hub_lock_open_items;
create trigger hub_lock_open_items_immutable before update or delete on public.hub_lock_open_items
  for each row execute function public.pay_lock_immutable();
drop trigger if exists audit_hub_lock_open_items on public.hub_lock_open_items;
create trigger audit_hub_lock_open_items after insert or update or delete on public.hub_lock_open_items
  for each row execute function public.audit_row_change();

alter table public.hub_lock_open_items enable row level security;
revoke all on public.hub_lock_open_items from public, anon, authenticated;
grant select, insert on public.hub_lock_open_items to authenticated;
drop policy if exists hub_lock_open_items_admin on public.hub_lock_open_items;
create policy hub_lock_open_items_admin on public.hub_lock_open_items for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke execute on function public.hub_lock_open_items_guard() from public, anon;

-- True-up: exempt open items from paid_by_hub (new cutover_status 'hub_open_item'). The column list is unchanged (same
-- names, types, order), so the slice-3 views migration stays re-runnable; the payday an open item pays on is in
-- premier_recon_hub_open (below). NOTE: re-running 20261031210100 after this restores the old true-up / lock logic; re-run
-- this migration after it.
create or replace view public.premier_recon_trueup with (security_invoker = true) as
with cfg as (select (select h.last_hub_payday from public.hub_cutover h) as cutover_date),
last_submit as (select max(payday) payday from public.payroll_cutoffs where source = 'submit'),
-- hub Lock Open Items still open at the cutover (no Paid On): exempt from paid_by_hub; they pay on the next open payday
ho as (select line_id, kind from public.hub_lock_open_items where paid_on is null and public.recon_can_read()),
nx as (select greatest((select cutover_date from cfg), (select max(payday) from public.pay_line_locks)) + 7 as next_open),
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
         coalesce(l.added_to_closed_week, false) as held,
         ho.kind is not null as ex_c,                               -- commission exempt (post date or unconfirmed)
         coalesce(ho.kind = 'unconfirmed', false) as ex_s,          -- spiffs exempt too (unconfirmed only, as the hub)
         (select next_open from nx) as next_open
    from public.premier_recon_lines l
    left join lk on lk.line_key = l.line_key
    left join ho on ho.line_id = l.hub_line_id
),
d as (
  select c.*,
         case when lc_commission is not null then lc_commission
              when actual_commission is null then null
              when actual_commission = 0 then 0
              when cutover is not null and commission_pay_friday <= cutover and not ex_c then 0
              when cutover is null and commission_pay_friday <= last_submit then null
              when held then null
              else actual_commission end as pay_commission,
         case when ls_spiffs is not null then ls_spiffs
              when claimed_spiffs = 0 then 0
              when cutover is not null and spiff_pay_friday <= cutover and not ex_s then 0
              when cutover is null and spiff_pay_friday <= last_submit then null
              when held then null
              else claimed_spiffs end as pay_claimed_spiffs,
         case when lm_missed is not null then lm_missed
              when coalesce(missed_spiffs, 0) = 0 then 0
              when cutover is not null and missed_spiff_pay_friday <= cutover and not ex_s then 0
              when cutover is null and missed_spiff_pay_friday <= last_submit then null
              when held then null
              else missed_spiffs end as pay_missed_spiffs,
         case when cutover is null and last_submit is not null and (
                     (lc_commission is null and coalesce(actual_commission, 0) <> 0 and commission_pay_friday <= last_submit)
                  or (ls_spiffs is null and claimed_spiffs <> 0 and spiff_pay_friday <= last_submit)
                  or (lm_missed is null and coalesce(missed_spiffs, 0) <> 0 and missed_spiff_pay_friday <= last_submit))
              then 'cutover_pending_kyle'
              when cutover is not null and (
                     (ex_c and lc_commission is null and commission_pay_friday <= cutover and coalesce(actual_commission, 0) <> 0)
                  or (ex_s and ls_spiffs is null and claimed_spiffs <> 0 and spiff_pay_friday <= cutover)
                  or (ex_s and lm_missed is null and coalesce(missed_spiffs, 0) <> 0 and missed_spiff_pay_friday <= cutover)
                  or (ex_c and lc_commission is null and commission_pay_friday <= cutover and actual_commission is null))
              then 'hub_open_item'
              when cutover is not null and (
                     (lc_commission is null and coalesce(actual_commission, 0) <> 0 and commission_pay_friday <= cutover and not ex_c)
                  or (ls_spiffs is null and claimed_spiffs <> 0 and spiff_pay_friday <= cutover and not ex_s)
                  or (lm_missed is null and coalesce(missed_spiffs, 0) <> 0 and missed_spiff_pay_friday <= cutover and not ex_s))
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

-- Hub open items still open at the cutover, per board line: kind, current true-up status, and the payday an exempt
-- component pays on once Premier confirms (the next open payday after the cutover / the last lock).
create or replace view public.premier_recon_hub_open with (security_invoker = true) as
select o.line_id as hub_line_id, t.line_key, o.agent_name, o.kind as hub_open_kind, o.original_pay_friday, o.est_commission,
       t.cutover_status,
       case when t.cutover_status = 'hub_open_item'
             and coalesce(t.pay_commission, 0) + coalesce(t.pay_claimed_spiffs, 0) + coalesce(t.pay_missed_spiffs, 0) <> 0
            then greatest((select h.last_hub_payday from public.hub_cutover h), (select max(payday) from public.pay_line_locks)) + 7
       end as hub_open_pay_friday
  from public.hub_lock_open_items o
  left join public.premier_recon_trueup t on t.hub_line_id = o.line_id
 where o.paid_on is null and public.recon_can_read();
revoke all on public.premier_recon_hub_open from public, anon, authenticated;
grant select on public.premier_recon_hub_open to authenticated;

-- Locking: an exempt component due on/before the cutover locks on the first payday locked after it is payable.
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
  select l.line_key, v.component, p_payday, l.agent_name, l.agent_id, v.amount, l.expected_total, l.actual_total, case when ho.kind is not null and v.due <= cf.cutover_date then 'locked by premier_lock_payday (hub open item, due ' || v.due || ')' else 'locked by premier_lock_payday' end
    from public.premier_recon_lines l
    left join public.hub_lock_open_items ho on ho.line_id = l.hub_line_id and ho.paid_on is null
    cross join lateral (values ('commission', l.commission_pay_friday, l.actual_commission),
                               ('claimed_spiffs', l.spiff_pay_friday, coalesce(l.actual_spiffs, 0) - coalesce(l.missed_spiffs, 0)),
                               ('missed_spiffs', l.missed_spiff_pay_friday, coalesce(l.missed_spiffs, 0))) v(component, due, amount)
   where l.agent_name is not null and l.actual_commission is not null and l.actual_spiffs is not null
     and public.recon_line_pays(l.line_status, l.added_to_closed_week)   -- same predicate as the P&L rep pay (rev 4)
     and (v.due = p_payday
          -- hub Lock Open Items (open at the cutover): their parts due on/before the cutover pay on the FIRST payday
          -- locked after they become payable (the hub's "next open payday"); on conflict keeps it to once
          or (v.due <= cf.cutover_date and v.amount <> 0
              and (ho.kind is not null and v.component = 'commission' or ho.kind = 'unconfirmed')))
  on conflict (line_key, component) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
