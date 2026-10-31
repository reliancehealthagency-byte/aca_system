-- ===== RECORD WHAT WAS APPLIED (Supabase CLI migration history shape) =====
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version     text primary key,
  statements  text[],
  name        text
);
revoke all on schema supabase_migrations from anon, authenticated;
revoke all on supabase_migrations.schema_migrations from anon, authenticated;
insert into supabase_migrations.schema_migrations (version, name, statements) values
  ('20261031190000', 'core_schema',          array['-- backfilled: slice one applied 2026-10-31 via SQL Editor (slice1_paste.sql)']),
  ('20261031190100', 'audit_event_log',      array['-- backfilled: slice one applied 2026-10-31 via SQL Editor (slice1_paste.sql)']),
  ('20261031190200', 'commission_pl_views',  array['-- backfilled: slice one applied 2026-10-31 via SQL Editor (slice1_paste.sql)']),
  ('20261031190300', 'rls_security',         array['-- backfilled: slice one applied 2026-10-31 via SQL Editor (slice1_paste.sql)']),
  ('20261031200000', 'pl_line_item_tables',  array['-- applied via SQL Editor (slice2_paste.sql; sha256 in README)']),
  ('20261031200100', 'pl_line_item_views',   array['-- applied via SQL Editor (slice2_paste.sql; sha256 in README)']),
  ('20261031200200', 'pl_line_item_rls',     array['-- applied via SQL Editor (slice2_paste.sql; sha256 in README)'])
on conflict (version) do nothing;
