-- ===== PREFLIGHT (read-only; runs inside the transaction before any change) =====
-- Fresh apply requires: slice one + two applied and recorded (7 versions), commission_config = one row 0.38 / 0.05,
-- is_admin() + audit_row_change() present, and NO slice-three object yet (tables or the sales columns). Anything else
-- aborts the whole paste. Re-run: if recon_imports exists AND the 4 slice-three versions are recorded, slice three is
-- already applied and the rest is a no-op (every statement is idempotent; config rows use on conflict do nothing).
do $$
declare applied3 int := 0; prior int := 0; has_s3 boolean; cols int; cc text;
begin
  has_s3 := to_regclass('public.recon_imports') is not null;
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$select count(*) from supabase_migrations.schema_migrations
                where version in ('20261031210000','20261031210100','20261031210200','20261031210300')$q$ into applied3;
    execute $q$select count(*) from supabase_migrations.schema_migrations
                where version in ('20261031190000','20261031190100','20261031190200','20261031190300',
                                  '20261031200000','20261031200100','20261031200200')$q$ into prior;
  end if;
  if has_s3 and applied3 = 4 then
    raise notice 'preflight: slice three already applied (tables present, 4 versions recorded); re-run is a no-op';
    return;
  end if;
  select count(*) into cols from information_schema.columns
   where table_schema = 'public' and table_name = 'sales' and column_name in ('premier_member_id', 'lead_source');
  if has_s3 or applied3 > 0 or cols > 0 then
    raise exception 'preflight failed: partial slice-three state (recon_imports present=%, versions recorded=%/4, sales columns present=%/2)', has_s3, applied3, cols;
  end if;
  if prior <> 7 or to_regclass('public.expense_categories') is null or to_regclass('public.pl_line_items') is null then
    raise exception 'preflight failed: slice one + two must be applied and recorded first (versions recorded=%/7, expense_categories=%, pl_line_items=%)',
      prior, to_regclass('public.expense_categories') is not null, to_regclass('public.pl_line_items') is not null;
  end if;
  if to_regprocedure('public.is_admin()') is null or to_regprocedure('public.audit_row_change()') is null
     or to_regclass('public.event_log') is null or to_regclass('public.sales') is null then
    raise exception 'preflight failed: slice-one security objects missing (is_admin, audit_row_change, event_log, sales)';
  end if;
  select string_agg(format('%s/%s', base_rate, addon_bonus_rate), ',') into cc from public.commission_config;
  if cc is distinct from '0.3800/0.0500' and cc is distinct from '0.38/0.05' then
    raise exception 'preflight failed: commission_config must be one row 0.38 / 0.05; found %', coalesce(cc, 'none');
  end if;
  raise notice 'preflight OK: slice one + two recorded (7), commission_config %, no slice-three objects', cc;
end $$;
