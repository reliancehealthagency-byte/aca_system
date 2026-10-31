-- Slice three, part 3 of 3: RLS + grants (admin only), the diff-event logger and the payday lock.

-- ---------- RLS ----------
do $$
declare t text;
begin
  foreach t in array array['recon_pay_config','agent_pay_rules','payroll_cutoffs','recon_imports','premier_member_products',
                           'board_submissions','premier_recon_event_state','premier_addon_map','policy_count_claims',
                           'pay_line_locks','pay_adjustments'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
  end loop;
end $$;
revoke all on public.premier_products_current, public.premier_member_status, public.premier_recon_lines,
              public.premier_recon_unmatched_board, public.premier_recon_unmatched_premier, public.premier_recon_open_items,
              public.premier_policy_count_check, public.premier_recon_trueup, public.sales_missing_member_id
  from public, anon, authenticated;

-- Admin users read everything and write config / imports / adjustments. Staging and locks are insert-only (immutable).
-- premier_recon_event_state has no policy at all: only the security-definer logger touches it.
grant select on public.recon_pay_config, public.agent_pay_rules, public.payroll_cutoffs, public.recon_imports,
                public.premier_member_products, public.board_submissions, public.premier_addon_map, public.policy_count_claims,
                public.pay_line_locks, public.pay_adjustments,
                public.premier_products_current, public.premier_member_status, public.premier_recon_lines,
                public.premier_recon_unmatched_board, public.premier_recon_unmatched_premier, public.premier_recon_open_items,
                public.premier_policy_count_check, public.premier_recon_trueup, public.sales_missing_member_id
  to authenticated;
grant update on public.recon_pay_config to authenticated;
grant insert, update, delete on public.agent_pay_rules, public.payroll_cutoffs, public.premier_addon_map, public.policy_count_claims
  to authenticated;
grant insert on public.recon_imports, public.premier_member_products, public.board_submissions, public.pay_adjustments
  to authenticated;

do $$
declare t text;
begin
  foreach t in array array['recon_pay_config','agent_pay_rules','payroll_cutoffs','recon_imports','premier_member_products',
                           'board_submissions','premier_addon_map','policy_count_claims','pay_line_locks','pay_adjustments'] loop
    execute format('drop policy if exists %1$s_admin on public.%1$I', t);
    execute format('create policy %1$s_admin on public.%1$I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end $$;

-- ---------- diff-event logger ----------
-- Compares the reconciliation with what was last logged (premier_recon_event_state) and writes ONLY changes to event_log:
--   premier.premium_diff, premier.paid_status_diff, premier.pay_week_diff, premier.post_date_diff  (first run: vs the board claim)
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
      values ('premier.premium_diff', uid, rl, 'board_submissions', r.line_key, 'EVENT',
              jsonb_build_object('member_id', r.member_id, 'agent', r.agent_name, 'attribution', 'unchanged',
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
       and (n.phone1 = o.phone1 or n.email = o.email)
       and n.member_created_date between o.member_created_date and o.member_created_date + (select rerun_match_days from public.recon_pay_config where id)
     where o.paid_status = 'refunded' and n.paid_status in ('confirmed', 'confirmed_inactive')
  loop
    if not exists (select 1 from public.premier_recon_event_state where state_key = 'info:' || r.k) then
      insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, detail)
      values (case when r.d->>'kind' = 'addon_mismatch' then 'premier.addon_mismatch' else 'premier.info' end,
              uid, rl, 'board_submissions', r.ref, 'EVENT', r.d);
      insert into public.premier_recon_event_state(state_key, state) values ('info:' || r.k, r.d);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ---------- payday lock (stage 3) ----------
-- Writes the payroll-actual amounts for one payday, once. OPEN rows (actual NULL) are skipped and stay open items.
create or replace function public.premier_lock_payday(p_payday date) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  if not (public.is_admin() or public.audit_actor_role() in ('service_role', 'postgres', 'supabase_admin')) then
    raise exception 'premier_lock_payday: admin only';
  end if;
  if extract(dow from p_payday) <> 5 then raise exception 'payday must be a Friday'; end if;
  insert into public.pay_line_locks(line_key, payday, agent_name, commission, spiffs, board_estimate, premier_corrected, note)
  select l.line_key, p_payday, l.agent_name,
         case when l.commission_pay_friday = p_payday then l.actual_commission else 0 end,
         case when l.spiff_pay_friday = p_payday then l.actual_spiffs else 0 end,
         l.expected_total, l.actual_total, 'locked by premier_lock_payday'
    from public.premier_recon_lines l
   where l.agent_name is not null and l.actual_commission is not null and l.actual_spiffs is not null
     and (l.commission_pay_friday = p_payday or l.spiff_pay_friday = p_payday)
  on conflict (line_key, payday) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public.premier_log_recon_events(), public.premier_lock_payday(date) from public, anon;
grant execute on function public.premier_log_recon_events(), public.premier_lock_payday(date) to authenticated, service_role;
revoke execute on function public.premier_parse_raw(), public.board_parse_raw(), public.recon_staging_immutable(),
                           public.pay_lock_immutable() from public, anon, authenticated;

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

-- payroll.adjustment.recorded: one internal event per manual adjustment (Kyle-only entry; rows are append-only).
create or replace function public.log_pay_adjustment() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
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
