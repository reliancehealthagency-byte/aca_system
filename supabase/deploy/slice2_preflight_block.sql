-- ===== PREFLIGHT (read-only; runs inside the transaction before any change) =====
-- Fresh apply: expenses must be exactly the slice-one seed (Leads x3 + Software x1, 4 rows) and no slice-two table may
-- exist yet; anything else aborts the whole paste. Re-run: if expense_categories exists AND all 3 slice-two versions
-- are recorded in supabase_migrations.schema_migrations, slice two is already applied and the rest is a no-op.
do $$
declare
  n int; leads int; sw int; found text; applied int := 0; has_s2 boolean;
begin
  has_s2 := to_regclass('public.expense_categories') is not null;
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$select count(*) from supabase_migrations.schema_migrations
                where version in ('20261031200000','20261031200100','20261031200200')$q$ into applied;
  end if;
  if has_s2 and applied = 3 then
    raise notice 'preflight: slice two already applied (tables present, 3 versions recorded); re-run is a no-op';
    return;
  end if;
  if has_s2 or applied > 0 then
    raise exception 'preflight failed: partial slice-two state (expense_categories present=%, versions recorded=%/3)', has_s2, applied;
  end if;
  select count(*), count(*) filter (where category = 'Leads'), count(*) filter (where category = 'Software')
    into n, leads, sw from public.expenses;
  select coalesce(string_agg(category || ' x' || c, ', ' order by category), 'none') into found
    from (select category, count(*) c from public.expenses group by category) x;
  if not (n = 4 and leads = 3 and sw = 1) then
    raise exception 'preflight failed: expected expenses = Leads x3 + Software x1 (4 rows); found % rows: %', n, found;
  end if;
  raise notice 'preflight OK: expenses = %', found;
end $$;
