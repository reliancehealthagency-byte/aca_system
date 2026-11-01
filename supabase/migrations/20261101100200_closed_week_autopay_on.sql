-- Slice 4a, part 3 of 3: switch closed-week rows to auto-pay on the next open payday (Kyle directive 11/01 11:26 AM ET:
-- "Default from now on: auto-pay on the next open payday", relayed by the Orchestrator; Hub v19.11 L1771-1779).
-- LIVE: changes live payroll behavior (recon_line_pays / premier_lock_payday / premier_recon_trueup). Apply on the live DB
-- only after the Orchestrator's review AND Kyle's direct go-ahead, via the SQL Editor file built by scripts/build_slice4a_sql.sh.
alter table public.recon_pay_config alter column closed_week_policy set default 'next_open_payday';
do $$ declare n int; begin
  update public.recon_pay_config
     set closed_week_policy = 'next_open_payday',
         note = concat_ws(' | ', nullif(note, ''), 'closed_week_policy next_open_payday: Kyle directive 11/01 11:26 AM (Hub L1771-1779)')
   where id and closed_week_policy = 'hold';
  get diagnostics n = row_count;
  if n = 1 then
    insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, detail)
    values ('recon.config.decision', public.audit_actor_uid(), public.audit_actor_role(), 'recon_pay_config', 'true', 'EVENT',
            jsonb_build_object('setting', 'closed_week_policy', 'from', 'hold', 'to', 'next_open_payday',
                               'reason', 'Kyle directive 11/01 11:26 AM: closed-week sales auto-pay on the next open payday (Hub v19.11 L1771-1779)',
                               'path', 'break-glass:' || coalesce(public.audit_actor_role(), current_user)));
  end if;
end $$;
