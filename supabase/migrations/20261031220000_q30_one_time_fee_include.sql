-- Q30 RESOLVED (Kyle direct 10/31 9:04 PM ET): "Include one-time fees in the first-month premium agents are paid on."
-- The commission premium = recurring fees + one-time fees (Enrollment / Application / Processing / AWA Lifetime, the
-- columns in recon_pay_config.premier_one_time_fee_cols). Mock S18: 297.00 x 38% = 112.86 (was OPEN: 93.86 / 112.86).
-- Config only: recon_pay_config.one_time_fee_policy 'pending_kyle' -> 'include' (the engine already supports it), plus
-- the column default so a fresh build matches live. Owner-only table: runs as postgres (SQL Editor / migration =
-- break-glass); audited by audit_recon_pay_config (row.update) plus an explicit config-decision event with the reason.
-- Idempotent: changes the row only while it is still 'pending_kyle'; never overrides a value the owner already chose.
alter table public.recon_pay_config alter column one_time_fee_policy set default 'include';
do $$
declare n int;
begin
  update public.recon_pay_config
     set one_time_fee_policy = 'include',
         note = concat_ws(' | ', nullif(note, ''), 'one_time_fee_policy include: Kyle direct 10/31 9:04 PM Q30')
   where id and one_time_fee_policy = 'pending_kyle';
  get diagnostics n = row_count;
  if n > 0 then
    insert into public.event_log (event_type, actor_uid, actor_role, table_name, row_id, action, detail)
    values ('recon.config.decision', public.audit_actor_uid(), public.audit_actor_role(), 'recon_pay_config', 'true', 'EVENT',
            jsonb_build_object('setting', 'one_time_fee_policy', 'from', 'pending_kyle', 'to', 'include',
                               'reason', 'Kyle direct 10/31 9:04 PM Q30',
                               'path', case when public.audit_actor_role() in ('postgres', 'supabase_admin') then 'break-glass:' || public.audit_actor_role() else public.audit_actor_role() end));
  end if;
end $$;
