-- READ-ONLY preflight for the one-time hub cutover (SQL Editor). Writes nothing. Expected before the cutover:
-- ready = true: slice three applied, no hub rows / cutover yet, no payday locked by this system, no submit after the
-- file's last payday. Also shows whether a board export is loaded (recommended BEFORE the cutover, so the hub-paid
-- weeks get frozen) and the backend roster size (agent ids for agent views).
select (select count(*) from public.hub_cutover)                                    as cutover_rows,
       (select count(*) from public.hub_paid_lock)                                  as hub_paid_lock_rows,
       (select count(*) from public.pay_line_locks)                                 as pay_line_locks,
       (select min(payday) from public.pay_line_locks)                              as first_locked_payday,
       (select max(payday) from public.payroll_cutoffs where source = 'submit')     as last_submit_payday,
       (select payroll_owner_user_id is not null from public.recon_pay_config where id) as owner_set,
       (select count(*) from public.board_submissions)                              as board_rows_loaded,
       (select count(*) from public.premier_member_products)                        as premier_rows_loaded,
       (select count(*) from public.agents where role = 'agent')                    as roster_agents,
       (select count(*) from public.agent_name_aliases)                             as roster_aliases,
       (select count(*) from public.hub_cutover) = 0 and (select count(*) from public.hub_paid_lock) = 0
         and (select count(*) from public.pay_line_locks) = 0
         and coalesce((select max(payday) from public.payroll_cutoffs where source = 'submit') <= date '2026-10-30', true) as ready;
