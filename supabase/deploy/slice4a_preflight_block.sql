-- ===== PREFLIGHT (read-only; runs inside the transaction before any change) =====
-- Fresh apply requires: slice three (5 versions) + Q30 (20261031220000) + PR #7's 20261101120000 (hub Lock Open Items)
-- applied and recorded WITH its objects (hub_lock_open_items, premier_recon_hub_open, the exemption in the true-up / lock),
-- one recon_pay_config row, and NO slice-4a object yet (ledger tables, closed_week_policy column, carry anchors). Anything else aborts the whole paste.
-- Re-run: if ledger_accounts exists AND both slice-4a versions are recorded, slice 4a is already applied: the rest is a no-op
-- (every statement is idempotent; the backfill posts nothing new).
do $$
declare s3 int := 0; q30 int := 0; p7 int := 0; a4 int := 0; has_l boolean; has_c boolean; has_a boolean; cfg int;
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$select count(*) from supabase_migrations.schema_migrations
                where version in ('20261031210000','20261031210100','20261031210200','20261031210300','20261031210400')$q$ into s3;
    execute $q$select count(*) from supabase_migrations.schema_migrations where version = '20261031220000'$q$ into q30;
    execute $q$select count(*) from supabase_migrations.schema_migrations where version = '20261101120000'$q$ into p7;
    execute $q$select count(*) from supabase_migrations.schema_migrations where version in ('20261101130000','20261101130100')$q$ into a4;
  end if;
  has_l := to_regclass('public.ledger_accounts') is not null;
  has_a := to_regclass('public.closed_week_carry_anchors') is not null;
  select count(*) > 0 into has_c from information_schema.columns
   where table_schema = 'public' and table_name = 'recon_pay_config' and column_name = 'closed_week_policy';
  if has_l and has_a and has_c and a4 = 2 then
    raise notice 'preflight: slice 4a already applied (objects present, 2 versions recorded); re-run is a no-op';
    return;
  end if;
  if has_l or has_a or has_c or a4 > 0 or to_regclass('public.ledger_transactions') is not null then
    raise exception 'preflight failed: partial slice-4a state (ledger_accounts=%, carry anchors=%, closed_week_policy=%, versions recorded=%/2)', has_l, has_a, has_c, a4;
  end if;
  if s3 <> 5 or q30 <> 1 or to_regclass('public.recon_imports') is null or to_regclass('public.pl_daily_walk') is null then
    raise exception 'preflight failed: slice three (5 versions) and Q30 (20261031220000) must be applied and recorded first (slice three=%/5, Q30=%/1)', s3, q30;
  end if;
  -- PR #7 lands FIRST (merge order, Orchestrator X-1): recorded AND incorporated, else 4a would overwrite its exemption
  if p7 <> 1 or to_regclass('public.hub_lock_open_items') is null or to_regclass('public.premier_recon_hub_open') is null
     or strpos(pg_get_viewdef('public.premier_recon_trueup'::regclass), 'hub_lock_open_items') = 0
     or strpos(pg_get_functiondef('public.premier_lock_payday(date)'::regprocedure), 'hub_lock_open_items') = 0 then
    raise exception 'preflight failed: PR #7 (20261101120000 hub_lock_open_items) must be applied, recorded and in the true-up / lock first (recorded=%/1, table=%, view=%)',
      p7, to_regclass('public.hub_lock_open_items') is not null, to_regclass('public.premier_recon_hub_open') is not null;
  end if;
  select count(*) into cfg from public.recon_pay_config;
  if cfg <> 1 then raise exception 'preflight failed: recon_pay_config must have exactly one row; found %', cfg; end if;
  if to_regprocedure('public.recon_line_pays(text, boolean)') is null or to_regprocedure('public.premier_lock_payday(date)') is null
     or to_regprocedure('public.payroll_cutoffs_guard()') is null or to_regclass('public.premier_recon_trueup') is null then
    raise exception 'preflight failed: slice-three / #7 objects replaced by 20261101130100 are missing';
  end if;
  raise notice 'preflight OK: slice three (5) + Q30 + #7 (20261101120000) recorded and incorporated, one pay-config row, no slice-4a objects';
end $$;
