-- ===== RECORD WHAT WAS APPLIED (Supabase CLI migration history shape) =====
insert into supabase_migrations.schema_migrations (version, name, statements) values
  ('20261031210000', 'premier_recon_tables',     array['-- applied via SQL Editor (slice3_paste.sql; sha256 in slice3_review.md)']),
  ('20261031210100', 'premier_recon_views',      array['-- applied via SQL Editor (slice3_paste.sql; sha256 in slice3_review.md)']),
  ('20261031210200', 'premier_recon_rls_events', array['-- applied via SQL Editor (slice3_paste.sql; sha256 in slice3_review.md)']),
  ('20261031210300', 'owner_writes_manual_entries', array['-- applied via SQL Editor (slice3_paste.sql; sha256 in slice3_review.md)']),
  ('20261031210400', 'retire_slice2_pl_views',  array['-- applied via SQL Editor (slice3_paste.sql; sha256 in slice3_review.md)'])
on conflict (version) do nothing;
