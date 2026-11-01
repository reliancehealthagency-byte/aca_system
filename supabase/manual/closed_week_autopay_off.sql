-- Slice 4a MANUAL switch OFF (audited): closed-week rows go back to 'hold' (slice-three behavior: shown, never paid until
-- Kyle decides). Undoes closed_week_autopay_on.sql. Anchors already written stay (payroll records; a line anchored and
-- locked stays paid); unlocked anchored components stop paying while the policy is 'hold'.
-- LIVE: Kyle's go-ahead only, via the SQL Editor file slice4a_autopay_off.sql. Re-run is a no-op (one event per switch).
alter table public.recon_pay_config alter column closed_week_policy set default 'hold';
do $$ declare n int; begin
  update public.recon_pay_config
     set closed_week_policy = 'hold',
         note = concat_ws(' | ', nullif(note, ''), 'closed_week_policy hold: autopay switched off (' || to_char(now() at time zone 'America/New_York', 'MM/DD HH24:MI') || ' ET)')
   where id and closed_week_policy = 'next_open_payday';
  get diagnostics n = row_count;
  if n = 1 then
    insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, detail)
    values ('recon.config.decision', public.audit_actor_uid(), public.audit_actor_role(), 'recon_pay_config', 'true', 'EVENT',
            jsonb_build_object('setting', 'closed_week_policy', 'from', 'next_open_payday', 'to', 'hold',
                               'reason', 'closed-week autopay switched off (slice4a_autopay_off.sql)',
                               'anchors_kept', (select count(*) from public.closed_week_carry_anchors),
                               'path', 'break-glass:' || coalesce(public.audit_actor_role(), current_user)));
  end if;
end $$;
