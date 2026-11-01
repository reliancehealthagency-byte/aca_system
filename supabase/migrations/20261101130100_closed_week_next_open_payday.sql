-- Slice 4a, part 2 of 2: closed-week rows pay on the NEXT OPEN payday (Kyle directive 11/01 11:26 AM ET, relayed by the
-- Orchestrator; master-context "Closed-week sales: follow the Hub"). The Hub carries a board row entered after a payday's
-- cutoff for an earlier week to the next payday whose cutoff it beats, as its own line (Hub v19.11 L1771-1779). The closed
-- week is never reopened: frozen rows, locks and paid totals don't change.
-- Policy 'hold' (flag, pay NULL, Kyle decides) is the default; supabase/manual/closed_week_autopay_on.sql (NOT a migration:
-- `supabase db push` can't apply it) switches it to 'next_open_payday' with Kyle's go-ahead; closed_week_autopay_off.sql back.
-- ONE combined premier_recon_trueup / premier_lock_payday (Orchestrator X-1, 11/01 12:45 PM): PR #7's hub Lock Open Items
-- exemption (20261101120000, required first) + the closed-week carry + the cutover prerequisites (4a.1, all inside the clock,
-- i.e. no effect before the hub cutover is recorded):
--   G1 a component that was $0 / not yet payable when its payday locked (e.g. Premier confirmed after the lock) pays ONCE on
--      the next locked payday (zero amounts are no longer locked);
--   G2 a board row first seen after the cutover for a hub-era week is carried (policy next_open_payday) or held (hold), never
--      a silent $0 'paid by hub';
--   G3 (NOT changed here): missed spiffs on hub-era rows keep Kyle's PB Q12 rule (anchored to the next open payday, as
--      slice three's S03 test); whether the hub already paid them is a Kyle decision (cutover-prerequisite list in the plan);
--   G4 manual pay adjustments dated on/before the last hub payday are refused on every app path (the SQL Editor may record
--      one as non-posting history; the ledger never posts a payday <= the cutover).
-- Anchoring follows the missed-spiff pattern Kyle approved (PB Q12): a carried component's payday is fixed at first
-- detection (the next submit, or a lock) and never slides afterwards.

alter table public.recon_pay_config add column if not exists closed_week_policy text not null default 'hold';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'recon_pay_config_closed_week_policy') then
    alter table public.recon_pay_config add constraint recon_pay_config_closed_week_policy check (closed_week_policy in ('hold', 'next_open_payday'));
  end if;
end $$;
comment on column public.recon_pay_config.closed_week_policy is
  'hold = a board row first seen in a closed week is flagged and held (pay NULL, Kyle decides); next_open_payday = it pays on the next open payday as its own line (Hub v19.11 L1771-1779; Kyle directive 11/01). Owner-only.';

create table if not exists public.closed_week_carry_anchors (
  line_key     text not null,
  component    text not null check (component in ('commission', 'claimed_spiffs', 'missed_spiffs')),
  orig_payday  date not null,
  payday       date not null check (extract(dow from payday) = 5),
  anchored_at  timestamptz not null default now(),
  note         text,
  primary key (line_key, component)
);
comment on table public.closed_week_carry_anchors is
  'Payday a closed-week row''s component was carried to, fixed at first detection (never moves). Append-only.';
drop trigger if exists closed_week_carry_anchors_immutable on public.closed_week_carry_anchors;
create trigger closed_week_carry_anchors_immutable before update or delete on public.closed_week_carry_anchors
  for each row execute function public.pay_lock_immutable();
drop trigger if exists audit_closed_week_carry_anchors on public.closed_week_carry_anchors;
create trigger audit_closed_week_carry_anchors after insert or update or delete on public.closed_week_carry_anchors
  for each row execute function public.audit_row_change();
alter table public.closed_week_carry_anchors enable row level security;
revoke all on public.closed_week_carry_anchors from anon, public, authenticated, service_role;
grant select on public.closed_week_carry_anchors to authenticated;
drop policy if exists closed_week_carry_anchors_admin_read on public.closed_week_carry_anchors;
create policy closed_week_carry_anchors_admin_read on public.closed_week_carry_anchors for select to authenticated using (public.is_admin());

