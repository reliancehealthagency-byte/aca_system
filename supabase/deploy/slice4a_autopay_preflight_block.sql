-- ===== PREFLIGHT (autopay switch; read-only) =====
-- Requires slice 4a applied + recorded (20261101130000 + 130100). The switch file itself is guarded: switching to the
-- policy already in force is a no-op (no event).
do $$
declare a4 int := 0; pol text;
begin
  execute $q$select count(*) from supabase_migrations.schema_migrations where version in ('20261101130000','20261101130100')$q$ into a4;
  if a4 <> 2 then raise exception 'preflight failed: slice 4a (20261101130000 + 130100) must be applied and recorded first (%/2)', a4; end if;
  select closed_week_policy into pol from public.recon_pay_config where id;
  if pol not in ('hold', 'next_open_payday') then raise exception 'preflight failed: unexpected closed_week_policy %', pol; end if;
  raise notice 'preflight OK: slice 4a recorded, closed_week_policy currently %', pol;
end $$;
