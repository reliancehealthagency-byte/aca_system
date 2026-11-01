-- ===== PREFLIGHT (autopay ON; read-only) =====
-- Requires slice 4a applied + recorded and the policy still 'hold'. If 20261101100200 is already recorded and the policy
-- is next_open_payday, the paste is a no-op (the migration's update is guarded to write its event once).
do $$
declare a4 int := 0; on3 int := 0; pol text;
begin
  execute $q$select count(*) from supabase_migrations.schema_migrations where version in ('20261101100000','20261101100100')$q$ into a4;
  execute $q$select count(*) from supabase_migrations.schema_migrations where version = '20261101100200'$q$ into on3;
  if a4 <> 2 then raise exception 'preflight failed: slice 4a (20261101100000 + 100100) must be applied and recorded first (%/2)', a4; end if;
  select closed_week_policy into pol from public.recon_pay_config where id;
  if on3 = 1 and pol = 'next_open_payday' then raise notice 'preflight: autopay already ON; re-run is a no-op'; return; end if;
  if on3 = 1 or pol is distinct from 'hold' then
    raise exception 'preflight failed: unexpected state (100200 recorded=%, policy=%)', on3, pol;
  end if;
  raise notice 'preflight OK: slice 4a recorded, closed_week_policy = hold; switching to next_open_payday';
end $$;
