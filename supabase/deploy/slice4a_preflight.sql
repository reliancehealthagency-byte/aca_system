-- Slice 4a PREFLIGHT, standalone and READ-ONLY (selects only). Run in the SQL Editor before slice4a_paste.sql.
-- verdict = PASS            -> safe to run the paste (slice three 5/5 + Q30 + PR #7 20261101120000 recorded and incorporated,
--                              one pay-config row, no slice-4a objects)
--         = ALREADY APPLIED -> slice 4a is in place and recorded; the paste would be a no-op
--         = FAIL            -> do not run the paste; see the columns
-- autopay = closed_week_policy (switched only by slice4a_autopay_on.sql / _off.sql, gated on Kyle): NOT APPLICABLE / READY (hold) / ON
with m as (
  select count(*) filter (where version in ('20261031210000','20261031210100','20261031210200','20261031210300','20261031210400')) s3,
         count(*) filter (where version = '20261031220000') q30,
         count(*) filter (where version = '20261101120000') p7,
         count(*) filter (where version in ('20261101130000','20261101130100')) a4
    from supabase_migrations.schema_migrations),
o as (
  select to_regclass('public.ledger_accounts') is not null has_l,
         to_regclass('public.closed_week_carry_anchors') is not null has_a,
         exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'recon_pay_config'
                  and column_name = 'closed_week_policy') has_c,
         (select count(*) from public.recon_pay_config) cfg,
         to_regprocedure('public.recon_line_pays(text, boolean)') is not null and to_regprocedure('public.premier_lock_payday(date)') is not null
           and to_regprocedure('public.payroll_cutoffs_guard()') is not null and to_regclass('public.premier_recon_trueup') is not null s3_objs,
         to_regclass('public.hub_lock_open_items') is not null and to_regclass('public.premier_recon_hub_open') is not null
           and to_regclass('public.hub_paid_elsewhere') is not null and to_regprocedure('public.hub_open_items_schema_ok()') is not null
           and strpos(pg_get_viewdef('public.premier_recon_trueup'::regclass), 'hub_paid_elsewhere') > 0
           and strpos(pg_get_viewdef('public.premier_recon_trueup'::regclass), 'hub_lock_open_items') > 0
           and strpos(pg_get_functiondef('public.premier_lock_payday(date)'::regprocedure), 'hub_lock_open_items') > 0 p7_objs,
         (select to_jsonb(c) ->> 'closed_week_policy' from public.recon_pay_config c where c.id) pol)
select case when has_l and has_a and has_c and a4 = 2 then 'ALREADY APPLIED'
            when not has_l and not has_a and not has_c and a4 = 0 and s3 = 5 and q30 = 1 and p7 = 1 and p7_objs and cfg = 1 and s3_objs then 'PASS'
            else 'FAIL' end as verdict,
       case when a4 <> 2 then 'NOT APPLICABLE (apply slice4a_paste.sql first)'
            when pol = 'next_open_payday' then 'ON (closed_week_policy next_open_payday)'
            else 'READY (policy hold; needs Kyle''s go-ahead)' end as autopay,
       s3 as slice3_versions, q30 as q30_version, p7 as pr7_version, p7_objs as pr7_objects_ok, a4 as slice4a_versions,
       has_l as ledger_present, has_a as carry_anchors_present, has_c as policy_column_present, cfg as pay_config_rows, s3_objs as slice3_objects_ok
  from m, o;
