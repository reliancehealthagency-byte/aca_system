-- ===== RECORD WHAT WAS APPLIED (Supabase CLI migration history shape) =====
insert into supabase_migrations.schema_migrations (version, name, statements) values
  ('20261101130000', 'actuals_ledger',                array['-- applied via SQL Editor (slice4a_paste.sql; sha256 in slice4a_review.md)']),
  ('20261101130100', 'closed_week_next_open_payday',  array['-- applied via SQL Editor (slice4a_paste.sql; sha256 in slice4a_review.md)'])
on conflict (version) do nothing;

-- ===== POST-APPLY ASSERTION (inside the transaction: a failure rolls the whole paste back) =====
-- The combined definitions must carry PR #7's open-item exemption + paid-elsewhere markers (its rerun guard must pass) and slice 4a's closed-week carry.
do $$
declare v text := pg_get_viewdef('public.premier_recon_trueup'::regclass);
        f text := pg_get_functiondef('public.premier_lock_payday(date)'::regprocedure);
        h text := pg_get_viewdef('public.premier_recon_hub_open'::regclass);
begin
  if strpos(v, 'hub_lock_open_items') = 0 or strpos(v, 'hub_paid_elsewhere') = 0 or strpos(v, 'closed_week_carry_anchors') = 0
     or strpos(v, 'hub_open_item') = 0 then
    raise exception 'post-apply check failed: premier_recon_trueup lacks the #7 exemption or the 4a carry';
  end if;
  if strpos(f, 'hub_lock_open_items') = 0 or strpos(f, 'hub_paid_elsewhere') = 0 or strpos(f, 'closed_week_carry_anchors') = 0 then
    raise exception 'post-apply check failed: premier_lock_payday lacks the #7 exemption or the 4a carry';
  end if;
  if strpos(h, 'premier_recon_trueup') = 0 then raise exception 'post-apply check failed: premier_recon_hub_open missing'; end if;
  if public.hub_open_items_schema_ok() is not true then
    raise exception 'post-apply check failed: PR #7 rerun guard hub_open_items_schema_ok() is false (locks would be refused)';
  end if;
  if (select count(*) from public.ledger_health where total = 0 and unbalanced = 0 and unposted = 0) <> 1 then
    raise exception 'post-apply check failed: ledger_health not clean after the backfill';
  end if;
  raise notice 'post-apply OK: combined true-up / lock carry the #7 open-item exemption and the 4a closed-week carry; ledger clean';
end $$;
