-- One append-only audited event log, from day one (Kyle 10/31).

create table public.event_log (
  id              bigint generated always as identity primary key,
  occurred_at     timestamptz not null default clock_timestamp(),
  event_type      text not null,             -- row.insert / row.update / row.delete / premium_mismatch ...
  actor_uid       uuid,                      -- auth.uid() when the change came through Supabase Auth
  actor_role      text,                      -- JWT role (authenticated / service_role) or database session user
  table_name      text not null,
  row_id          text,
  action          text not null,             -- INSERT / UPDATE / DELETE / EVENT
  before          jsonb,
  after           jsonb,
  changed_fields  text[],
  detail          jsonb
);
create index event_log_row_idx on public.event_log(table_name, row_id);
create index event_log_type_idx on public.event_log(event_type, occurred_at);

-- Who is acting: JWT claims when present (PostgREST / Supabase client), else the DB session user.
create or replace function public.audit_actor_uid() returns uuid
language sql stable as $$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                         (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')), '')::uuid
$$;
create or replace function public.audit_actor_role() returns text
language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
                  session_user::text)
$$;

create or replace function public.audit_row_change() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b jsonb; a jsonb; cf text[]; rid text;
begin
  if tg_op in ('UPDATE','DELETE') then b := to_jsonb(old); end if;
  if tg_op in ('INSERT','UPDATE') then a := to_jsonb(new); end if;
  rid := coalesce(a ->> 'id', b ->> 'id');
  if tg_op = 'UPDATE' then
    select array_agg(k order by k) into cf
      from (select jsonb_object_keys(a) k) keys
     where (a -> k) is distinct from (b -> k);
    if cf is null then return new; end if;   -- no-op update: nothing changed, nothing logged
  end if;
  insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, before, after, changed_fields)
  values ('row.' || lower(tg_op), public.audit_actor_uid(), public.audit_actor_role(),
          tg_table_name, rid, tg_op, b, a, cf);
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['agents','contacts','applications','sales','call_metrics','expenses','commission_config'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_row_change()', t);
  end loop;
end $$;

-- Immutability: nobody updates, deletes or truncates the log.
create or replace function public.event_log_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'event_log is append-only: % is not allowed', tg_op;
end $$;
create trigger event_log_no_update before update or delete on public.event_log
  for each row execute function public.event_log_immutable();
create trigger event_log_no_truncate before truncate on public.event_log
  for each statement execute function public.event_log_immutable();

revoke all on public.event_log from public;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated','service_role'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke insert, update, delete, truncate on public.event_log from %I', r);
    end if;
  end loop;
end $$;
