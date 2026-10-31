-- Slice three, part 3 of 3: RLS + grants (admin only), the diff-event logger and the payday lock.

-- ---------- RLS ----------
do $$
declare t text;
begin
  foreach t in array array['recon_pay_config','agent_pay_rules','payroll_cutoffs','recon_imports','premier_member_products',
                           'board_submissions','premier_recon_event_state','premier_addon_map','policy_count_claims',
                           'pay_line_locks','pay_adjustments','missed_spiff_anchors','board_week_freezes','hub_paid_lock',
                           'hub_cutover','agent_name_aliases'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
  end loop;
end $$;
revoke all on public.board_submissions_current, public.board_export_diffs, public.premier_products_current, public.premier_member_status, public.premier_recon_lines,
              public.premier_recon_unmatched_board, public.premier_recon_unmatched_premier, public.premier_recon_open_items,
              public.premier_policy_count_check, public.premier_recon_trueup, public.sales_missing_member_id
  from public, anon, authenticated;

-- Admin users read everything and write config / imports / adjustments. Staging and locks are insert-only (immutable).
-- rev 3: recon_pay_config.payroll_owner_user_id / adjustment_server_path are guarded by recon_pay_config_guard, a recorded
-- payroll submit by payroll_cutoffs_guard and the one-time hub cutover by hub_cutover_guard (below): an admin's grants do
-- not reach them.
-- premier_recon_event_state has no policy at all: only the security-definer logger touches it.
grant select on public.recon_pay_config, public.agent_pay_rules, public.payroll_cutoffs, public.recon_imports,
                public.premier_member_products, public.board_submissions, public.premier_addon_map, public.policy_count_claims,
                public.pay_line_locks, public.pay_adjustments, public.missed_spiff_anchors,
                public.board_week_freezes, public.hub_paid_lock, public.hub_cutover, public.agent_name_aliases,
                public.board_submissions_current, public.board_export_diffs, public.premier_products_current, public.premier_member_status, public.premier_recon_lines,
                public.premier_recon_unmatched_board, public.premier_recon_unmatched_premier, public.premier_recon_open_items,
                public.premier_policy_count_check, public.premier_recon_trueup, public.sales_missing_member_id
  to authenticated;
grant update on public.recon_pay_config to authenticated;
grant insert, update, delete on public.agent_pay_rules, public.payroll_cutoffs, public.premier_addon_map, public.policy_count_claims
  to authenticated;
grant insert on public.recon_imports, public.premier_member_products, public.board_submissions, public.pay_adjustments,
                public.hub_paid_lock, public.hub_cutover
  to authenticated;
grant insert, update, delete on public.agent_name_aliases to authenticated;

do $$
declare t text;
begin
  foreach t in array array['recon_pay_config','agent_pay_rules','payroll_cutoffs','recon_imports','premier_member_products',
                           'board_submissions','premier_addon_map','policy_count_claims','pay_line_locks','missed_spiff_anchors',
                           'board_week_freezes','hub_paid_lock','hub_cutover','agent_name_aliases'] loop
    execute format('drop policy if exists %1$s_admin on public.%1$I', t);
    execute format('create policy %1$s_admin on public.%1$I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end $$;
-- pay_adjustments (rev 4, Kyle directly 10/31 7:03 PM ET): admins READ and any admin may INSERT. Rows are immutable
-- (trigger), so there is no update/delete policy. The BEFORE INSERT trigger enforces the same rule, refuses service_role,
-- allows postgres only as audited break-glass, and overwrites entered_by / entered_by_uid / created_by from auth.uid().
drop policy if exists pay_adjustments_admin on public.pay_adjustments;
drop policy if exists pay_adjustments_admin_read on public.pay_adjustments;
drop policy if exists pay_adjustments_owner_insert on public.pay_adjustments;
create policy pay_adjustments_admin_read on public.pay_adjustments for select to authenticated using (public.is_admin());
drop policy if exists pay_adjustments_admin_insert on public.pay_adjustments;
-- rev 4 (Kyle directly, 10/31 7:03 PM ET): any admin may insert; the trigger stamps entered_by from auth.uid().
create policy pay_adjustments_admin_insert on public.pay_adjustments for insert to authenticated
  with check (auth.uid() is not null and public.is_admin());

-- ---------- payroll owner / cutover / submit guards (rev 3) ----------
-- "Server" = the SQL Editor (postgres / supabase_admin) or the service_role key, checked with current_user (these
-- trigger functions are NOT security definer, so current_user is the caller).
create or replace function public.recon_payroll_owner() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select payroll_owner_user_id from public.recon_pay_config where id $$;
create or replace function public.recon_cutover_bounds(out last_submit date, out first_locked date)
language sql stable security definer set search_path = public, pg_temp as $$
  select (select max(payday) from public.payroll_cutoffs where source = 'submit'),
         (select min(payday) from public.pay_line_locks) $$;

create or replace function public.recon_pay_config_guard() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare who text := current_user; uid uuid := auth.uid();
        sql_editor boolean := current_user in ('postgres', 'supabase_admin');
begin
  -- payroll ownership and the server adjustment path: only the current owner or the SQL Editor (postgres); while no owner
  -- is set, only the SQL Editor. service_role and other admins are refused (Orchestrator review 2, blocker 2).
  if new.payroll_owner_user_id is distinct from old.payroll_owner_user_id
     or new.adjustment_server_path is distinct from old.adjustment_server_path then
    if current_user = 'service_role' or public.audit_actor_role() = 'service_role' then
      raise exception 'recon_pay_config: the service_role (admin key) can''t change the payroll owner / adjustment_server_path';
    elsif old.payroll_owner_user_id is null and not sql_editor then
      raise exception 'recon_pay_config: payroll owner not set: only the project owner in the SQL Editor (postgres) can set payroll_owner_user_id / adjustment_server_path (caller %)', who;
    elsif old.payroll_owner_user_id is not null and not (sql_editor or uid = old.payroll_owner_user_id) then
      raise exception 'recon_pay_config: only the current payroll owner (or the SQL Editor) can change payroll_owner_user_id / adjustment_server_path';
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists recon_pay_config_guard on public.recon_pay_config;
create trigger recon_pay_config_guard before update on public.recon_pay_config
  for each row execute function public.recon_pay_config_guard();

-- Missed-spiff anchors (PB Q12): record the payday of every missed spiff not anchored yet, as it reads NOW.
create or replace function public.premier_anchor_missed_spiffs() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  if not (public.is_admin() or public.audit_actor_role() in ('service_role', 'postgres', 'supabase_admin')
          or session_user in ('postgres', 'supabase_admin')) then
    raise exception 'premier_anchor_missed_spiffs: admin only';
  end if;
  insert into public.missed_spiff_anchors (line_key, payday, amount, mode, note)
  select l.line_key, l.missed_spiff_pay_friday, l.missed_spiffs, 'next_open_payday', 'anchored at first detection'
    from public.premier_recon_lines l, public.recon_pay_config c
   where c.id and c.missed_spiff_payday = 'next_open_payday' and l.line_status <> 'duplicate_board_row'
     and coalesce(l.missed_spiffs, 0) <> 0 and l.missed_spiff_pay_friday is not null and not l.missed_spiff_anchored
  on conflict (line_key) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Closed weeks: freeze every current submission whose week payday is on or before p_payday (Kyle 10/31: a closed week's
-- board data is never revised).
create or replace function public.recon_freeze_closed_weeks(p_payday date, p_reason text) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int; owner uuid := public.recon_payroll_owner();
begin
  -- only the payroll owner or the SQL Editor (they are the ones who record submits / the hub cutover)
  if not ((owner is not null and auth.uid() = owner and public.audit_actor_role() <> 'service_role')
          or (auth.uid() is null and public.audit_actor_role() in ('postgres', 'supabase_admin'))) then
    raise exception 'recon_freeze_closed_weeks: payroll owner or SQL Editor only';
  end if;
  if extract(dow from p_payday) <> 5 then raise exception 'payday must be a Friday'; end if;
  insert into public.board_week_freezes (submission_key, board_id, week_payday, reason)
  select b.submission_key, b.id, b.week_payday, p_reason
    from public.board_submissions_current b
   where b.week_payday <= p_payday and not b.frozen and not b.added_to_closed_week
  on conflict (submission_key) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- A recorded submit is final, and only the owner / SQL Editor records one. Before a submit is recorded, every missed
-- spiff is anchored (the next-open-payday rule would otherwise move it to the payday after this one) and the weeks it
-- closes are frozen.
create or replace function public.payroll_cutoffs_guard() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare owner uuid := public.recon_payroll_owner();
        sql_editor boolean := current_user in ('postgres', 'supabase_admin');
        allowed boolean := current_user in ('postgres', 'supabase_admin')
                           or (owner is not null and auth.uid() = owner and current_user <> 'service_role'
                               and public.audit_actor_role() <> 'service_role');
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
    perform public.recon_freeze_closed_weeks(new.payday, 'payroll_submit');
  end if;
  return new;
end $$;
drop trigger if exists payroll_cutoffs_guard on public.payroll_cutoffs;
create trigger payroll_cutoffs_guard before insert or update or delete on public.payroll_cutoffs
  for each row execute function public.payroll_cutoffs_guard();

-- ---------- one-time hub cutover (rev 3, Kyle 10/31 relayed via Orchestrator) ----------
-- The hub "Paid Lock" export (scripts/csv_to_recon_sql.py --hub) inserts its rows into hub_paid_lock, then ONE hub_cutover
-- row. Same protection as payroll ownership: the current owner, or the SQL Editor while no owner is set; service_role and
-- other admins are refused. Once recorded it can't be reset, edited or moved (immutable); no more hub rows are accepted.
create or replace function public.recon_owner_or_sql_editor(what text) returns void
language plpgsql set search_path = public, pg_temp as $$
declare owner uuid := public.recon_payroll_owner();
begin
  if current_user in ('postgres', 'supabase_admin') then return; end if;
  if current_user = 'service_role' or public.audit_actor_role() = 'service_role' then
    raise exception '%: the service_role (admin key) is refused; the payroll owner or the SQL Editor (postgres) only', what;
  end if;
  if owner is null then
    raise exception '%: payroll owner not set: only the project owner in the SQL Editor (postgres) may do this (caller %)', what, current_user;
  elsif auth.uid() is distinct from owner then
    raise exception '%: only the payroll owner (or the SQL Editor) may do this', what;
  end if;
end $$;
create or replace function public.hub_paid_lock_guard() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  perform public.recon_owner_or_sql_editor('hub cutover');
  if exists (select 1 from public.hub_cutover) then
    raise exception 'hub cutover already recorded: the hub file is imported once (no more hub rows)';
  end if;
  return new;
end $$;
drop trigger if exists hub_paid_lock_guard on public.hub_paid_lock;
create trigger hub_paid_lock_guard before insert on public.hub_paid_lock
  for each row execute function public.hub_paid_lock_guard();
create or replace function public.hub_cutover_guard() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare b record; ds date[]; n int;
begin
  perform public.recon_owner_or_sql_editor('hub cutover');
  select array_agg(distinct payday order by payday), count(*) into ds, n from public.hub_paid_lock where file_sha256 = new.file_sha256;
  if n = 0 then raise exception 'hub cutover: no hub_paid_lock rows for file %', new.file_sha256; end if;
  new.paydays := ds; new.last_hub_payday := ds[cardinality(ds)]; new.row_count := n;
  new.recorded_at := now(); new.recorded_by := auth.uid(); new.recorded_role := public.audit_actor_role();
  select * into b from public.recon_cutover_bounds();
  if b.last_submit is not null and new.last_hub_payday < b.last_submit then
    raise exception 'hub cutover: the file ends at % but payday % is already submitted: that payroll would be paid again', new.last_hub_payday, b.last_submit;
  end if;
  if b.first_locked is not null then
    raise exception 'hub cutover: this system already locked payday %; the cutover can''t be recorded after the clock started', b.first_locked;
  end if;
  return new;
end $$;
drop trigger if exists hub_cutover_guard on public.hub_cutover;
create trigger hub_cutover_guard before insert on public.hub_cutover
  for each row execute function public.hub_cutover_guard();
create or replace function public.hub_cutover_recorded() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  n := public.recon_freeze_closed_weeks(new.last_hub_payday, 'hub_cutover');
  insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, detail)
  values ('payroll.hub_cutover.recorded', public.audit_actor_uid(), public.audit_actor_role(), 'hub_cutover', new.file_sha256, 'EVENT',
          jsonb_build_object('file_name', new.file_name, 'last_hub_payday', new.last_hub_payday, 'paydays', new.paydays,
                             'rows', new.row_count, 'board_submissions_frozen', n,
                             'note', 'clock started: these paydays are paid_by_hub; one-time, immutable'));
  return new;
end $$;
drop trigger if exists hub_cutover_recorded on public.hub_cutover;
create trigger hub_cutover_recorded after insert on public.hub_cutover
  for each row execute function public.hub_cutover_recorded();

-- ---------- finalize a board export (rev 3) ----------
-- Called once per board import, in the same transaction as its rows (the import script does). Refuses:
--   * an empty export;
--   * a STALE export: its newest Timestamp is older than the newest Timestamp of the latest finalized export;
--   * an export that would REVERT a submission to a version a later export already replaced (e.g. an older download
--     re-imported after a newer one), unless p_allow_revert (Kyle checked the revert is intended).
create or replace function public.recon_finalize_board_import(p_import_id bigint, p_allow_revert boolean default false) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare imp record; lat record; mn timestamptz; mx timestamptz; n int; reverted text;
begin
  if not (public.is_admin() or public.audit_actor_role() in ('service_role', 'postgres', 'supabase_admin')) then
    raise exception 'recon_finalize_board_import: admin only';
  end if;
  select * into imp from public.recon_imports where id = p_import_id and kind = 'sales_board' for update;
  if imp.id is null then raise exception 'recon_finalize_board_import: % is not a board import', p_import_id; end if;
  if imp.finalized_at is not null then return 0; end if;
  select count(*), min(submitted_at), max(submitted_at) into n, mn, mx from public.board_submissions where import_id = p_import_id;
  if n = 0 then raise exception 'board import % (%) has no rows: nothing to finalize', p_import_id, imp.file_name; end if;
  select * into lat from public.recon_imports
   where kind = 'sales_board' and finalized_at is not null order by finalized_at desc, id desc limit 1;
  if lat.id is not null and mx < lat.max_submitted_at then
    raise exception 'board import % (%) is STALE: its newest Timestamp % is older than the latest export''s % (import %); export the board again',
      p_import_id, imp.file_name, mx at time zone 'America/New_York', lat.max_submitted_at at time zone 'America/New_York', lat.id;
  end if;
  if not p_allow_revert then
    select string_agg(nw.submission_key, ', ' order by nw.submission_key) into reverted
      from public.board_submissions nw
      join public.board_submissions_current cur on cur.submission_key = nw.submission_key
     where nw.import_id = p_import_id and nw.raw_fields is distinct from cur.raw_fields
       and exists (select 1 from public.board_submissions old join public.recon_imports oi on oi.id = old.import_id
                    where old.submission_key = nw.submission_key and oi.finalized_at is not null
                      and old.id <> cur.id and old.raw_fields = nw.raw_fields);
    if reverted is not null then
      raise exception 'board import % (%) would revert submission(s) % to a version a later export replaced (stale download?); re-export, or finalize with p_allow_revert after checking',
        p_import_id, imp.file_name, reverted;
    end if;
  end if;
  update public.recon_imports set finalized_at = clock_timestamp(), min_submitted_at = mn, max_submitted_at = mx where id = p_import_id;
  return n;
end $$;

-- ---------- diff-event logger ----------
-- Compares the reconciliation with what was last logged (premier_recon_event_state) and writes ONLY changes to event_log:
--   premium_mismatch (same name as slice one's sales trigger), premier.paid_status_diff, premier.pay_week_diff, premier.post_date_diff  (first run: vs the board claim)
--   premier.info (once per item): duplicate board row, late CS add-on ignored, Premier agent label differs (attribution
--   unchanged), blank member ID, PHS-only member, OPEN decision, possible rerun, ABS amount flag, clawback proposed.
-- Nothing about pay or attribution is changed by an event. Re-running with the same data writes nothing.
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

-- ---------- payday lock (stage 3) ----------
-- Writes the payroll-actual amount of every component due on one payday, ONCE per (line, component) across all paydays
-- (rev 3, constraint pay_line_locks_once). Refuses a payday with no recorded submit, before the hub cutover is imported,
-- and on or before the cutover (the hub paid those). OPEN rows (actual NULL), duplicates and rows held as added to a closed
-- week are not locked.
create or replace function public.premier_lock_payday(p_payday date) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int; cf record;
begin
  if not (public.is_admin() or public.audit_actor_role() in ('service_role', 'postgres', 'supabase_admin')) then
    raise exception 'premier_lock_payday: admin only';
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
     and l.line_status <> 'duplicate_board_row'
     and not coalesce(l.added_to_closed_week, false)
     and v.due = p_payday
  on conflict (line_key, component) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public.premier_log_recon_events(), public.premier_lock_payday(date) from public, anon;
grant execute on function public.premier_log_recon_events(), public.premier_lock_payday(date) to authenticated, service_role;
revoke execute on function public.premier_parse_raw(), public.board_parse_raw(), public.recon_staging_immutable(),
                           public.pay_lock_immutable(), public.recon_import_check() from public, anon, authenticated;
revoke execute on function public.recon_finalize_board_import(bigint, boolean), public.premier_anchor_missed_spiffs(),
                           public.recon_payroll_owner(), public.recon_cutover_bounds(), public.recon_owner_or_sql_editor(text),
                           public.recon_pay_config_guard(), public.payroll_cutoffs_guard(), public.hub_paid_lock_guard(),
                           public.hub_cutover_guard(), public.recon_scrub_text(text, text[]), public.recon_agent_id(text)
  from public, anon;
grant execute on function public.recon_finalize_board_import(bigint, boolean), public.premier_anchor_missed_spiffs(),
                          public.recon_payroll_owner(), public.recon_cutover_bounds(), public.recon_owner_or_sql_editor(text),
                          public.recon_pay_config_guard(), public.payroll_cutoffs_guard(), public.hub_paid_lock_guard(),
                          public.hub_cutover_guard(), public.recon_scrub_text(text, text[]), public.recon_agent_id(text)
  to authenticated, service_role;
revoke execute on function public.recon_freeze_closed_weeks(date, text) from public, anon;
grant execute on function public.recon_freeze_closed_weeks(date, text) to authenticated;
revoke execute on function public.hub_cutover_recorded(), public.recon_imports_immutable() from public, anon, authenticated;
revoke execute on function public.recon_premier_required_cols(), public.recon_premier_allowed_cols(), public.recon_board_expected_cols()
  from public, anon;

-- Slice-three helper functions: signed-in users and server roles only (PUBLIC/anon get nothing).
revoke execute on function public.recon_parse_date(text), public.recon_parse_ts_et(text), public.recon_parse_money(text),
  public.recon_yes(text), public.recon_digits(text), public.recon_col_letter(int), public.recon_can_read(),
  public.recon_friday_after_week(date), public.premier_row_fees(jsonb, text), public.premier_product_addon(text, text, boolean),
  public.board_answer_addons(text), public.abs_item_count(numeric), public.recon_spiff_payday(timestamptz, date)
  from public, anon;
grant execute on function public.recon_parse_date(text), public.recon_parse_ts_et(text), public.recon_parse_money(text),
  public.recon_yes(text), public.recon_digits(text), public.recon_col_letter(int), public.recon_can_read(),
  public.recon_friday_after_week(date), public.premier_row_fees(jsonb, text), public.premier_product_addon(text, text, boolean),
  public.board_answer_addons(text), public.abs_item_count(numeric), public.recon_spiff_payday(timestamptz, date)
  to authenticated, service_role;

-- payroll.adjustment.recorded: one internal event per manual adjustment (any admin, rev 4; rows are append-only).
create or replace function public.log_pay_adjustment() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.entered_by like 'break-glass:%' then
    insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, detail)
    values ('payroll.adjustment.break_glass', public.audit_actor_uid(), public.audit_actor_role(), 'pay_adjustments', new.id::text, 'EVENT',
            jsonb_build_object('agent', new.agent_name, 'payday', new.payday, 'amount', new.amount, 'entered_by', new.entered_by,
                               'source_entered_by', new.source_entered_by, 'external_ref', new.external_ref,
                               'note', 'inserted from the SQL Editor (no signed-in admin): break-glass path, review'));
  end if;
  insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, detail)
  values ('payroll.adjustment.recorded', public.audit_actor_uid(), public.audit_actor_role(), 'pay_adjustments', new.id::text, 'EVENT',
          jsonb_build_object('agent', new.agent_name, 'payday', new.payday, 'kind', new.kind, 'component', new.component,
                             'amount', new.amount, 'note', new.reason, 'line_key', new.line_key, 'member_id', new.member_id,
                             'covers', new.covers, 'reason_code', new.reason_code, 'entered_by', new.entered_by,
                             'has_internal_note', new.internal_note is not null, 'agent_visible', jsonb_build_object('amount', new.amount, 'note', new.reason)));
  return new;
