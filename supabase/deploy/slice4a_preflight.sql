-- Slice 4a PREFLIGHT, standalone and READ-ONLY (selects only). Run in the SQL Editor before slice4a_paste.sql.
-- verdict = PASS            -> safe to run the paste (slice three 5/5 + Q30 recorded, one pay-config row, no slice-4a objects)
--         = ALREADY APPLIED -> slice 4a is in place and recorded; the paste would be a no-op
--         = FAIL            -> do not run the paste; see the columns
-- autopay = state of the separate slice4a_autopay_on.sql (gated on Kyle): NOT APPLICABLE / READY (policy hold) / ON
with m as (
  select count(*) filter (where version in ('20261031210000','20261031210100','20261031210200','20261031210300','20261031210400')) s3,
         count(*) filter (where version = '20261031220000') q30,
         count(*) filter (where version in ('20261101100000','20261101100100')) a4,
         count(*) filter (where version = '20261101100200') on3
    from supabase_migrations.schema_migrations),
o as (
  select to_regclass('public.ledger_accounts') is not null has_l,
         to_regclass('public.closed_week_carry_anchors') is not null has_a,
         exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'recon_pay_config'
                  and column_name = 'closed_week_policy') has_c,
         (select count(*) from public.recon_pay_config) cfg,
         to_regprocedure('public.recon_line_pays(text, boolean)') is not null and to_regprocedure('public.premier_lock_payday(date)') is not null
           and to_regprocedure('public.payroll_cutoffs_guard()') is not null and to_regclass('public.premier_recon_trueup') is not null s3_objs)
select case when has_l and has_a and has_c and a4 = 2 then 'ALREADY APPLIED'
            when not has_l and not has_a and not has_c and a4 = 0 and s3 = 5 and q30 = 1 and cfg = 1 and s3_objs then 'PASS'
            else 'FAIL' end as verdict,
       case when a4 <> 2 then 'NOT APPLICABLE (apply slice4a_paste.sql first)'
            when on3 = 1 then 'ON (20261101100200 recorded)'
            else 'READY (policy hold; needs Kyle''s go-ahead)' end as autopay,
       s3 as slice3_versions, q30 as q30_version, a4 as slice4a_versions, on3 as autopay_version,
       has_l as ledger_present, has_a as carry_anchors_present, has_c as policy_column_present, cfg as pay_config_rows, s3_objs as slice3_objects_ok
  from m, o;