-- Next OPEN payday on or after d: the first Friday >= d (and after the hub cutover) with no recorded payroll submit.
create or replace function public.recon_next_open_payday(d date) returns date
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare f date; cut date := (select h.last_hub_payday from public.hub_cutover h);
begin
  if d is null then return null; end if;
  f := d + ((5 - extract(dow from d)::int + 7) % 7);
  if cut is not null and f <= cut then f := cut + 7; end if;
  for i in 1 .. 520 loop
    exit when not exists (select 1 from public.payroll_cutoffs c where c.payday = f and c.source = 'submit');
    f := f + 7;
  end loop;
  return f;
end $$;

-- Payroll rule: the shared status rule; a closed-week row is held only under 'hold' (the P&L still uses the status rule only).
create or replace function public.recon_line_pays(p_line_status text, p_added_to_closed_week boolean) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select public.recon_line_status_pays(p_line_status)
     and (not coalesce(p_added_to_closed_week, false)
          or coalesce((select closed_week_policy = 'next_open_payday' from public.recon_pay_config where id), false))
$$;


-- Hub-era late row (G2): a board submission for a week the hub paid (week payday <= cutover) that the cutover did not freeze
-- (first seen after it: no freeze of it existed when the cutover was recorded; a later backend-submit freeze doesn't count).
create or replace function public.recon_hub_era_late(p_submission_key text, p_submitted_at timestamptz) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select h.last_hub_payday from public.hub_cutover h) is not null
     and p_submission_key is not null and p_submitted_at is not null
     and public.recon_friday_after_week((p_submitted_at at time zone 'America/New_York')::date) <= (select h.last_hub_payday from public.hub_cutover h)
     and not exists (select 1 from public.board_week_freezes f, public.hub_cutover h
                      where f.submission_key = p_submission_key and f.frozen_at <= h.recorded_at), false) $$;
revoke execute on function public.recon_hub_era_late(text, timestamptz) from public, anon;
grant execute on function public.recon_hub_era_late(text, timestamptz) to authenticated, service_role;

-- Anchor every carried component not anchored yet (called at each submit, before it is recorded, and at each lock).
create or replace function public.recon_anchor_closed_week_carry() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  if not (public.is_admin() or public.audit_actor_role() in ('service_role', 'postgres', 'supabase_admin')
          or session_user in ('postgres', 'supabase_admin')) then
    raise exception 'recon_anchor_closed_week_carry: admin only';
  end if;
  if coalesce((select closed_week_policy from public.recon_pay_config where id), 'hold') <> 'next_open_payday' then return 0; end if;
  insert into public.closed_week_carry_anchors (line_key, component, orig_payday, payday, note)
  select l.line_key, v.component, v.due, public.recon_next_open_payday(v.due),
         case when coalesce(l.added_to_closed_week, false) then 'carried from a closed week (anchored at first detection)'
              else 'hub-era late row carried (anchored at first detection)' end
    from public.premier_recon_lines l
    cross join lateral (values ('commission', l.commission_pay_friday), ('claimed_spiffs', l.spiff_pay_friday),
                               ('missed_spiffs', l.missed_spiff_pay_friday)) v(component, due)
   where (coalesce(l.added_to_closed_week, false) or public.recon_hub_era_late(l.submission_key, l.submitted_at))
     and public.recon_line_status_pays(l.line_status) and v.due is not null
  on conflict (line_key, component) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.recon_anchor_closed_week_carry(), public.recon_next_open_payday(date) from public, anon;
grant execute on function public.recon_anchor_closed_week_carry(), public.recon_next_open_payday(date) to authenticated, service_role;

-- Submit trigger: as slice three, plus anchoring the carried components (part of the submit).
create or replace function public.payroll_cutoffs_guard() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare owner uuid := public.recon_payroll_owner();
        sql_editor boolean := current_user in ('postgres', 'supabase_admin');
        allowed boolean := coalesce(current_user in ('postgres', 'supabase_admin')
                           or (owner is not null and auth.uid() = owner and current_user <> 'service_role'
                               and public.audit_actor_role() <> 'service_role'), false);   -- fails closed (rev 4 B1)
begin
  if tg_op in ('UPDATE', 'DELETE') and old.source = 'submit' and not sql_editor then
    raise exception 'payroll_cutoffs: the submit for payday % is recorded and final (only the SQL Editor can correct it)', old.payday;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if new.source = 'submit' and (tg_op = 'INSERT' or old.source <> 'submit') then
    if not allowed then
      raise exception 'payroll_cutoffs: only the payroll owner (recon_pay_config.payroll_owner_user_id) or the SQL Editor records a payroll submit';
    end if;
    perform public.premier_anchor_missed_spiffs();
    perform public.recon_anchor_closed_week_carry();   -- slice 4a: rows carried to this payday are anchored before it is submitted
    perform public.recon_freeze_closed_weeks(new.payday, 'payroll_submit');
  end if;
  return new;
