-- Hub cutover follow-up (11/01): the hub's "Lock Open Items" are imported with the one-time cutover, so the deals the
-- hub held open at its last lock (post dates awaiting first payment; deals unconfirmed in PHS) are NOT treated as
-- paid_by_hub. Mirrors hub v19.11 loadLock_ / applyLockLines_ / unconfLock_: once payable they pay ONCE, on the next
-- open payday. post_date items move the commission only; unconfirmed items move commission and spiffs. Rows with a
-- Paid On (paid by the hub at a later lock) stay paid_by_hub.
-- One-time: rows go in only in the same transaction as the hub_cutover row (refused once it exists); owner / SQL Editor
-- only (service_role refused); immutable; audited. Idempotent DDL (re-running the file changes nothing).
-- Also: hub-era line-linked Manual Adjustments (Covers 'pay spiff:<line>' etc.) are imported as paid-elsewhere markers
-- (hub_paid_elsewhere): never imported as pay; the marked component of that line pays $0 in the backend from then on.
--
-- ORDER GUARD (Orchestrator 11/01): this migration replaces premier_recon_trueup / premier_lock_payday. If slice 4a
-- (20261101100000 actuals ledger / 20261101100100 closed-week carry) is already applied, running it would silently drop
-- 4a's carry, so it refuses. Merge order: #7 first, then 4a rebased on top ships the combined view and lock function.
do $order$ declare s4a boolean := to_regclass('public.closed_week_carry_anchors') is not null
                                    or to_regclass('public.ledger_accounts') is not null;
begin
  if not s4a and to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$select exists (select 1 from supabase_migrations.schema_migrations where version in ('20261101100000', '20261101100100'))$q$ into s4a;
  end if;
  if s4a then
    raise exception 'migration 20261101120000 REFUSED: slice 4a (20261101100000 / 20261101100100) is already applied; this migration would replace 4a''s premier_recon_trueup / premier_lock_payday and drop its closed-week carry (merge order: #7 first, then 4a rebased on top)';
  end if;
end $order$;

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
  source              text not null default 'lock_open_items_tab' check (source = 'lock_open_items_tab'),
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

-- Hub-era line-linked Manual Adjustments (Covers column or the hub code COVER_SEEDS_): paid-elsewhere markers. Not pay:
-- the hub already paid / reversed / clawed that item inside its paydays (all in the Paid Lock totals). Each marks one
-- component of one line (spiff:<line> = spiffs, comm:<line> = commission): the backend pays it $0 and never locks it.
create table if not exists public.hub_paid_elsewhere (
  id           bigint generated always as identity primary key,
  file_sha256  text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  tab_row      int not null check (tab_row >= 2),
  line_id      text not null check (line_id ~ '^[0-9]{14}-[^-]+-(P|PADD|ACA|ABS)$'),
  component    text not null check (component in ('commission', 'spiffs')),
  cover_kind   text not null check (cover_kind in ('pay', 'reverse', 'dup', 'claw')),
  agent_name   text not null,
  payday       date not null check (extract(dow from payday) = 5),
  amount       numeric(12,2) not null,
  source       text not null check (source in ('covers_column', 'cover_seed')),
  note         text,
  unique (file_sha256, tab_row, line_id, component)
);
comment on table public.hub_paid_elsewhere is
  'Hub-era line-linked Manual Adjustments at the one-time cutover (paid-elsewhere markers, not pay): the marked component of the line pays 0 in the backend. Immutable.';
create or replace function public.hub_paid_elsewhere_guard() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  perform public.recon_owner_or_sql_editor('hub cutover');
  if exists (select 1 from public.hub_cutover) then
    raise exception 'hub cutover already recorded: paid-elsewhere markers go in only with the one-time cutover (no more rows)';
  end if;
  return new;
end $$;
drop trigger if exists hub_paid_elsewhere_guard on public.hub_paid_elsewhere;
create trigger hub_paid_elsewhere_guard before insert on public.hub_paid_elsewhere
  for each row execute function public.hub_paid_elsewhere_guard();
drop trigger if exists hub_paid_elsewhere_immutable on public.hub_paid_elsewhere;
create trigger hub_paid_elsewhere_immutable before update or delete on public.hub_paid_elsewhere
  for each row execute function public.pay_lock_immutable();
drop trigger if exists audit_hub_paid_elsewhere on public.hub_paid_elsewhere;
create trigger audit_hub_paid_elsewhere after insert or update or delete on public.hub_paid_elsewhere
  for each row execute function public.audit_row_change();
alter table public.hub_paid_elsewhere enable row level security;
revoke all on public.hub_paid_elsewhere from public, anon, authenticated;
grant select, insert on public.hub_paid_elsewhere to authenticated;
drop policy if exists hub_paid_elsewhere_admin on public.hub_paid_elsewhere;
create policy hub_paid_elsewhere_admin on public.hub_paid_elsewhere for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke execute on function public.hub_paid_elsewhere_guard() from public, anon;

