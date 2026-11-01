-- ===== RECORD WHAT WAS APPLIED (Supabase CLI migration history shape) =====
insert into supabase_migrations.schema_migrations (version, name, statements) values
  ('20261101100000', 'actuals_ledger',                array['-- applied via SQL Editor (slice4a_paste.sql; sha256 in slice4a_review.md)']),
  ('20261101100100', 'closed_week_next_open_payday',  array['-- applied via SQL Editor (slice4a_paste.sql; sha256 in slice4a_review.md)'])
on conflict (version) do nothing;
