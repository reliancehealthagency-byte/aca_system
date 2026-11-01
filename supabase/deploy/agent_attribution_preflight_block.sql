-- ===== PREFLIGHT (read-only; inside the transaction before any change) =====
-- Requires slice three (5 versions) recorded and its two replaced functions present. Re-run (20261101090000 recorded and
-- the objects present) = no-op: every statement is idempotent (create or replace / add column if not exists).
do $$
declare s3 int := 0; v int := 0;
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    execute $q$select count(*) from supabase_migrations.schema_migrations
                where version in ('20261031210000','20261031210100','20261031210200','20261031210300','20261031210400')$q$ into s3;
    execute $q$select count(*) from supabase_migrations.schema_migrations where version = '20261101090000'$q$ into v;
  end if;
  if v = 1 and to_regclass('public.board_unknown_agents') is not null then
    raise notice 'preflight: agent attribution (20261101090000) already applied; re-run is a no-op'; return;
  end if;
  if s3 <> 5 or to_regprocedure('public.board_parse_raw()') is null or to_regprocedure('public.recon_agent_id(text)') is null
     or to_regclass('public.agent_name_aliases') is null then
    raise exception 'preflight failed: slice three (5 versions) must be applied and recorded first (found %/5)', s3;
  end if;
  raise notice 'preflight OK: slice three recorded; applying agent attribution';
end $$;