-- True-up: exempt open items from paid_by_hub (new cutover_status 'hub_open_item'). The column list is unchanged (same
-- names, types, order), so the slice-3 views migration stays re-runnable; the payday an open item pays on is in
-- premier_recon_hub_open (below). NOTE: re-running 20261031210100 after this restores the old true-up / lock logic; re-run
-- this migration after it.
create or replace view public.premier_recon_trueup with (security_invoker = true) as
with cfg as (select (select h.last_hub_payday from public.hub_cutover h) as cutover_date),
last_submit as (select max(payday) payday from public.payroll_cutoffs where source = 'submit'),
-- hub Lock Open Items still open at the cutover (no Paid On): exempt from paid_by_hub; they pay on the next open payday
ho as (select line_id, kind from public.hub_lock_open_items where paid_on is null and public.recon_can_read()),
pe as (select line_id, bool_or(component = 'commission') pe_c, bool_or(component = 'spiffs') pe_s
         from public.hub_paid_elsewhere where public.recon_can_read() group by line_id),
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
         coalesce(pe.pe_c, false) as pe_c,                          -- commission paid elsewhere (hub adjustment)
         coalesce(pe.pe_s, false) as pe_s,                          -- spiffs paid elsewhere (hub adjustment)
         ho.kind is not null and not coalesce(pe.pe_c, false) as ex_c,                  -- commission exempt (post date or unconfirmed)
         coalesce(ho.kind = 'unconfirmed', false) and not coalesce(pe.pe_s, false) as ex_s,  -- spiffs exempt too (unconfirmed only)
         (select next_open from nx) as next_open
    from public.premier_recon_lines l
    left join lk on lk.line_key = l.line_key
    left join ho on ho.line_id = l.hub_line_id
    left join pe on pe.line_id = l.hub_line_id
),
d as (
  select c.*,
         case when lc_commission is not null then lc_commission
              when pe_c then 0                                         -- paid elsewhere (hub adjustment): never again
              when actual_commission is null then null
              when actual_commission = 0 then 0
              when cutover is not null and commission_pay_friday <= cutover and not ex_c then 0
              when cutover is null and commission_pay_friday <= last_submit then null
              when held then null
              else actual_commission end as pay_commission,
         case when ls_spiffs is not null then ls_spiffs
              when pe_s then 0
              when claimed_spiffs = 0 then 0
              when cutover is not null and spiff_pay_friday <= cutover and not ex_s then 0
              when cutover is null and spiff_pay_friday <= last_submit then null
              when held then null
              else claimed_spiffs end as pay_claimed_spiffs,
         case when lm_missed is not null then lm_missed
              when pe_s then 0
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
              when cutover is not null and ((pe_c and lc_commission is null) or (pe_s and ls_spiffs is null and lm_missed is null))
              then 'hub_paid_elsewhere'
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
    left join (select line_id, bool_or(component = 'commission') pe_c, bool_or(component = 'spiffs') pe_s
                 from public.hub_paid_elsewhere group by line_id) pe on pe.line_id = l.hub_line_id
    cross join lateral (values ('commission', l.commission_pay_friday, l.actual_commission),
                               ('claimed_spiffs', l.spiff_pay_friday, coalesce(l.actual_spiffs, 0) - coalesce(l.missed_spiffs, 0)),
                               ('missed_spiffs', l.missed_spiff_pay_friday, coalesce(l.missed_spiffs, 0))) v(component, due, amount)
   where l.agent_name is not null and l.actual_commission is not null and l.actual_spiffs is not null
     and public.recon_line_pays(l.line_status, l.added_to_closed_week)   -- same predicate as the P&L rep pay (rev 4)
     -- hub-era line-linked adjustments (hub_paid_elsewhere): that component was paid elsewhere; never locked / paid again
     and not (v.component = 'commission' and coalesce(pe.pe_c, false))
     and not (v.component <> 'commission' and coalesce(pe.pe_s, false))
     and (v.due = p_payday
          -- hub Lock Open Items (open at the cutover): their parts due on/before the cutover pay on the FIRST payday
          -- locked after they become payable (the hub's "next open payday"); on conflict keeps it to once
          or (v.due <= cf.cutover_date and v.amount <> 0
              and (ho.kind is not null and v.component = 'commission' or ho.kind = 'unconfirmed')))
  on conflict (line_key, component) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- SETTLED BY HUB (Orchestrator 11/01 should-fix 2): a refund / void whose clawback payday is on/before the cutover, or whose
-- commission the hub clawed by hand (a 'claw' marker, e.g. tab row 9), was settled by the hub. It shows 'settled_by_hub'
-- (never 'needs_kyle_approve') and a clawback_approved adjustment for it is refused, so it can't be clawed twice.
create or replace view public.premier_recon_clawbacks with (security_invoker = true) as
select x.*,
       x.hub_era_date or x.hub_claw_marker as settled_by_hub,
       case when x.hub_claw_marker then 'hub clawed it by hand (claw marker, tab row ' || x.claw_rows || ')'
            when x.hub_era_date then 'clawback payday ' || x.clawback_pay_friday || ' is on/before the hub cutover ' || x.last_hub_payday
       end as settled_reason,
       case when x.hub_era_date or x.hub_claw_marker then 'settled_by_hub'
            when exists (select 1 from public.pay_adjustments a where a.line_key = x.line_key and a.kind = 'clawback_approved') then 'approved'
            else 'needs_kyle_approve' end as status
  from (select l.line_key, l.hub_line_id, l.member_id, l.agent_name, l.line_status, l.clawback_proposed, l.clawback_pay_friday,
               h.last_hub_payday,
               coalesce(h.last_hub_payday is not null and l.clawback_pay_friday <= h.last_hub_payday, false) as hub_era_date,
               m.rows is not null as hub_claw_marker, m.rows as claw_rows
          from public.premier_recon_lines l
          left join public.hub_cutover h on true
          left join (select line_id, string_agg(distinct tab_row::text, ', ') rows from public.hub_paid_elsewhere
                      where component = 'commission' and cover_kind = 'claw' group by line_id) m on m.line_id = l.hub_line_id
         where l.clawback_proposed is not null and public.recon_can_read()) x;
revoke all on public.premier_recon_clawbacks from public, anon, authenticated;
grant select on public.premier_recon_clawbacks to authenticated;

create or replace function public.pay_adjustments_hub_clawback_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare why text;
begin
  if new.kind = 'clawback_approved' then
    select settled_reason into why from public.premier_recon_clawbacks where line_key = new.line_key and settled_by_hub;
    if why is null and new.line_key is not null then      -- also when the line is not (or no longer) a proposed clawback
      select coalesce(case when exists (select 1 from public.hub_paid_elsewhere p where p.line_id = l.hub_line_id
                                         and p.component = 'commission' and p.cover_kind = 'claw') then 'hub claw marker' end,
                      case when l.clawback_pay_friday <= (select last_hub_payday from public.hub_cutover) then 'clawback payday on/before the hub cutover' end)
        into why from public.premier_recon_lines l where l.line_key = new.line_key;
    end if;
    if why is not null then
      raise exception 'clawback_approved REFUSED for %: settled by hub (%); approving it would claw it a second time', new.line_key, why;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists pay_adjustments_hub_clawback_guard on public.pay_adjustments;
create trigger pay_adjustments_hub_clawback_guard before insert on public.pay_adjustments
  for each row execute function public.pay_adjustments_hub_clawback_guard();
revoke execute on function public.pay_adjustments_hub_clawback_guard() from public, anon;

-- MARKER DRIFT (should-fix 3): a marker zeroes the whole part for good. When the backend amount on a marked part differs
-- from what the hub paid / clawed (a later add-on, a reinstatement), it is listed here (status 'differs') and logged once per
-- amount by premier_log_recon_events (hub_cutover.paid_elsewhere_amount_differs) instead of being silently lost.
-- hub_amount per line part: pay +amount, dup -amount (paid outside), claw -amount (clawed); a multi-line row is split evenly;
-- 'reverse' rows only move money between agents (not counted). backend_amount: commission = actual_commission,
-- spiffs = actual_spiffs (which already includes missed_spiffs).
create or replace view public.premier_recon_paid_elsewhere_drift with (security_invoker = true) as
with m as (select line_id, component, cover_kind, tab_row,
                  amount / count(*) over (partition by file_sha256, tab_row) as per_line
             from public.hub_paid_elsewhere where public.recon_can_read()),
h as (select line_id, component,
             sum(case cover_kind when 'pay' then per_line when 'dup' then -per_line when 'claw' then -per_line end) as hub_amount,
             string_agg(tab_row || ' ' || cover_kind, ', ' order by tab_row) as hub_rows
        from m group by 1, 2)
select h.line_id as hub_line_id, l.line_key, l.agent_name, h.component, h.hub_rows, round(h.hub_amount, 2) as hub_amount,
       case when l.line_key is null then null when h.component = 'commission' then coalesce(l.actual_commission, 0)
            else coalesce(l.actual_spiffs, 0) end as backend_amount,
       case when l.line_key is null or h.hub_amount is null then null
            else (case when h.component = 'commission' then coalesce(l.actual_commission, 0)
                       else coalesce(l.actual_spiffs, 0) end) - round(h.hub_amount, 2) end as difference,
       case when l.line_key is null then 'board_line_not_loaded'
            when h.hub_amount is null then 'reverse_only'
            when abs((case when h.component = 'commission' then coalesce(l.actual_commission, 0)
                           else coalesce(l.actual_spiffs, 0) end) - round(h.hub_amount, 2)) > 0.005 then 'differs'
            else 'matches' end as status
  from h left join public.premier_recon_lines l on l.hub_line_id = h.line_id;
revoke all on public.premier_recon_paid_elsewhere_drift from public, anon, authenticated;
grant select on public.premier_recon_paid_elsewhere_drift to authenticated;

-- premier_log_recon_events: byte copy of 20261031210200 except the clawback flag (settled_by_hub, above) and the drift event.
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
    -- hub cutover (20261101120000): a hub-era clawback (date on/before the cutover, or clawed by hand via a hub 'claw' marker)
    -- is settled by the hub: shown as such, never 'needs Kyle approve' (and a clawback_approved for it is refused)
    select case when c.settled_by_hub then 'clawback_settled:' else 'clawback:' end || c.line_key, c.line_key,
           case when c.settled_by_hub
                then jsonb_build_object('kind', 'clawback_settled_by_hub', 'member_id', c.member_id, 'agent', c.agent_name,
                                        'amount', c.clawback_proposed, 'payday', c.clawback_pay_friday, 'status', 'settled by hub',
                                        'settled_reason', c.settled_reason)
                else jsonb_build_object('kind', 'clawback_proposed', 'member_id', c.member_id, 'agent', c.agent_name, 'amount', c.clawback_proposed,
                                        'payday', c.clawback_pay_friday, 'status', 'needs Kyle approve; spiffs kept') end
      from public.premier_recon_clawbacks c
    union all
    -- a part marked paid elsewhere whose backend amount now differs from what the hub paid (later add-on / reinstatement)
    select 'pe_drift:' || d.hub_line_id || ':' || d.component || ':' || d.backend_amount, coalesce(d.line_key, d.hub_line_id),
           jsonb_build_object('kind', 'paid_elsewhere_amount_differs', 'hub_line_id', d.hub_line_id, 'component', d.component,
                              'hub_amount', d.hub_amount, 'backend_amount', d.backend_amount, 'difference', d.difference,
                              'status', 'review: the backend pays this part $0 (hub marker); the difference is not paid automatically')
      from public.premier_recon_paid_elsewhere_drift d where d.status = 'differs'
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
                   when r.d->>'kind' in ('clawback_settled_by_hub', 'paid_elsewhere_amount_differs') then 'hub_cutover.' || (r.d->>'kind')
                   else 'premier.info' end,
              uid, rl, 'board_submissions', r.ref, 'EVENT', r.d);
      insert into public.premier_recon_event_state(state_key, state) values ('info:' || r.k, r.d);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- RERUN GUARD (Orchestrator 11/01): re-running 20261031210100 (views) or 20261031210200 (lock function) puts back the
-- slice-three true-up / lock function WITHOUT the open-item exemption and paid-elsewhere markers; payroll would then
-- silently treat open items as paid_by_hub (and could pay a marked line again). While this migration is in place, no
-- payday can be locked in that state: re-run 20261101120000 after them.
create or replace function public.hub_open_items_schema_ok() returns boolean
language sql stable set search_path = public, pg_temp as $$
  select pg_get_viewdef('public.premier_recon_trueup'::regclass) like '%hub_lock_open_items%'
     and pg_get_viewdef('public.premier_recon_trueup'::regclass) like '%hub_paid_elsewhere%'
     and coalesce((select prosrc from pg_proc where oid = 'public.premier_lock_payday(date)'::regprocedure), '') like '%hub_lock_open_items%'
     and coalesce((select prosrc from pg_proc where oid = 'public.premier_lock_payday(date)'::regprocedure), '') like '%hub_paid_elsewhere%'
     and coalesce((select prosrc from pg_proc where oid = 'public.premier_log_recon_events()'::regprocedure), '') like '%premier_recon_clawbacks%'
$$;
create or replace function public.pay_line_locks_hub_schema_guard() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if not public.hub_open_items_schema_ok() then
    raise exception 'pay_line_locks REFUSED: premier_recon_trueup / premier_lock_payday lack the hub open-item exemption and paid-elsewhere markers (migration 20261101120000 is in place, but 20261031210100 / 20261031210200 were re-run after it): re-run 20261101120000 first';
  end if;
  return null;
end $$;
drop trigger if exists pay_line_locks_hub_schema_guard on public.pay_line_locks;
create trigger pay_line_locks_hub_schema_guard before insert on public.pay_line_locks
  for each statement execute function public.pay_line_locks_hub_schema_guard();
revoke execute on function public.pay_line_locks_hub_schema_guard() from public, anon;
