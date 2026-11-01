-- READ-ONLY preflight for the one-time hub cutover (SQL Editor). Writes nothing. Expected before the cutover:
-- ready = true: slice three applied, no hub rows / cutover yet, no payday locked by this system, no submit after the
-- file's last payday. Also shows whether a board export is loaded (recommended BEFORE the cutover, so the hub-paid
-- weeks get frozen) and the backend roster size (agent ids for agent views).
-- Order / rerun guards (Orchestrator 11/01). Raises (writes nothing) when:
--  * slice 4a (20261101100000 / 20261101100100) is already applied but #7's migration 20261101120000 is not: applying #7
--    now would replace 4a's true-up / lock function and drop its closed-week carry (merge order: #7 first, then 4a);
--  * 20261101120000 is in place but premier_recon_trueup / premier_lock_payday lost the open-item exemption (the 10/31
--    views / lock migrations were re-run after it): re-run 20261101120000 first.
do $pre$
declare s4a boolean := to_regclass('public.closed_week_carry_anchors') is not null or to_regclass('public.ledger_accounts') is not null;
        ok boolean;
begin
  if not s4a and to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$select exists (select 1 from supabase_migrations.schema_migrations where version in ('20261101100000', '20261101100100'))$q$ into s4a;
  end if;
  if s4a and to_regclass('public.hub_lock_open_items') is null then
    raise exception 'hub cutover preflight REFUSED: slice 4a (20261101100000 / 20261101100100) is applied before #7 (20261101120000): wrong merge order, applying #7 now would drop 4a''s carry';
  end if;
  if to_regclass('public.hub_lock_open_items') is not null then
    if to_regprocedure('public.hub_open_items_schema_ok()') is null then ok := false;
    else execute 'select public.hub_open_items_schema_ok()' into ok; end if;
    if not ok then
      raise exception 'hub cutover preflight REFUSED: premier_recon_trueup / premier_lock_payday lack the open-item exemption / paid-elsewhere markers (10/31 migrations re-run after 20261101120000): re-run 20261101120000 first';
    end if;
  end if;
end $pre$;

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
