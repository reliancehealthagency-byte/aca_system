-- Slice three, part 2 of 3: reconciliation logic (functions + views). Nothing here stores pay: every amount is derived at
-- read time from staging + commission_config + recon_pay_config + agent_pay_rules + premier_addon_map, so a rate change
-- needs no migration. Every view is security_invoker and filtered by is_admin() (pay data is admin only).
--
-- Rules (master-context §5.2 wins over payroll-breakdown.md where they differ):
--  * Match board -> Premier by Member ID (digits only). Attribution = board agent (locked); Premier Agent Label = reference.
--  * Premier's premium is paid (board premium is a claim). Premium = Premier fee columns of products created within
--    product_window_days of Date Booked, so products customer service adds later never raise pay.
--  * Rate = commission_config.base_rate (+ addon_bonus_rate when a qualifying add-on is present), with agent_pay_rules
--    overrides (Kaitlyn 25% flat). ACA wrap = recon_pay_config.aca_wrap_rate. ABS = $ per item, never a percentage.
--  * Commission pays the Friday after the Sun-Sat week of the pay basis date = Premier First Billing Date, else Date Booked;
--    an unbilled post-dated deal projects off Premier's Next Billing Date (never the form's future date).
--  * Spiffs pay current: first payday whose cutoff (Kyle's submit) is at/after both the form timestamp and Date Booked.
--  * Clawbacks (full refund / VOID) are PROPOSED only (-commission, spiffs kept) until a clawback_approved adjustment exists.
--  * Rows the README marks OPEN are not guessed: actual pay is NULL and both readings are shown.

-- Who may read reconciliation data: an admin user, or a server-side role (SQL Editor owner / service_role, which bypass
-- RLS on the tables anyway). anon and ordinary agents get nothing.
create or replace function public.recon_can_read() returns boolean
language sql stable set search_path = public, pg_temp as $$
  select public.is_admin() or current_user in ('postgres', 'service_role', 'supabase_admin')
$$;

create or replace function public.recon_friday_after_week(d date) returns date
language sql immutable as $$ select d - extract(dow from d)::int + 12 $$;

-- Premier fee split for one raw row: (first-month recurring, one-time). Anniversary fees excluded.
create or replace function public.premier_row_fees(raw jsonb, period_label text, out recurring numeric, out one_time numeric)
language sql stable set search_path = public, pg_temp as $$
  with c as (select premier_fee_exclude ex, premier_one_time_fee_cols ot from public.recon_pay_config where id),
  f as (select k, coalesce(public.recon_parse_money(raw ->> k), 0) amt
          from jsonb_object_keys(raw) k, c where k like '% Fee' and not (k = any (c.ex)))
  select coalesce(sum(amt) filter (where not (k = any (c.ot)) and not (k = 'Product Fee' and coalesce(period_label, '') ~* 'one.?time')), 0),
         coalesce(sum(amt) filter (where k = any (c.ot) or (k = 'Product Fee' and coalesce(period_label, '') ~* 'one.?time')), 0)
    from f, c
$$;

-- Add-on for one Premier product (label, then tier from benefit), from the Payroll-owned map. Case-insensitive.
-- include_proposed = also use rows still awaiting Kyle's OK (only to show the second reading of an OPEN item).
create or replace function public.premier_product_addon(label text, benefit text, include_proposed boolean default false,
  out addon_key text, out tier text, out qualifies boolean)
language sql stable set search_path = public, pg_temp as $$
  select m.addon_key,
         case when m.addon_key = 'consultcare' then
           (select b.tier from public.premier_addon_map b where b.active and b.source = 'premier_benefit'
              and (b.status = 'approved' or include_proposed)
              and coalesce(benefit, '') ~* b.pattern order by b.id limit 1) end,
         m.qualifies_bonus
    from public.premier_addon_map m
   where m.active and m.source = 'premier_label' and (m.status = 'approved' or include_proposed)
     and coalesce(label, '') ~* m.pattern
   order by case m.addon_key when 'consultcare' then 1 when 'wellness' then 2 when 'add_type' then 3 else 4 end, m.id
   limit 1
$$;

-- Board AO answer -> add-ons (an answer can name several; "None" maps to nothing).
create or replace function public.board_answer_addons(answer text)
returns table(addon_key text, tier text, qualifies boolean)
language sql stable set search_path = public, pg_temp as $$
  select distinct m.addon_key, m.tier, m.qualifies_bonus from public.premier_addon_map m
   where m.active and m.status = 'approved' and m.source = 'board_answer' and coalesce(answer, '') ~* m.pattern
$$;

-- ABS items (hub v19.13 absMixItems_): exact multiple of the first price; else the fewest second-price items plus a whole
-- number of first-price items; else round(amount / first price) and flag. <= 0 pays nothing and flags.
create or replace function public.abs_item_count(amount numeric, out items int, out flagged boolean)
language plpgsql stable set search_path = public, pg_temp as $$
declare p1 numeric; p2 numeric; b int; rem numeric; k numeric;
begin
  select abs_item_prices[1], coalesce(abs_item_prices[2], abs_item_prices[1]) into p1, p2 from public.recon_pay_config where id;
  if amount is null or amount <= 0 then items := 0; flagged := true; return; end if;
  k := round(amount / p1);
  if k >= 1 and abs(amount - k * p1) <= 0.01 then items := k; flagged := false; return; end if;
  for b in 1 .. ceil(amount / p2)::int loop
    rem := amount - b * p2;
    exit when rem < -0.01;
    k := round(greatest(rem, 0) / p1);
    if abs(rem - k * p1) <= 0.01 then items := b + k; flagged := false; return; end if;
  end loop;
  items := greatest(1, round(amount / p1)::int); flagged := true;
end $$;

-- Spiff payday: first payday whose cutoff (Kyle's submit) is at/after the form timestamp AND Date Booked; else the
-- provisional Friday after the Thursday on/after that day (skipping a payday whose recorded cutoff already passed).
create or replace function public.recon_spiff_payday(submitted timestamptz, booked date) returns date
language sql stable set search_path = public, pg_temp as $$
  with x as (select greatest(coalesce(submitted, booked::timestamp at time zone 'America/New_York'),
                             coalesce(booked, (submitted at time zone 'America/New_York')::date)::timestamp at time zone 'America/New_York') t),
  hit as (select min(c.payday) p from public.payroll_cutoffs c, x where c.cutoff_at >= x.t),
  f0 as (select ((x.t at time zone 'America/New_York')::date
                 + ((4 - extract(dow from (x.t at time zone 'America/New_York')::date)::int + 7) % 7) + 1) p from x)
  select coalesce((select p from hit),
                  (select case when exists (select 1 from public.payroll_cutoffs c where c.payday = f0.p) then f0.p + 7 else f0.p end from f0))
$$;

-- Latest copy of each Premier product (dedupe member + Product ID + Product Created Date; latest import, last row wins).
create or replace view public.premier_products_current with (security_invoker = true) as
select distinct on (p.member_id, p.product_id, p.product_created_date)
       p.id, p.import_id, p.row_num, p.member_id, p.product_id, p.product_label, p.product_benefit, p.period_label,
       p.agent_label, p.phone_sha256, p.email_sha256, p.member_created_date, p.product_created_date,
       p.active_date, p.first_billing_date, p.next_billing_date, p.inactive_date, p.hold_date, p.hold_reason,
       p.paid, p.last_payment, p.refund_requested, p.refund_provided, p.refund_provided_date,
       f.recurring as recurring_fee, f.one_time as one_time_fee, a.addon_key, a.tier as addon_tier, a.qualifies as addon_qualifies,
       ap.addon_key as addon_key_with_proposed, ap.qualifies as addon_qualifies_with_proposed,
       i.file_name, i.is_mock
  from public.premier_member_products p
  join public.recon_imports i on i.id = p.import_id
  cross join lateral public.premier_row_fees(p.raw, p.period_label) f
  cross join lateral public.premier_product_addon(p.product_label, p.product_benefit) a
  cross join lateral public.premier_product_addon(p.product_label, p.product_benefit, true) ap
 where public.recon_can_read() and p.member_id is not null
 order by p.member_id, p.product_id, p.product_created_date, i.imported_at desc, i.id desc, p.row_num desc;

-- One row per Premier member: paid / refund / void status from ALL current products.
create or replace view public.premier_member_status with (security_invoker = true) as
with a as (
  select member_id, count(*) n_products, bool_or(paid) paid_any, max(last_payment) lp_max,
         bool_and(refund_provided) all_refunded, bool_or(refund_provided) any_refunded,
         bool_or(refund_requested and not refund_provided) refund_pending, max(refund_provided_date) refund_date,
         min(first_billing_date) first_billing_date, min(next_billing_date) next_billing_date, min(active_date) active_min,
         bool_or(inactive_date is not null) any_inactive, max(inactive_date) inactive_max,
         string_agg(distinct hold_reason, '; ') hold_reasons, max(agent_label) agent_label,
         min(member_created_date) member_created_date, max(phone_sha256) phone_sha256, max(email_sha256) email_sha256,
         bool_or(is_mock) is_mock
    from public.premier_products_current group by member_id)
select a.*,
       v.void,
       case when a.all_refunded then 'refunded'
            when v.void then 'void'
            when a.paid_any and a.lp_max >= 1 then case when a.any_inactive then 'confirmed_inactive' else 'confirmed' end
            when a.paid_any then 'failed_payment'
            when a.any_inactive then 'never_paid'
            else 'awaiting_first_payment' end as paid_status
  from a
  cross join lateral (select coalesce(a.paid_any and a.lp_max = 0 and not a.any_refunded and bool_and(p.inactive_date is not null and p.inactive_date <= a.active_min), false) void
                        from public.premier_products_current p
                       where p.member_id = a.member_id and p.recurring_fee + p.one_time_fee > 0) v;

-- Current (PAY) version of each board submission.
--  * Identity = Timestamp (submission_key). Only FINALIZED exports count; finalizing refuses stale / reverting exports.
--  * OPEN week (Kyle 10/31 relayed via Orchestrator): the newest export is the truth: the latest finalized version is paid.
--    A submission missing from the newest export (inside its Timestamp range) is flagged dropped_from_export and KEEPS its
--    last version: removing a row is a manual Kyle correction only, never an automatic unpay.
--  * CLOSED week (its payday submitted, or covered by the hub cutover): the submission is frozen (board_week_freezes) and
--    the frozen version is paid forever. A later change or removal only sets closed_week_change. A submission that first
--    appears in an already-closed week is added_to_closed_week: flagged, held for Kyle, never paid automatically.
--  changed_from_previous = the newest version differs from the one before it (drives 'board_submission_revised').
create or replace view public.board_submissions_current with (security_invoker = true) as
with fin as (
  select i.id, i.is_mock, i.imported_at, i.finalized_at, i.min_submitted_at, i.max_submitted_at
    from public.recon_imports i where i.kind = 'sales_board' and i.finalized_at is not null),
latest as (select * from fin order by finalized_at desc, id desc limit 1),
v as (
  select bs.id, bs.submission_key, bs.import_id, bs.raw_fields, bs.submitted_at,
         row_number() over (partition by bs.submission_key order by f.finalized_at desc, f.id desc) as rn,
         lag(bs.raw_fields) over (partition by bs.submission_key order by f.finalized_at, f.id) as prev_raw_fields,
         count(*) over (partition by bs.submission_key) as versions
    from public.board_submissions bs join fin f on f.id = bs.import_id),
pick as (
  select v.submission_key, v.versions, v.prev_raw_fields, v.id as newest_id, v.raw_fields as newest_raw,
         coalesce(v.import_id <> l.id and v.submitted_at between l.min_submitted_at and l.max_submitted_at, false) as dropped,
         fz.board_id as frozen_id, fz.reason as frozen_reason,
         public.recon_friday_after_week((v.submitted_at at time zone 'America/New_York')::date) as week_payday,
         l.id as latest_import_id
    from v left join latest l on true
    left join public.board_week_freezes fz on fz.submission_key = v.submission_key
   where v.rn = 1)
select bs.*, i.is_mock, i.imported_at, i.finalized_at, p.versions, p.prev_raw_fields,
       p.week_payday, p.frozen_id is not null as frozen, p.frozen_reason,
       p.prev_raw_fields is not null and p.prev_raw_fields is distinct from p.newest_raw as changed_from_previous,
       p.dropped as dropped_from_export,
       p.frozen_id is not null and (p.newest_raw is distinct from bs.raw_fields or p.dropped) as closed_week_change,
       -- added_to_closed_week: first seen after its week's payday was submitted by THIS system (after the hub cutover).
       -- Before the hub file is imported every submitted week is cutover_pending_kyle anyway; weeks the hub paid pay 0.
       p.frozen_id is null
         and p.week_payday > coalesce((select h.last_hub_payday from public.hub_cutover h), date '9999-12-31')
         and exists (select 1 from public.payroll_cutoffs c where c.payday = p.week_payday and c.source = 'submit')
         as added_to_closed_week,
       p.newest_id, p.latest_import_id
  from pick p
  join public.board_submissions bs on bs.id = coalesce(p.frozen_id, p.newest_id)
  join public.recon_imports i on i.id = bs.import_id
 where public.recon_can_read();

-- Week-to-week diff of the stored export snapshots: what each finalized export added, changed or removed vs the one
-- before it (removed = missing inside the newer export's Timestamp range).
create or replace view public.board_export_diffs with (security_invoker = true) as
with fin as (
  select i.id, i.file_name, i.finalized_at, i.min_submitted_at, i.max_submitted_at,
         lag(i.id) over (order by i.finalized_at, i.id) prev_id
    from public.recon_imports i where i.kind = 'sales_board' and i.finalized_at is not null)
select f.id as import_id, f.file_name, f.prev_id as previous_import_id, x.submission_key, x.change
  from fin f
  cross join lateral (
    select n.submission_key, case when o.id is null then 'added' else 'changed' end change
      from public.board_submissions n left join public.board_submissions o on o.import_id = f.prev_id and o.submission_key = n.submission_key
     where n.import_id = f.id and (o.id is null or o.raw_fields is distinct from n.raw_fields)
    union all
    select o.submission_key, 'removed'
      from public.board_submissions o
     where o.import_id = f.prev_id and o.submitted_at between f.min_submitted_at and f.max_submitted_at
       and not exists (select 1 from public.board_submissions n where n.import_id = f.id and n.submission_key = o.submission_key)) x
 where f.prev_id is not null and public.recon_can_read();

-- Every board pay line (P = Premier policy, PADD = ACA wrap, ACA = $30 flat, ABS = $/item), reconciled to Premier.
-- Kyle 10/31 add-on rulings (recorded by Payroll in payroll-breakdown.md, header update 5:10 PM): Premier products win over
-- the board AO for both the +5% and spiffs; missed spiffs pay; board-only claims pay $0; only products created on or before
-- the add-on cutoff (Date Booked, or the post date for a post-dated deal) count; nothing created later rolls down.
create or replace view public.premier_recon_lines with (security_invoker = true) as
with cfg as (select * from public.recon_pay_config where id),
rt as (select * from public.commission_rates()),
last_submit as (select max(payday) payday from public.payroll_cutoffs where source = 'submit'),
b as (select * from public.board_submissions_current),
bl as (
  select b.id board_id, b.row_num, b.submission_key, v.line_type, v.member_id, b.member_id raw_member, v.d, v.claim_premium,
         b.submitted_at, b.agent_name, b.agent_source_col, b.deal_type, b.line_kind, b.board_post_date, b.board_active_date,
         b.increased_answer, b.aca_ffm, b.is_mock, b.dropped_from_export, b.closed_week_change, b.added_to_closed_week, b.agent_id
    from b
    cross join lateral (values
      ('P', b.member_id, b.date_booked, b.board_premium, b.line_kind = 'premier'),
      ('PADD', b.wrap_member_id, coalesce(b.aca_date_booked, (b.submitted_at at time zone 'America/New_York')::date), b.wrap_premium,
         b.line_kind = 'aca' and (public.recon_yes(b.raw ->> 'AF') or b.wrap_member_id is not null)),
      ('ACA', null, coalesce(b.aca_date_booked, (b.submitted_at at time zone 'America/New_York')::date), null::numeric, b.line_kind = 'aca'),
      ('ABS', coalesce(b.abs_member_id, case when b.line_kind = 'premier' then b.member_id end),
         coalesce(b.date_booked, b.aca_date_booked, (b.submitted_at at time zone 'America/New_York')::date), b.abs_premium,
         coalesce(b.abs_addon, false) and (b.line_kind <> 'premier' or b.abs_premium is not null or b.abs_member_id is not null))
    ) v(line_type, member_id, d, claim_premium, applies)
   where v.applies
),
k as (
  select bl.*,
         bl.submission_key || '-' || bl.line_type as line_key,     -- unique: one current version per submission, one line per type
         -- the hub's Line ID (Timestamp-Member-Type), kept so hub "Covers" references (spiff:<id>) can be matched
         bl.submission_key || '-' || coalesce(case when bl.line_type = 'ACA' then bl.aca_ffm else bl.member_id end, 'NOID') || '-' || bl.line_type as hub_line_id,
         dk.dedupe_key,
         -- one paying line per deal (rev 3): P/PADD by Premier member, ABS by ABS member, ACA by FFM. A line that already
         -- has a payroll lock wins, then one not newly added to a closed week, then one still in the newest export, then
         -- the earliest submission.
         case when dk.dedupe_key is not null then
           row_number() over (partition by dk.dedupe_key
                              order by exists (select 1 from public.pay_line_locks pl where pl.line_key = bl.submission_key || '-' || bl.line_type) desc,
                                       bl.added_to_closed_week, bl.dropped_from_export, bl.submitted_at, bl.board_id) end as dup_rank
    from bl
    cross join lateral (select case when bl.line_type in ('P', 'PADD') and bl.member_id is not null then 'M:' || bl.member_id
                                    when bl.line_type = 'ABS' and bl.member_id is not null then 'ABS:' || bl.member_id
                                    when bl.line_type = 'ACA' and bl.aca_ffm is not null then 'FFM:' || bl.aca_ffm end as dedupe_key) dk
),
pl as (  -- P / PADD lines matched to Premier (member-level status + board AO claim)
  select k.*, ms.paid_status, coalesce(ms.n_products, 0) n_products, ms.first_billing_date fbd, ms.next_billing_date nbd,
         coalesce(ms.paid_any, false) paid_any, ms.refund_date, ms.inactive_max, ms.agent_label premier_agent_label,
         ms.refund_pending, ms.hold_reasons,
         ba.*, apr.base_rate_override, apr.addon_bonus_override, coalesce(apr.no_spiff, false) no_spiff
    from k
    left join public.premier_member_status ms on ms.member_id = k.member_id
    cross join lateral (
      select coalesce(array_agg(distinct x.tier) filter (where x.addon_key = 'consultcare' and x.tier is not null), '{}') b_tiers,
             bool_or(x.addon_key = 'wellness') is true b_wellness,
             bool_or(x.addon_key in ('add_type', 'champion')) is true b_add,
             bool_or(x.qualifies) is true b_qual
        from public.board_answer_addons(k.increased_answer) x) ba
    left join public.agent_pay_rules apr on apr.agent_name = k.agent_name
   where k.line_type in ('P', 'PADD')
),
pd as (  -- post-dating + the add-on cutoff date ("original deal")
  select pl.*,
         (pl.fbd is not null and pl.fbd > pl.d + c.post_date_gap_days)
           or (pl.fbd is null and not pl.paid_any and pl.nbd > pl.d + c.post_date_gap_days) premier_post_dated,
         case when c.post_date_source = 'board_active_only' and pl.board_post_date then coalesce(pl.board_active_date, pl.fbd, pl.nbd)
              when c.post_date_source <> 'board_active_only' and pl.fbd is not null and pl.fbd > pl.d + c.post_date_gap_days then pl.fbd
              when c.post_date_source = 'premier_fbd_else_board_active' and pl.board_post_date and pl.fbd is null then coalesce(pl.board_active_date, pl.nbd)
              when c.post_date_source = 'premier_fbd_only' and pl.board_post_date and pl.fbd is null then pl.nbd   -- projected until Premier bills
              else pl.d + c.product_window_days end addon_cutoff,
         case when c.post_date_source = 'board_active_only' and pl.board_post_date then 'board_active_date'
              when c.post_date_source <> 'board_active_only' and pl.fbd is not null and pl.fbd > pl.d + c.post_date_gap_days then 'premier_first_billing'
              when c.post_date_source = 'premier_fbd_else_board_active' and pl.board_post_date and pl.fbd is null then 'board_active_date_provisional'
              when c.post_date_source = 'premier_fbd_only' and pl.board_post_date and pl.fbd is null then 'premier_next_billing_projected'
              else 'date_booked' end
           || case when c.post_date_source_status = 'pending_kyle' and (pl.board_post_date or (pl.fbd is not null and pl.fbd > pl.d + c.post_date_gap_days))
                   then ' (Q11 pending Kyle)' else '' end addon_cutoff_source
    from pl cross join cfg c
),
w as (  -- Premier products on the original deal (created on/before the cutoff; blank created date never counts)
  select pd.*, ww.*
    from pd
    left join lateral (
      select count(*) filter (where orig) n_orig,
             sum(recurring_fee) filter (where orig) prem_recurring,
             sum(one_time_fee) filter (where orig) prem_one_time,
             coalesce(array_agg(addon_tier order by addon_tier) filter (where orig and addon_key = 'consultcare' and addon_tier is not null), '{}') p_tiers,
             count(*) filter (where orig and addon_key = 'wellness') p_wellness,
             bool_or(orig and addon_key in ('add_type', 'champion')) is true p_add,
             bool_or(orig and addon_qualifies) is true p_qual,
             bool_or(orig and addon_qualifies_with_proposed) is true p_qual_prop,
             string_agg(product_label, '; ' order by product_created_date) filter (where not orig and product_created_date is not null and addon_key_with_proposed is not null) late_addons,
             count(*) filter (where product_created_date is null) blank_created
        from (select p.*, (p.product_created_date is not null and p.product_created_date <= pd.addon_cutoff) orig
                from public.premier_products_current p where p.member_id = pd.member_id) p) ww on true
),
pr as (
  select w.*,
         coalesce(w.n_orig, 0) > 0 in_premier,
         coalesce(w.prem_one_time, 0) > 0 and (select one_time_fee_policy from cfg) = 'pending_kyle' premium_open,
         w.prem_recurring + case when (select one_time_fee_policy from cfg) = 'include' then coalesce(w.prem_one_time, 0) else 0 end comm_base,
         coalesce(w.p_qual_prop, false) <> coalesce(w.p_qual, false) mapping_open,
         (w.n_products > 0 and not (array(select distinct unnest(w.p_tiers) order by 1) = array(select unnest(w.b_tiers) order by 1)
                                    and (w.p_wellness > 0) = w.b_wellness and w.p_add = w.b_add)) products_differ,
         w.board_post_date or coalesce(w.premier_post_dated, false) post_dated,
         coalesce(w.base_rate_override, rt.base_rate) base_r, coalesce(w.addon_bonus_override, rt.addon_bonus_rate) bonus_r,
         case when w.paid_status in ('confirmed', 'confirmed_inactive', 'refunded', 'void') then true else false end collected,
         case when w.fbd is not null then w.fbd when (w.board_post_date or w.premier_post_dated) and w.nbd is not null then w.nbd else w.d end pay_basis,
         (select coalesce(sum(case t when 'asset' then c.spiff_cc_asset when 'edge' then c.spiff_cc_edge when 'ultra' then c.spiff_cc_ultra end), 0)
            from unnest(w.p_tiers) t, cfg c) + coalesce(w.p_wellness, 0) * (select spiff_wellness from cfg) spiff_premier_raw,
         (select coalesce(sum(case t when 'asset' then c.spiff_cc_asset when 'edge' then c.spiff_cc_edge when 'ultra' then c.spiff_cc_ultra end), 0)
            from unnest(w.b_tiers) t, cfg c) + case when w.b_wellness then (select spiff_wellness from cfg) else 0 end spiff_board_raw,
         -- the part of Premier's spiffs the board also claimed (the rest is "missed", PB Q12)
         (select coalesce(sum(case t when 'asset' then c.spiff_cc_asset when 'edge' then c.spiff_cc_edge when 'ultra' then c.spiff_cc_ultra end), 0)
            from unnest(w.p_tiers) t, cfg c where t = any (w.b_tiers))
           + case when w.b_wellness and coalesce(w.p_wellness, 0) > 0 then (select spiff_wellness from cfg) else 0 end spiff_claimed_raw
    from w cross join rt
),
pf as (
  select pr.*,
         case when pr.line_type = 'PADD' then (select aca_wrap_rate from cfg)
              else pr.base_r + case when pr.p_qual then pr.bonus_r else 0 end end rate_premier,
         case when pr.line_type = 'PADD' then (select aca_wrap_rate from cfg)
              else pr.base_r + case when pr.p_qual_prop then pr.bonus_r else 0 end end rate_premier_prop,
         case when pr.line_type = 'PADD' then (select aca_wrap_rate from cfg)
              else pr.base_r + case when pr.b_qual then pr.bonus_r else 0 end end rate_board,
         case when pr.no_spiff or pr.post_dated then 0 else pr.spiff_premier_raw end spiff_premier,
         case when pr.no_spiff or pr.post_dated then 0 else least(pr.spiff_claimed_raw, pr.spiff_premier_raw) end spiff_claimed,
         case when pr.no_spiff or pr.board_post_date then 0 else pr.spiff_board_raw end spiff_board
    from pr
),
p_out as (
  select pf.line_key, pf.hub_line_id, pf.submission_key, pf.board_id, pf.row_num, pf.line_type, pf.member_id, pf.agent_name, pf.agent_source_col, pf.d date_booked,
         pf.submitted_at, pf.is_mock, pf.dropped_from_export, pf.closed_week_change, pf.added_to_closed_week, pf.agent_id,
         ma.payday is not null as missed_spiff_anchored,
         case when pf.dup_rank > 1 then 'duplicate_board_row' when not pf.in_premier then 'not_in_premier' else pf.paid_status end line_status,
         pf.paid_status, pf.claim_premium board_premium,
         case when pf.in_premier and not pf.premium_open then pf.comm_base end premier_premium,
         pf.prem_recurring premier_premium_excl_one_time, pf.prem_recurring + coalesce(pf.prem_one_time, 0) premier_premium_incl_one_time,
         pf.premier_agent_label, pf.post_dated, pf.board_post_date, pf.premier_post_dated, pf.fbd premier_first_billing_date,
         pf.addon_cutoff, pf.addon_cutoff_source,
         public.recon_friday_after_week(pf.d) expected_pay_friday,
         public.recon_friday_after_week(pf.pay_basis) commission_pay_friday,
         public.recon_spiff_payday(pf.submitted_at, pf.d) spiff_pay_friday,
         -- missed spiffs (Premier-only, board did not claim): PB Q12, configurable, pending Kyle
         case when pf.in_premier then pf.spiff_premier - pf.spiff_claimed else 0 end missed_spiffs_projected,
         -- next_open_payday: the anchored payday once detected (missed_spiff_anchors), else first payday after the latest submit
         case when (select missed_spiff_payday from cfg) = 'next_open_payday' and ma.payday is not null then ma.payday
              when (select missed_spiff_payday from cfg) = 'next_open_payday'
                   and public.recon_spiff_payday(pf.submitted_at, pf.d) <= coalesce((select payday from last_submit), date '1900-01-05')
              then (select payday from last_submit) + 7
              else public.recon_spiff_payday(pf.submitted_at, pf.d) end missed_spiff_pay_friday_calc,
         -- stage 1: board estimate (board premium + board AO only)
         round(pf.claim_premium * pf.rate_board, 2) expected_commission, pf.spiff_board expected_spiffs,
         -- stage 2: Premier-corrected. Member not in Premier yet: the board claim stays an estimate (Pending PHS), $0 now.
         case when pf.mapping_open then null when pf.in_premier then pf.rate_premier else pf.rate_board end commission_rate,
         case when pf.mapping_open or pf.premium_open or not pf.in_premier then null else round(pf.comm_base * pf.rate_premier, 2) end projected_commission,
         case when not pf.in_premier then pf.spiff_board else pf.spiff_premier end projected_spiffs,
         pf.mapping_open, pf.premium_open, pf.products_differ, pf.collected, pf.in_premier, pf.late_addons, pf.hold_reasons,
         pf.refund_pending, pf.refund_date, pf.inactive_max, pf.blank_created,
         -- the two readings for OPEN rows. A: approved mapping, premium without one-time fees. B: with proposed mapping rows
         -- and one-time fees included.
         round(pf.prem_recurring * pf.rate_premier, 2) + pf.spiff_premier alt_a_total,
         round((pf.prem_recurring + coalesce(pf.prem_one_time, 0)) * pf.rate_premier_prop, 2) + pf.spiff_premier alt_b_total,
         pf.no_spiff, pf.increased_answer board_addon_answer
    from pf
    left join public.missed_spiff_anchors ma on ma.line_key = pf.line_key
),
p_final as (
  select p.*,
         case when p.line_status = 'duplicate_board_row' then 0
              when p.mapping_open or p.premium_open then null
              when p.collected then p.projected_commission else 0 end actual_commission,
         case when p.line_status = 'duplicate_board_row' then 0
              when p.collected then p.projected_spiffs else 0 end actual_spiffs,
         case when p.line_status = 'duplicate_board_row' or not p.collected then 0 else p.missed_spiffs_projected end actual_missed_spiffs
    from p_out p
),
o as (  -- ABS + ACA lines (dropped with a duplicate board row)
  select k.line_key, k.hub_line_id, k.submission_key, k.board_id, k.row_num, k.line_type, k.member_id, k.agent_name, k.agent_source_col, k.d date_booked,
         k.submitted_at, k.is_mock, k.claim_premium, coalesce(apr.no_spiff, false) no_spiff, k.dup_rank, k.dropped_from_export,
         k.closed_week_change, k.added_to_closed_week, k.agent_id,
         case when k.line_type = 'ABS' then (public.abs_item_count(k.claim_premium)).items end abs_items,
         case when k.line_type = 'ABS' then (public.abs_item_count(k.claim_premium)).flagged end abs_flagged
    from k left join public.agent_pay_rules apr on apr.agent_name = k.agent_name
   where k.line_type in ('ABS', 'ACA')
     and not exists (select 1 from k k2 where k2.board_id = k.board_id and k2.line_type in ('P', 'PADD') and k2.dup_rank > 1)
),
o_final as (
  select o.*,
         case when o.dup_rank > 1 then 'duplicate_board_row'
              when o.line_type = 'ACA' then 'board_confirmed'
              when par.line_key is null then 'board_confirmed'
              when par.post_dated then 'parent_post_dated'
              when par.in_premier and not par.collected then 'parent_not_paid'
              else 'board_confirmed' end line_status,
         public.recon_friday_after_week(o.date_booked) expected_pay_friday,
         case when o.line_type = 'ACA' then public.recon_friday_after_week(o.date_booked) end commission_pay_friday,
         case when o.line_type = 'ABS' then public.recon_spiff_payday(o.submitted_at, o.date_booked) end spiff_pay_friday,
         case when o.line_type = 'ACA' then (select aca_flat from cfg) else 0 end expected_commission,
         case when o.line_type = 'ABS' and not o.no_spiff then o.abs_items * (select abs_spiff_per_item from cfg) else 0 end expected_spiffs
    -- parent = the P (Premier deal) or PADD (ACA + wrap) line of the SAME board submission (rev 2: no NOID fallback)
    from o left join p_out par on par.board_id = o.board_id and par.line_type in ('P', 'PADD') and o.line_type = 'ABS'
)
select p.line_key, p.board_id, p.row_num board_row, p.line_type, p.member_id, p.agent_name, p.agent_source_col, p.date_booked,
       p.submitted_at, p.line_status, p.paid_status,
       p.board_premium, p.premier_premium, p.premier_premium_excl_one_time, p.premier_premium_incl_one_time,
       p.premier_premium_excl_one_time - p.board_premium as premium_diff,
       p.premier_agent_label, p.post_dated, p.board_post_date, p.premier_post_dated, p.premier_first_billing_date,
       p.addon_cutoff, p.addon_cutoff_source,
       p.expected_pay_friday, p.commission_pay_friday, p.spiff_pay_friday,
       p.commission_rate,
       p.expected_commission, p.expected_spiffs, p.expected_commission + p.expected_spiffs as expected_total,
       p.projected_commission, p.projected_spiffs,
       p.actual_commission, p.actual_spiffs, p.actual_commission + p.actual_spiffs as actual_total,
       case when p.line_status in ('refunded', 'void') and p.actual_commission is not null then -p.actual_commission end as clawback_proposed,
       case when p.line_status in ('refunded', 'void') then
         greatest(p.commission_pay_friday,
                  coalesce(p.refund_date, p.inactive_max) + ((5 - extract(dow from coalesce(p.refund_date, p.inactive_max))::int + 7) % 7)) end as clawback_pay_friday,
       nullif(concat_ws(',', case when p.mapping_open then 'proposed_addon_mapping' end,
                             case when p.premium_open then 'one_time_fee_in_premium' end), '') as open_item,
       case when p.mapping_open or p.premium_open then p.alt_a_total end as open_alt_a_total,
       case when p.mapping_open or p.premium_open then p.alt_b_total end as open_alt_b_total,
       p.products_differ as board_vs_premier_products_differ, p.board_addon_answer,
       null::int as abs_items, null::boolean as abs_flagged,
       case when p.line_type = 'P' and p.in_premier then
         case when p.premier_premium_excl_one_time < (select half_policy_threshold from cfg) then (select half_policy_value from cfg) else 1 end end
         as premier_policy_count,
       case when p.line_type = 'P' and p.board_premium is not null then
         case when p.board_premium < (select half_policy_threshold from cfg) then (select half_policy_value from cfg) else 1 end end
         as board_policy_count,
       p.late_addons, p.hold_reasons, p.refund_pending, p.blank_created, p.is_mock,
       p.hub_line_id, p.submission_key,
       p.actual_missed_spiffs as missed_spiffs,
       case when p.actual_missed_spiffs <> 0 or p.missed_spiffs_projected <> 0 then p.missed_spiff_pay_friday_calc end as missed_spiff_pay_friday,
       p.dropped_from_export, p.missed_spiff_anchored, p.closed_week_change, p.added_to_closed_week, p.agent_id
  from p_final p
union all
select o.line_key, o.board_id, o.row_num, o.line_type, o.member_id, o.agent_name, o.agent_source_col, o.date_booked,
       o.submitted_at, o.line_status, null,
       o.claim_premium, null, null, null, null,
       null, null, null, null, null,
       null, null,
       o.expected_pay_friday, o.commission_pay_friday, o.spiff_pay_friday,
       null,
       o.expected_commission, o.expected_spiffs, o.expected_commission + o.expected_spiffs,
       case when o.line_status = 'duplicate_board_row' then 0 else o.expected_commission end,
       case when o.line_status = 'board_confirmed' then o.expected_spiffs else 0 end,
       case when o.line_status = 'duplicate_board_row' then 0 else o.expected_commission end,
       case when o.line_status = 'board_confirmed' then o.expected_spiffs else 0 end,
       case when o.line_status = 'duplicate_board_row' then 0 else o.expected_commission end
         + case when o.line_status = 'board_confirmed' then o.expected_spiffs else 0 end,
       null, null, null, null, null, null, null,
       o.abs_items, o.abs_flagged, null, null, null, null, null, null, o.is_mock,
       o.hub_line_id, o.submission_key, 0, null,
       o.dropped_from_export, false, o.closed_week_change, o.added_to_closed_week, o.agent_id
  from o_final o;
comment on view public.premier_recon_lines is
  'Board pay lines reconciled to Premier. One row per (current board submission, line type): line_key = <submission_key>-<type> is unique. expected_* = board estimate (stage 1), projected_*/actual_* = Premier-corrected (stage 2; actual = collected per Premier). actual_spiffs includes missed_spiffs, which pay on missed_spiff_pay_friday (PB Q12). NULL actual + open_item = pending Kyle''s decision (readings in open_alt_a_total / open_alt_b_total). One paying line per deal: duplicates (same Premier member, ABS member or FFM) show duplicate_board_row and pay 0. dropped_from_export = missing from the newest board export (flag only); closed_week_change = a later export changed/dropped a frozen closed-week submission (flag only, pay unchanged); added_to_closed_week = first seen in an already-closed week (held for Kyle).';

-- Board side with no Premier match (or no member ID at all).
create or replace view public.premier_recon_unmatched_board with (security_invoker = true) as
select l.line_key, l.board_id, l.board_row, l.line_type, l.member_id, l.agent_name, l.date_booked, l.board_premium,
       l.expected_total, case when l.member_id is null then 'missing_member_id' else 'not_in_premier' end as reason
  from public.premier_recon_lines l
 where l.line_type in ('P', 'PADD') and l.line_status = 'not_in_premier';

-- Premier side with no board line (member / wrap / ABS id), plus blank-ID rows (data quality, never paid).
create or replace view public.premier_recon_unmatched_premier with (security_invoker = true) as
select ms.member_id, ms.agent_label as premier_agent_label_reference, ms.member_created_date, ms.paid_status,
       ms.n_products,
       (select sum(p.recurring_fee) from public.premier_products_current p where p.member_id = ms.member_id) as premier_premium,
       case when ms.paid_any or ms.lp_max > 0 then 'phs_only_pending_kyle' else 'cancelled_enrollment' end as category,
       0::numeric as pay_now,
       case when ms.paid_any or ms.lp_max > 0 then 'Pending: Kyle picks the agent and approves (Agent Label is only a suggestion)'
            else 'Never billed: counted, not flagged' end as note,
       ms.is_mock
  from public.premier_member_status ms
 where not exists (select 1 from public.board_submissions_current b
                    where ms.member_id in (b.member_id, b.wrap_member_id, b.abs_member_id))
union all
select null, p.agent_label, p.member_created_date, null, 1, f.recurring, 'blank_member_id', 0,
       format('Data quality: Premier row %s of import %s has no Member ID (%s); ignored, $0', p.row_num, p.import_id, p.product_label),
       i.is_mock
  from public.premier_member_products p
  join public.recon_imports i on i.id = p.import_id
  cross join lateral public.premier_row_fees(p.raw, p.period_label) f
 where public.recon_can_read() and p.member_id is null
   and i.id = (select max(i2.id) from public.recon_imports i2 where i2.kind = 'premier_member_products');

create or replace view public.premier_recon_open_items with (security_invoker = true) as
select line_key, member_id, agent_name, line_type, open_item, open_alt_a_total, open_alt_b_total,
       'A = approved add-on mapping, premium without one-time fees; B = with proposed mapping rows and one-time fees' as readings,
       'pending Kyle decision' as status
  from public.premier_recon_lines where open_item is not null;

-- Policy-count validation per agent per Sun-Sat week: typed vs board vs Premier (half policy < threshold = 0.5).
create or replace view public.premier_policy_count_check with (security_invoker = true) as
with l as (
  select agent_name, date_booked - extract(dow from date_booked)::int as week_start,
         sum(board_policy_count) board_count,
         sum(premier_policy_count) filter (where line_status not in ('not_in_premier', 'duplicate_board_row')) premier_count
    from public.premier_recon_lines where line_type = 'P' and line_status <> 'duplicate_board_row' group by 1, 2),
t as (select agent_name, week_start, sum(typed_count) typed_count from public.policy_count_claims where public.recon_can_read() group by 1, 2)
select coalesce(l.agent_name, t.agent_name) agent_name, coalesce(l.week_start, t.week_start) week_start,
       t.typed_count, coalesce(l.board_count, 0) board_count, coalesce(l.premier_count, 0) premier_count,
       t.typed_count is not null and t.typed_count = coalesce(l.board_count, 0) as typed_matches_board,
       coalesce(l.board_count, 0) = coalesce(l.premier_count, 0) as board_matches_premier,
       case when t.typed_count is null then 'no_typed_count'
            when t.typed_count = coalesce(l.board_count, 0) and coalesce(l.board_count, 0) = coalesce(l.premier_count, 0) then 'match'
            else 'mismatch' end as flag
  from l full join t on t.agent_name = l.agent_name and t.week_start = l.week_start;

-- True-up: stage 1 board estimate -> stage 2 Premier-corrected -> stage 3 payroll actual (locks) + adjustments.
-- rev 3: locks are ONE row per (line_key, component) across all paydays (constraint pay_line_locks_once) and are summed per
-- line and component here, whatever payday they were written on, so a component whose due payday moves (a missed spiff,
-- a Premier billing-date change) is still matched to its lock and never paid twice. Components:
--   commission (commission_pay_friday), claimed_spiffs (spiff_pay_friday), missed_spiffs (missed_spiff_pay_friday, anchored).
-- Order per component: locked amount; else OPEN (NULL); else 0; else cutover (rev 3: hub_cutover.last_hub_payday; due on
-- or before it = paid by the hub -> 0; no hub cutover yet and due on a submitted payday -> NULL + cutover_pending_kyle);
-- else held (added_to_closed_week -> NULL, Kyle decides); else the amount. dropped_from_export / closed_week_change are
-- flags only (Kyle 10/31: no automatic unpay; closed weeks never change pay).
-- due_on_submitted_payday_unlocked: a non-zero, unlocked, payable component whose payday after the cutover was already
-- submitted (e.g. a row that came back into the export): it was not in that payroll; Kyle pays it by adjustment or lock.
create or replace view public.premier_recon_trueup with (security_invoker = true) as
with cfg as (select (select h.last_hub_payday from public.hub_cutover h) as cutover_date),
last_submit as (select max(payday) payday from public.payroll_cutoffs where source = 'submit'),
lk as (select line_key,
              sum(amount) filter (where component = 'commission') commission,
              sum(amount) filter (where component = 'claimed_spiffs') claimed,
              sum(amount) filter (where component = 'missed_spiffs') missed,
              bool_or(component = 'commission') has_c, bool_or(component = 'claimed_spiffs') has_s, bool_or(component = 'missed_spiffs') has_m,
              string_agg(distinct agent_name, ', ') agents,
              string_agg(distinct component || '@' || payday::text, ', ') locked_on
         from public.pay_line_locks where public.recon_can_read() group by line_key),
adj as (select line_key, sum(amount) total, string_agg(distinct kind, ',') kinds, bool_or(kind = 'cancel_commission') cancelled
          from public.pay_adjustments where line_key is not null and public.recon_can_read() group by line_key),
c as (
  select l.*, coalesce(l.actual_spiffs, 0) - coalesce(l.missed_spiffs, 0) as claimed_spiffs,
         case when lk.has_c then lk.commission end lc_commission,
         case when lk.has_s then lk.claimed end ls_spiffs,
         case when lk.has_m then lk.missed end lm_missed,
         lk.agents locked_agents, lk.locked_on,
         (select cutover_date from cfg) cutover, (select payday from last_submit) last_submit,
         coalesce(l.added_to_closed_week, false) as held
    from public.premier_recon_lines l
    left join lk on lk.line_key = l.line_key
),
d as (
  select c.*,
         case when lc_commission is not null then lc_commission
              when actual_commission is null then null
              when actual_commission = 0 then 0
              when cutover is not null and commission_pay_friday <= cutover then 0
              when cutover is null and commission_pay_friday <= last_submit then null
              when held then null
              else actual_commission end as pay_commission,
         case when ls_spiffs is not null then ls_spiffs
              when claimed_spiffs = 0 then 0
              when cutover is not null and spiff_pay_friday <= cutover then 0
              when cutover is null and spiff_pay_friday <= last_submit then null
              when held then null
              else claimed_spiffs end as pay_claimed_spiffs,
         case when lm_missed is not null then lm_missed
              when coalesce(missed_spiffs, 0) = 0 then 0
              when cutover is not null and missed_spiff_pay_friday <= cutover then 0
              when cutover is null and missed_spiff_pay_friday <= last_submit then null
              when held then null
              else missed_spiffs end as pay_missed_spiffs,
         case when cutover is null and last_submit is not null and (
                     (lc_commission is null and coalesce(actual_commission, 0) <> 0 and commission_pay_friday <= last_submit)
                  or (ls_spiffs is null and claimed_spiffs <> 0 and spiff_pay_friday <= last_submit)
                  or (lm_missed is null and coalesce(missed_spiffs, 0) <> 0 and missed_spiff_pay_friday <= last_submit))
              then 'cutover_pending_kyle'
              when cutover is not null and (
                     (lc_commission is null and coalesce(actual_commission, 0) <> 0 and commission_pay_friday <= cutover)
                  or (ls_spiffs is null and claimed_spiffs <> 0 and spiff_pay_friday <= cutover)
                  or (lm_missed is null and coalesce(missed_spiffs, 0) <> 0 and missed_spiff_pay_friday <= cutover))
              then 'paid_by_hub' end as cutover_status,
         cutover is not null and last_submit is not null and (
                (lc_commission is null and coalesce(actual_commission, 0) <> 0 and commission_pay_friday > cutover and commission_pay_friday <= last_submit)
             or (ls_spiffs is null and claimed_spiffs <> 0 and spiff_pay_friday > cutover and spiff_pay_friday <= last_submit)
             or (lm_missed is null and coalesce(missed_spiffs, 0) <> 0 and missed_spiff_pay_friday > cutover and missed_spiff_pay_friday <= last_submit))
           as due_on_submitted_payday_unlocked
    from c
)
select d.line_key, d.hub_line_id, d.agent_name, d.line_type, d.member_id, d.line_status,
       d.expected_total as stage1_board_estimate,
       d.actual_total as stage2_premier_corrected,
       coalesce(d.lc_commission, 0) as locked_commission,
       coalesce(d.ls_spiffs, 0) + coalesce(d.lm_missed, 0) as locked_spiffs,
       d.lc_commission is not null as commission_locked,
       d.ls_spiffs is not null or d.lm_missed is not null as spiffs_locked,
       case when d.lc_commission is not null or d.ls_spiffs is not null or d.lm_missed is not null
            then coalesce(d.lc_commission, 0) + coalesce(d.ls_spiffs, 0) + coalesce(d.lm_missed, 0) end as stage3_payroll_actual,
       case when d.lc_commission is not null then d.actual_commission - d.lc_commission end as true_up_commission_due,
       case when d.ls_spiffs is not null or d.lm_missed is not null
            then d.actual_spiffs - coalesce(d.ls_spiffs, 0) - coalesce(d.lm_missed, 0) end as true_up_spiffs_due,
       coalesce(a.total, 0) as adjustments_total, a.kinds as adjustment_kinds,
       coalesce(a.cancelled, false) as commission_cancelled,
       d.locked_agents as locked_agent_names,
       coalesce(d.locked_agents is not null and strpos(d.locked_agents, d.agent_name) = 0, false) as agent_changed_after_lock,
       d.cutover_status,
       d.pay_commission, d.pay_claimed_spiffs, d.pay_missed_spiffs,
       d.pay_commission + d.pay_claimed_spiffs + d.pay_missed_spiffs + coalesce(a.total, 0) as final_payable,
       d.locked_on, d.dropped_from_export, d.closed_week_change, d.added_to_closed_week,
       case when d.held and d.cutover_status is distinct from 'cutover_pending_kyle' then 'held_added_to_closed_week'
            when d.closed_week_change then 'closed_week_change_flag_only'
            when d.dropped_from_export then 'dropped_from_export_flag_only' end as hold_status,
       d.due_on_submitted_payday_unlocked
  from d left join adj a on a.line_key = d.line_key
 where public.recon_can_read();

-- Sales with no Premier member ID (the source of that ID is OPEN with Kyle).
create or replace view public.sales_missing_member_id with (security_invoker = true) as
select s.id, s.agent_of_record, s.sale_date, s.board_premium, s.premier_premium, s.lead_source
  from public.sales s where public.recon_can_read() and s.premier_member_id is null;