end $$;
drop trigger if exists pay_adjustments_event on public.pay_adjustments;
create trigger pay_adjustments_event after insert on public.pay_adjustments
  for each row execute function public.log_pay_adjustment();
revoke execute on function public.log_pay_adjustment(), public.pay_adjustment_open_payday() from public, anon, authenticated;

-- ---------- agent view of their OWN adjustments (rev 2) ----------
-- Agents can't read pay_adjustments (admin-only RLS). This security-definer function returns only the caller's rows
-- (rev 3: by the stable link pay_adjustments.agent_id = the caller's agents.id, resolved server-side at insert), only amount + note
-- (never internal_note, never who entered it), and only once the payday's spiff cutoff is recorded as Kyle's submit
-- (PB §1.8 visibility gate: hidden until the cutoff is set).
create or replace function public.my_pay_adjustments()
returns table(payday date, amount numeric, note text, kind text, member_id text)
language sql stable security definer set search_path = public, pg_temp as $$
  select a.payday, a.amount, a.reason, a.kind, a.member_id
    from public.pay_adjustments a
    join public.agents ag on ag.id = a.agent_id and ag.user_id = auth.uid()
   where auth.uid() is not null
     and exists (select 1 from public.payroll_cutoffs c where c.payday = a.payday and c.source = 'submit')
   order by a.payday, a.id
$$;
revoke execute on function public.my_pay_adjustments() from public, anon;
grant execute on function public.my_pay_adjustments() to authenticated;