end $$;


-- Lock (= push): the combined rule. Per component, the payday it locks on:
--   carried (closed week or hub-era late, next_open_payday): its anchor, else the next open payday;
--   hub Lock Open Item (PR #7, open at the cutover) due on/before the cutover: the first payday locked after it is payable;
--   G1: due on an earlier backend payday (after the cutover, already submitted) and never locked: this payday (once);
--   else: its own due payday. Never: $0, or anything else due on/before the cutover.
create or replace function public.premier_lock_payday(p_payday date) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int; cf record; pol text;
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
  select closed_week_policy into pol from public.recon_pay_config where id;
  perform public.premier_anchor_missed_spiffs();
  perform public.recon_anchor_closed_week_carry();
  insert into public.pay_line_locks (line_key, component, payday, agent_name, agent_id, amount, board_estimate, premier_corrected, note)
  select x.line_key, x.component, p_payday, x.agent_name, x.agent_id, x.amount, x.expected_total, x.actual_total,
         case when x.ex and x.due <= cf.cutover_date then 'locked by premier_lock_payday (hub open item, due ' || x.due || ')'
              when x.carried then 'locked by premier_lock_payday (carried from ' || x.due || ')'
              when x.eff < p_payday then 'locked by premier_lock_payday (payable after the ' || x.eff || ' lock)'
              else 'locked by premier_lock_payday' end
    from (
      select l.line_key, l.agent_name, l.agent_id, l.expected_total, l.actual_total, v.component, v.due, v.amount, l.spiff_pay_friday,
             (ho.kind is not null and v.component = 'commission' or ho.kind = 'unconfirmed') as ex,
             c.carried,
             case when c.carried and pol = 'next_open_payday'
                  then coalesce((select a.payday from public.closed_week_carry_anchors a where a.line_key = l.line_key and a.component = v.component),
                                public.recon_next_open_payday(v.due))
                  else v.due end as eff,
             c.late_held
        from public.premier_recon_lines l
        left join public.hub_lock_open_items ho on ho.line_id = l.hub_line_id and ho.paid_on is null
        cross join lateral (select coalesce(l.added_to_closed_week, false) or public.recon_hub_era_late(l.submission_key, l.submitted_at) as carried_any) cl
        cross join lateral (select cl.carried_any and pol = 'next_open_payday' as carried,
                                   cl.carried_any and pol = 'hold' as late_held) c
        cross join lateral (values ('commission', l.commission_pay_friday, l.actual_commission),
                                   ('claimed_spiffs', l.spiff_pay_friday, coalesce(l.actual_spiffs, 0) - coalesce(l.missed_spiffs, 0)),
                                   ('missed_spiffs', l.missed_spiff_pay_friday, coalesce(l.missed_spiffs, 0))) v(component, due, amount)
       where l.agent_name is not null and l.actual_commission is not null and l.actual_spiffs is not null
         and public.recon_line_pays(l.line_status, cl.carried_any)   -- status rule; a late / closed-week row is held under 'hold'
    ) x
   where x.amount <> 0
     and not exists (select 1 from public.pay_line_locks k where k.line_key = x.line_key and k.component = x.component)
     and (x.eff = p_payday
          or (x.ex and x.due <= cf.cutover_date)                                                             -- PR #7
          or (x.eff > cf.cutover_date and x.eff < p_payday                                                   -- G1
              and exists (select 1 from public.payroll_cutoffs s where s.payday = x.eff and s.source = 'submit')))
  on conflict (line_key, component) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- G4: manual pay adjustments dated on/before the last hub payday are refused on every app path (owner UI, admin key):
-- the hub paid that payroll and hub-era Manual Adjustments are never imported as pay. The SQL Editor (postgres) may still
-- record one as NON-POSTING history (the ledger never posts a payday <= the cutover; LG4), e.g. a hub row kept for audit.
create or replace function public.pay_adjustment_after_cutover() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare cut date := (select h.last_hub_payday from public.hub_cutover h);
begin
  if cut is not null and new.payday <= cut and current_user not in ('postgres', 'supabase_admin') then
    raise exception 'pay adjustments: payday % is on or before the last hub payday % (paid by the hub): enter it on an open payday after the cutover', new.payday, cut;
  end if;
  return new;
end $$;
drop trigger if exists pay_adjustments_after_cutover on public.pay_adjustments;
create trigger pay_adjustments_after_cutover before insert on public.pay_adjustments
  for each row execute function public.pay_adjustment_after_cutover();
revoke execute on function public.pay_adjustment_after_cutover() from public, anon;

-- True-up view: the combined rule (same predicate as premier_lock_payday). Column list = slice three's (as PR #7 keeps it)
-- plus four carry columns at the end, plus G1's pays_on_payday.
create or replace view public.premier_recon_trueup with (security_invoker = true) as
with cfg as (select (select h.last_hub_payday from public.hub_cutover h) as cutover_date),
pol as (select closed_week_policy from public.recon_pay_config where id),
last_submit as (select max(payday) payday from public.payroll_cutoffs where source = 'submit'),
-- PR #7: hub Lock Open Items still open at the cutover (no Paid On): exempt from paid_by_hub
ho as (select line_id, kind from public.hub_lock_open_items where paid_on is null and public.recon_can_read()),
lk as (select line_key,
              sum(amount) filter (where component = 'commission') commission,
              sum(amount) filter (where component = 'claimed_spiffs') claimed,
              sum(amount) filter (where component = 'missed_spiffs') missed,
              bool_or(component = 'commission') has_c, bool_or(component = 'claimed_spiffs') has_s, bool_or(component = 'missed_spiffs') has_m,
              string_agg(distinct agent_name, ', ') agents,
              string_agg(distinct component || '@' || payday::text, ', ') locked_on
         from public.pay_line_locks where public.recon_can_read() group by line_key),
adj as (select line_key, sum(amount) total, string_agg(distinct kind, ',') kinds, bool_or(kind = 'cancel_commission') cancelled
          from public.pay_adjustments where line_key is not null and public.recon_can_read()
         group by line_key),
c as (
  select l.*, coalesce(l.actual_spiffs, 0) - coalesce(l.missed_spiffs, 0) as claimed_spiffs,
         case when lk.has_c then lk.commission end lc_commission,
         case when lk.has_s then lk.claimed end ls_spiffs,
         case when lk.has_m then lk.missed end lm_missed,
         lk.agents locked_agents, lk.locked_on,
         (select cutover_date from cfg) cutover, (select payday from last_submit) last_submit,
         (coalesce(l.added_to_closed_week, false) or public.recon_hub_era_late(l.submission_key, l.submitted_at)) and (select closed_week_policy from pol) = 'hold' as held,
         public.recon_hub_era_late(l.submission_key, l.submitted_at) as hub_era_late,
         l.commission_pay_friday as orig_commission_due, l.spiff_pay_friday as orig_spiff_due, l.missed_spiff_pay_friday as orig_missed_due,
         (coalesce(l.added_to_closed_week, false) or public.recon_hub_era_late(l.submission_key, l.submitted_at)) and (select closed_week_policy from pol) = 'next_open_payday' as carried,
         ho.kind is not null as ex_c,                               -- PR #7: commission exempt (post date or unconfirmed)
         coalesce(ho.kind = 'unconfirmed', false) as ex_s           -- PR #7: spiffs exempt too (unconfirmed only, as the hub)
    from public.premier_recon_lines l
    left join lk on lk.line_key = l.line_key
    left join ho on ho.line_id = l.hub_line_id
),
c2 as (
  -- slice 4a (Kyle directive 11/01, Hub v19.11 L1771-1779): under next_open_payday a closed-week (or hub-era late) row pays
  -- each component on the next OPEN payday (its anchor once anchored); the closed week itself is never reopened.
  select c.*,
         case when c.carried then coalesce((select a.payday from public.closed_week_carry_anchors a where a.line_key = c.line_key and a.component = 'commission'),
                                           public.recon_next_open_payday(c.orig_commission_due)) else c.orig_commission_due end as eff_commission_due,
         case when c.carried then coalesce((select a.payday from public.closed_week_carry_anchors a where a.line_key = c.line_key and a.component = 'claimed_spiffs'),
                                           public.recon_next_open_payday(c.orig_spiff_due)) else c.orig_spiff_due end as eff_spiff_due,
         case when c.carried then coalesce((select a.payday from public.closed_week_carry_anchors a where a.line_key = c.line_key and a.component = 'missed_spiffs'),
                                           public.recon_next_open_payday(c.orig_missed_due)) else c.orig_missed_due end as eff_missed_due
    from c
),
d as (
  select c.*,
         case when lc_commission is not null then lc_commission
              when actual_commission is null then null
              when actual_commission = 0 then 0
              when held and hub_era_late then null                                                   -- G2 (never $0 hub-paid)
              when cutover is not null and eff_commission_due <= cutover and not ex_c then 0
              when cutover is null and eff_commission_due <= last_submit then null
              when held then null
              else actual_commission end as pay_commission,
         case when ls_spiffs is not null then ls_spiffs
              when claimed_spiffs = 0 then 0
              when held and hub_era_late then null
              when cutover is not null and eff_spiff_due <= cutover and not ex_s then 0
              when cutover is null and eff_spiff_due <= last_submit then null
              when held then null
              else claimed_spiffs end as pay_claimed_spiffs,
         case when lm_missed is not null then lm_missed
              when coalesce(missed_spiffs, 0) = 0 then 0
              when held and hub_era_late then null
              when cutover is not null and eff_missed_due <= cutover and not ex_s then 0
              when cutover is null and eff_missed_due <= last_submit then null
              when held then null
              else missed_spiffs end as pay_missed_spiffs,
         case when cutover is null and last_submit is not null and (
                     (lc_commission is null and coalesce(actual_commission, 0) <> 0 and eff_commission_due <= last_submit)
                  or (ls_spiffs is null and claimed_spiffs <> 0 and eff_spiff_due <= last_submit)
                  or (lm_missed is null and coalesce(missed_spiffs, 0) <> 0 and eff_missed_due <= last_submit))
              then 'cutover_pending_kyle'
              when cutover is not null and (
                     (ex_c and lc_commission is null and orig_commission_due <= cutover and coalesce(actual_commission, 0) <> 0)
                  or (ex_s and ls_spiffs is null and claimed_spiffs <> 0 and orig_spiff_due <= cutover)
                  or (ex_s and lm_missed is null and coalesce(missed_spiffs, 0) <> 0 and orig_missed_due <= cutover)
                  or (ex_c and lc_commission is null and orig_commission_due <= cutover and actual_commission is null))
              then 'hub_open_item'
              when cutover is not null and not (held and hub_era_late) and (
                     (lc_commission is null and coalesce(actual_commission, 0) <> 0 and eff_commission_due <= cutover and not ex_c)
                  or (ls_spiffs is null and claimed_spiffs <> 0 and eff_spiff_due <= cutover and not ex_s)
                  or (lm_missed is null and coalesce(missed_spiffs, 0) <> 0 and eff_missed_due <= cutover and not ex_s))
              then 'paid_by_hub' end as cutover_status,
         cutover is not null and last_submit is not null and (
                (lc_commission is null and coalesce(actual_commission, 0) <> 0 and eff_commission_due > cutover and eff_commission_due <= last_submit)
             or (ls_spiffs is null and claimed_spiffs <> 0 and eff_spiff_due > cutover and eff_spiff_due <= last_submit)
             or (lm_missed is null and coalesce(missed_spiffs, 0) <> 0 and eff_missed_due > cutover and eff_missed_due <= last_submit))
           as due_on_submitted_payday_unlocked
    from c2 c
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
       case when d.held and d.cutover_status is distinct from 'cutover_pending_kyle'
                 then case when d.hub_era_late then 'held_hub_era_late_row' else 'held_added_to_closed_week' end
            when d.carried then case when d.hub_era_late then 'hub_era_late_carried' else 'carried_to_next_open_payday' end
            when d.closed_week_change then 'closed_week_change_flag_only'
            when d.dropped_from_export then 'dropped_from_export_flag_only' end as hold_status,
       d.due_on_submitted_payday_unlocked,
       case when d.carried then d.eff_commission_due end as carried_commission_payday,
       case when d.carried then d.eff_spiff_due end as carried_spiff_payday,
       case when d.carried then d.eff_missed_due end as carried_missed_spiff_payday,
       case when d.carried then d.orig_commission_due end as carried_from_payday,
       -- G1: an unlocked payable component due on an already-submitted backend payday locks on the next payday locked
       case when d.due_on_submitted_payday_unlocked then public.recon_next_open_payday(d.last_submit) end as pays_on_payday
  from d left join adj a on a.line_key = d.line_key
 where public.recon_can_read();
