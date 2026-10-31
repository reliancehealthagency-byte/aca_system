-- ===== PREFLIGHT (read-only; runs inside the transaction before any change) =====
-- Fresh apply: expenses must be exactly the 4 slice-one rows (date, amount, description, category) and no slice-two table may
-- exist yet; anything else aborts the whole paste. Re-run: if expense_categories exists AND all 3 slice-two versions
-- are recorded in supabase_migrations.schema_migrations, slice two is already applied and the rest is a no-op.
do $$
declare
  n int; leads int; sw int; found text; applied int := 0; has_s2 boolean;  -- leads = unexpected rows, sw = missing rows
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
  -- Exactly the 4 live rows read on 2026-10-31 (read-only GET): (date, amount, description, category), nothing else.
  select count(*) into n from public.expenses;
  select count(*) into leads from (
      select date, amount, description, category from public.expenses
      except all
      select * from (values (date '2026-10-26', 200.00::numeric, 'FAKE seed: lead spend',   'Leads'),
                            (date '2026-10-29', 175.00::numeric, 'FAKE seed: lead spend',   'Leads'),
                            (date '2026-10-31', 150.00::numeric, 'FAKE seed: lead spend',   'Leads'),
                            (date '2026-10-31',  49.00::numeric, 'FAKE seed: subscription', 'Software')) v) extra;
  select count(*) into sw from (
      select * from (values (date '2026-10-26', 200.00::numeric, 'FAKE seed: lead spend',   'Leads'),
                            (date '2026-10-29', 175.00::numeric, 'FAKE seed: lead spend',   'Leads'),
                            (date '2026-10-31', 150.00::numeric, 'FAKE seed: lead spend',   'Leads'),
                            (date '2026-10-31',  49.00::numeric, 'FAKE seed: subscription', 'Software')) v
      except all
      select date, amount, description, category from public.expenses) missing;
  select coalesce(string_agg(format('%s %s %s %s', date, amount, coalesce(description, 'NULL'), category), '; ' order by date, amount), 'none')
    into found from public.expenses;
  if not (n = 4 and leads = 0 and sw = 0) then
    raise exception 'preflight failed: expenses must be exactly the 4 slice-one rows (2026-10-26 200.00 Leads, 2026-10-29 175.00 Leads, 2026-10-31 150.00 Leads, 2026-10-31 49.00 Software, with their FAKE seed descriptions); found % rows (% unexpected, % missing): %', n, leads, sw, found;
  end if;
  raise notice 'preflight OK: expenses = %', found;
end $$;
