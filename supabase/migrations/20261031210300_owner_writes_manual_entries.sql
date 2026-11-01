-- Slice three, part 4 of 4 (rev 4).
--  A. Kyle 7:14 PM ET 10/31 (relayed via Orchestrator): "Any admin can view all data. Only reliancehealthagency can change
--     those settings." Every pay-config write is owner-only: recon_pay_config.payroll_owner_user_id (Kyle) or postgres in
--     the SQL Editor (audited break-glass); service_role is always refused. Covers commission_config (slice one table:
--     its write policy and a guard trigger are changed HERE, never in the slice-one files; slice3_rollback restores them),
--     premier_addon_map, agent_pay_rules, agent_name_aliases, recon_pay_config, payroll_cutoffs and manual_entry_sources.
--     Locking (premier_lock_payday) is owner-only too (migration 3). Admins keep full read access; any admin may still
--     insert pay adjustments and manual entries. There is no second owner.
--  B. Kyle 7:15 PM ET 10/31 (relayed via Orchestrator): "Just ship together." Manual entries (formerly 3b): Premier premium,
--     credits, debits, policy counts, transfers (Ringba / Acme), lead spend per source, deposit boxes (Premier Book, Neo Book,
--     O'Neil ACA) and Allstate Earned. One row per entry; any admin inserts; corrections are new reversing / superseding
--     rows (no edits, no deletes); agents see nothing.
--  C. Kyle 7:19 PM + 7:20 PM ET 10/31 (relayed via Orchestrator): the P&L walk (daily / weekly / monthly views below),
--     built alongside slice two's P&L views, which stay unchanged.

-- ---------- A. owner-only writes ----------
-- recon_owner_or_break_glass() is defined in migration 3 (premier_lock_payday uses it too).
create or replace function public.recon_owner_write_guard() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  -- Break-glass = the caller's role is postgres / supabase_admin (the SQL Editor), the same rule payroll_cutoffs_guard and
  -- recon_owner_or_sql_editor use: this trigger is SECURITY INVOKER, so current_user is the caller's role (anon /
  -- authenticated / service_role for every API request), and no SECURITY DEFINER function writes these tables.
  if current_user in ('postgres', 'supabase_admin') then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if public.recon_owner_or_break_glass() is not true then   -- fails closed (rev 4 B1): a NULL owner refuses everyone else
    raise exception '%: pay settings are owner-only (Kyle 10/31 7:14 PM): only the payroll owner or the SQL Editor may % (caller %)',
      tg_table_name, lower(tg_op), coalesce(public.audit_actor_role(), current_user);
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
do $$
declare t text;
begin
  foreach t in array array['commission_config','premier_addon_map','agent_pay_rules','agent_name_aliases',
                           'recon_pay_config','payroll_cutoffs'] loop
    execute format('drop trigger if exists %1$s_owner_write on public.%1$I', t);
    execute format('create trigger %1$s_owner_write before insert or update or delete on public.%1$I
                    for each row execute function public.recon_owner_write_guard()', t);
  end loop;
end $$;
-- The owner check lives in the BEFORE trigger (not in the RLS policies) on purpose: a refused admin gets a clear error
-- instead of a silent 0-row update, and service_role (which bypasses RLS) is refused too. Admins keep their read
-- policies; the existing admin write policies (incl. slice one's commission_config_admin_update) only let the
-- statement reach the trigger.
grant execute on function public.recon_owner_or_break_glass() to authenticated, service_role;

-- ---------- B. manual entries ----------
-- Owner-only config: the allowed sources / box names per kind.
create table if not exists public.manual_entry_sources (
  kind        text not null check (kind in ('transfer', 'lead_spend', 'deposit_box')),
  code        text not null check (code ~ '^[a-z0-9_]+$'),
  label       text not null,
  pl_line     text not null,          -- the P&L memo line it shows on (Allstate Earned is its own line)
  active      boolean not null default true,
  note        text,
  primary key (kind, code)
);
insert into public.manual_entry_sources (kind, code, label, pl_line, note) values
  ('transfer',    'ringba',          'Ringba transfers',     'transfers_ringba',     'Kyle 7:15 PM: Ringba and Acme are separate lines'),
  ('transfer',    'acme',            'Acme transfers',       'transfers_acme',       'Kyle 7:15 PM: Ringba and Acme are separate lines'),
  ('lead_spend',  'keystone_data',   'Keystone Data',        'lead_spend',           'PROVISIONAL list from the board Source values (open question)'),
  ('lead_spend',  'ppc_data',        'PPC Data',             'lead_spend',           'PROVISIONAL list from the board Source values (open question)'),
  ('lead_spend',  'ppc_inbound',     'PPC Inbound',          'lead_spend',           'PROVISIONAL list from the board Source values (open question)'),
  ('deposit_box', 'premier_book',    'Premier Book',         'deposit_premier_book', 'weekly earned line (Kyle 7:19 PM)'),
  ('deposit_box', 'neo_book',        'Neo Book',             'deposit_neo_book',     'weekly earned line; Neo pays monthly, entered in the week the admin picks (Kyle 7:19 PM)'),
  ('deposit_box', 'oneil_aca',       'O''Neil ACA',          'deposit_oneil_aca',    'weekly earned line (Kyle 7:19 PM)'),
  ('deposit_box', 'allstate_earned', 'Allstate Earned',      'allstate_earned',      'weekly earned line, its own line (Kyle 7:15 / 7:19 PM)')
on conflict (kind, code) do nothing;

create table if not exists public.manual_entries (
  id               bigint generated always as identity primary key,
  kind             text not null check (kind in ('premier_premium', 'credit', 'debit', 'policy_count', 'transfer', 'lead_spend', 'deposit_box')),
  source           text,               -- required for transfer / lead_spend / deposit_box (manual_entry_sources), else NULL
  entry_date       date not null,      -- the day, or the first day of the week the entry covers (see period)
  period           text not null default 'week' check (period in ('day', 'week', 'month')),
  amount           numeric(12,2) not null,   -- dollars; for policy_count it is the COUNT (halves allowed)
  agent_name       text,               -- optional (policy counts per agent)
  agent_id         uuid references public.agents(id),
  note             text,
  correction_of    bigint references public.manual_entries(id),
  correction_kind  text check (correction_kind in ('reverse', 'supersede')),
  entered_by       text not null default '',
  entered_by_uid   uuid,
  entered_at       timestamptz not null default now(),
  check ((correction_of is null) = (correction_kind is null))
);
create unique index if not exists manual_entries_one_correction on public.manual_entries (correction_of) where correction_of is not null;
comment on table public.manual_entries is
  'Manual entries (Kyle 7:15 PM ET 10/31): premium, credits, debits, policy counts, transfers, lead spend, deposit boxes. Append-only: a correction is a new row (reverse = negates the original; supersede = replaces it). Any admin inserts; entered_by is set from the login.';

create or replace function public.manual_entry_before_insert() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); rl text := public.audit_actor_role(); o record;
begin
  if rl = 'service_role' or current_user = 'service_role' then
    raise exception 'manual entries: the service_role (admin key) path is refused; a signed-in admin enters them';
  end if;
  if uid is null and rl in ('postgres', 'supabase_admin') then
    new.entered_by := 'break-glass:' || rl;
  elsif uid is null or not public.is_admin() then
    raise exception 'only a signed-in admin may record manual entries';
  else
    new.entered_by := coalesce((select a.display_name from public.agents a where a.user_id = uid limit 1), uid::text);
  end if;
  new.entered_by_uid := uid;
  new.entered_at := now();
  new.agent_id := case when new.agent_name is not null then public.recon_agent_id(new.agent_name) end;
  if new.kind in ('transfer', 'lead_spend', 'deposit_box') then
    if not exists (select 1 from public.manual_entry_sources s where s.kind = new.kind and s.code = new.source and s.active) then
      raise exception 'manual entry: % needs a source from manual_entry_sources (got %)', new.kind, coalesce(new.source, 'none');
    end if;
  elsif new.source is not null then
    raise exception 'manual entry: % takes no source', new.kind;
  end if;
  -- Kyle 7:19 PM ET: credits, debits, transfers and lead spend are daily; the four earned lines are weekly.
  if new.kind in ('credit', 'debit', 'transfer', 'lead_spend') and new.period <> 'day' then
    raise exception 'manual entry: % is entered daily (period day), got %', new.kind, new.period;
  end if;
  if new.kind = 'deposit_box' and new.period <> 'week' then
    raise exception 'manual entry: the earned lines are entered weekly (period week, the Sunday of the week), got %', new.period;
  end if;
  if new.period = 'week' and extract(dow from new.entry_date) <> 0 then
    raise exception 'manual entry: a weekly entry_date must be the Sunday that starts the week (got %)', new.entry_date;
  end if;
  if new.correction_of is not null then
    select * into o from public.manual_entries where id = new.correction_of;
    if o.id is null then raise exception 'manual entry: correction_of % not found', new.correction_of; end if;
    if o.correction_kind = 'reverse' then raise exception 'manual entry: a reversing row can''t itself be corrected'; end if;
    if (o.kind, coalesce(o.source, ''), o.entry_date, o.period) is distinct from (new.kind, coalesce(new.source, ''), new.entry_date, new.period) then
      raise exception 'manual entry: a correction must keep kind / source / date / period of entry %', o.id;
    end if;
    if new.correction_kind = 'reverse' and new.amount <> -o.amount then
      raise exception 'manual entry: a reversing row must be exactly -% (entry %)', o.amount, o.id;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists manual_entry_before_insert on public.manual_entries;
create trigger manual_entry_before_insert before insert on public.manual_entries
  for each row execute function public.manual_entry_before_insert();
create or replace function public.manual_entry_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'manual_entries rows are immutable: enter a reversing or superseding row instead';
end $$;
drop trigger if exists manual_entry_immutable on public.manual_entries;
create trigger manual_entry_immutable before update or delete on public.manual_entries
  for each row execute function public.manual_entry_immutable();
drop trigger if exists manual_entry_sources_owner_write on public.manual_entry_sources;
create trigger manual_entry_sources_owner_write before insert or update or delete on public.manual_entry_sources
  for each row execute function public.recon_owner_write_guard();
do $$
declare t text;
begin
  foreach t in array array['manual_entries', 'manual_entry_sources'] loop
    execute format('drop trigger if exists audit_%1$s on public.%1$I', t);
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_row_change()', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, public, authenticated', t);   -- incl. Supabase default grants
  end loop;
end $$;
grant select, insert on public.manual_entries to authenticated;
grant select, insert, update, delete on public.manual_entry_sources to authenticated;
drop policy if exists manual_entries_admin_read on public.manual_entries;
drop policy if exists manual_entries_admin_insert on public.manual_entries;
create policy manual_entries_admin_read on public.manual_entries for select to authenticated using (public.is_admin());
create policy manual_entries_admin_insert on public.manual_entries for insert to authenticated
  with check (auth.uid() is not null and public.is_admin());
drop policy if exists manual_entry_sources_admin_read on public.manual_entry_sources;
drop policy if exists manual_entry_sources_owner_write on public.manual_entry_sources;
create policy manual_entry_sources_admin_read on public.manual_entry_sources for select to authenticated using (public.is_admin());
create policy manual_entry_sources_owner_write on public.manual_entry_sources for all to authenticated
  using (public.is_admin()) with check (public.is_admin());   -- + the owner-only trigger
revoke execute on function public.manual_entry_before_insert(), public.manual_entry_immutable(), public.recon_owner_write_guard()
  from public, anon;

-- Current entries: superseded rows drop out; reversing rows stay (they net the original to 0).
create or replace view public.manual_entries_current with (security_invoker = true) as
select e.*, (e.entry_date - extract(dow from e.entry_date)::int) as week_start,
       date_trunc('month', e.entry_date)::date as month_start,
       case e.kind when 'transfer' then s.pl_line when 'deposit_box' then s.pl_line
                   when 'lead_spend' then 'lead_spend' when 'premier_premium' then 'premier_premium_entered'
                   when 'credit' then 'credits' when 'debit' then 'debits' else 'policy_count' end as pl_line,
       coalesce(s.label, initcap(replace(e.kind, '_', ' '))) as source_label
  from public.manual_entries e
  left join public.manual_entry_sources s on s.kind = e.kind and s.code = e.source
 where public.is_admin()
   and not exists (select 1 from public.manual_entries c where c.correction_of = e.id and c.correction_kind = 'supersede');
comment on view public.manual_entries_current is 'Manual entries net of corrections (superseded rows hidden; reversals kept). Admin only.';

-- One visible P&L line per current manual entry (feeds the walk views below).
create or replace view public.pl_manual_entry_lines with (security_invoker = true) as
select m.entry_date as line_date, m.week_start, m.month_start, 'manual_entry'::text as line_type, m.pl_line as category,
       case m.pl_line when 'premier_premium_entered' then 'Premier premium (entered)' when 'credits' then 'Credits'
            when 'debits' then 'Debits' when 'policy_count' then 'Policy count (entered)'
            when 'transfers_ringba' then 'Transfers: Ringba' when 'transfers_acme' then 'Transfers: Acme'
            when 'lead_spend' then 'Lead spend: ' || m.source_label when 'allstate_earned' then 'Allstate Earned'
            else 'Deposit: ' || m.source_label end as category_label,
       m.note as description, m.source, m.amount, m.period, m.agent_name, m.id as ref_id, m.entered_by
  from public.manual_entries_current m;
comment on view public.pl_manual_entry_lines is
  'Every current manual entry as its own visible P&L line (Kyle 7:15 PM ET 10/31); the walk views sum these. Admin only.';

-- ---------- C. the P&L walk (Kyle 7:19 PM + 7:20 PM ET 10/31, relayed via Orchestrator) ----------
-- Daily:   credit revenue (credits - debits) + transfer revenue (Ringba + Acme) - lead spend - projected commission = net.
-- Projected commission = expected rep pay (Kyle 7:20 PM): deal commission (38% / +5% add-on under agent_pay_rules, the
--   slice-three engine) + spiffs + ABS pay ($20 per item), each its own visible sub-line, dated by Date Booked.
-- Weekly:  the sum of the daily nets + the four weekly earned lines (Allstate Earned, Premier Book, Neo Book, O'Neil ACA)
--          - overhead (Kyle directly 7:24 PM: earned sources affect weekly, never daily; overhead derived from the monthly input).
-- Monthly: the same rolled up: daily nets + earned lines of the weeks whose Sunday falls in the month - full monthly overhead.
-- (Slice two's pl_daily / pl_weekly / pl_monthly showed premium as revenue; they are retired by migration
-- 20261031210400, Kyle direct 7:35 PM.)
-- Per line first (rev 4 B2): the same STATUS rule payroll uses (recon_line_status_pays: no duplicate board rows).
-- Rows added to a closed week are INCLUDED in their booked date / week (Kyle direct 8:03 PM ET: "No sales count to the
-- week it happen, they don't move for payroll"); payroll still doesn't pay them (recon_line_pays). No separate held line.
create or replace view public.pl_projected_rep_pay_lines with (security_invoker = true) as
select l.line_key, l.line_type, l.agent_name, l.line_status,
       coalesce(l.date_booked, (l.submitted_at at time zone 'America/New_York')::date) as day,
       (case when l.line_type <> 'ABS' then coalesce(l.projected_commission, 0) else 0 end)::numeric(12,2) as deal_commission,
       (case when l.line_type <> 'ABS' then coalesce(l.projected_spiffs, 0) else 0 end)::numeric(12,2)     as spiffs,
       (case when l.line_type = 'ABS' then coalesce(l.projected_spiffs, 0) else 0 end)::numeric(12,2)      as abs_pay,
       coalesce(l.added_to_closed_week, false) as added_to_closed_week   -- shown, not excluded (Kyle 8:03 PM)
  from public.premier_recon_lines l
 where public.is_admin() and public.recon_line_status_pays(l.line_status)
   and coalesce(l.date_booked, (l.submitted_at at time zone 'America/New_York')::date) is not null;
comment on view public.pl_projected_rep_pay_lines is
  'Projected rep pay per line (deal commission / spiffs / ABS pay), by Date Booked; status rule shared with payroll (recon_line_status_pays); closed-week added rows count in their booked week. Admin only.';
create or replace view public.pl_projected_rep_pay_daily with (security_invoker = true) as
select day, sum(deal_commission)::numeric(12,2) as deal_commission, sum(spiffs)::numeric(12,2) as spiffs,
       sum(abs_pay)::numeric(12,2) as abs_pay, count(*) as line_count
  from public.pl_projected_rep_pay_lines
 group by 1;
comment on view public.pl_projected_rep_pay_daily is
  'Projected commission = expected rep pay per Date Booked: deal commission (38/43% + agent_pay_rules), spiffs, ABS pay ($20/item). From premier_recon_lines. Admin only.';

create or replace view public.pl_daily_walk with (security_invoker = true) as
with m as (
  select line_date as day,
         sum(amount) filter (where category = 'credits') credits,
         sum(amount) filter (where category = 'debits') debits,
         sum(amount) filter (where category = 'transfers_ringba') transfers_ringba,
         sum(amount) filter (where category = 'transfers_acme') transfers_acme,
         sum(amount) filter (where category = 'lead_spend') lead_spend
    from public.pl_manual_entry_lines where period = 'day' group by 1),
d as (select day from m union select day from public.pl_projected_rep_pay_daily),
w as (
  select d.day,
         coalesce(m.credits, 0) credits, coalesce(m.debits, 0) debits,
         coalesce(m.transfers_ringba, 0) transfers_ringba, coalesce(m.transfers_acme, 0) transfers_acme,
         coalesce(m.lead_spend, 0) lead_spend,
         coalesce(c.deal_commission, 0) deal_commission, coalesce(c.spiffs, 0) spiffs, coalesce(c.abs_pay, 0) abs_pay
    from d left join m using (day) left join public.pl_projected_rep_pay_daily c using (day))
select day, (day - extract(dow from day)::int) as week_start, date_trunc('month', day)::date as month_start,
       credits::numeric(12,2), debits::numeric(12,2), (credits - debits)::numeric(12,2) as credit_revenue,
       transfers_ringba::numeric(12,2), transfers_acme::numeric(12,2),
       (transfers_ringba + transfers_acme)::numeric(12,2) as transfer_revenue,
       lead_spend::numeric(12,2) as total_spend,
       deal_commission::numeric(12,2), spiffs::numeric(12,2), abs_pay::numeric(12,2),
       (deal_commission + spiffs + abs_pay)::numeric(12,2) as projected_commission,
       ((credits - debits) + (transfers_ringba + transfers_acme) - lead_spend - (deal_commission + spiffs + abs_pay))::numeric(12,2) as net
  from w where public.is_admin();
comment on view public.pl_daily_walk is
  'Daily P&L walk (Kyle 7:19/7:20 PM ET 10/31): net = (credits - debits) + transfers - lead spend - projected commission (deal commission + spiffs + ABS pay). Lead spend per source: pl_manual_entry_lines. Admin only.';

-- ---------- D. monthly overhead (Kyle directly, 7:24 PM ET 10/31) ----------
-- "an overhead figure (which is derived from the monthly overhead I will input with source name to the system)".
-- One row per month + free-text source name (rent, software, ...). Same rules as manual_entries: any admin inserts,
-- corrections are reversing / superseding rows, no agent access, audited.
create table if not exists public.overhead_entries (
  id               bigint generated always as identity primary key,
  month            date not null check (extract(day from month) = 1),
  source_name      text not null check (length(btrim(source_name)) > 0),
  amount           numeric(12,2) not null,
  note             text,
  correction_of    bigint references public.overhead_entries(id),
  correction_kind  text check (correction_kind in ('reverse', 'supersede')),
  entered_by       text not null default '',
  entered_by_uid   uuid,
  entered_at       timestamptz not null default now(),
  check ((correction_of is null) = (correction_kind is null))
);
create unique index if not exists overhead_entries_one_correction on public.overhead_entries (correction_of) where correction_of is not null;
comment on table public.overhead_entries is
  'Monthly overhead by source name (Kyle 7:24 PM ET 10/31). Append-only; any admin inserts; weekly share prorated by days (DEFAULT).';
create or replace function public.overhead_entry_before_insert() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); rl text := public.audit_actor_role(); o record;
begin
  if rl = 'service_role' or current_user = 'service_role' then
    raise exception 'overhead entries: the service_role (admin key) path is refused; a signed-in admin enters them';
  end if;
  if uid is null and rl in ('postgres', 'supabase_admin') then
    new.entered_by := 'break-glass:' || rl;
  elsif uid is null or not public.is_admin() then
    raise exception 'only a signed-in admin may record overhead entries';
  else
    new.entered_by := coalesce((select a.display_name from public.agents a where a.user_id = uid limit 1), uid::text);
  end if;
  new.entered_by_uid := uid;
  new.entered_at := now();
  new.source_name := btrim(new.source_name);
  if new.correction_of is not null then
    select * into o from public.overhead_entries where id = new.correction_of;
    if o.id is null then raise exception 'overhead entry: correction_of % not found', new.correction_of; end if;
    if o.correction_kind = 'reverse' then raise exception 'overhead entry: a reversing row can''t itself be corrected'; end if;
    if (o.month, o.source_name) is distinct from (new.month, new.source_name) then
      raise exception 'overhead entry: a correction must keep month and source name of entry %', o.id;
    end if;
    if new.correction_kind = 'reverse' and new.amount <> -o.amount then
      raise exception 'overhead entry: a reversing row must be exactly -% (entry %)', o.amount, o.id;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists overhead_entry_before_insert on public.overhead_entries;
create trigger overhead_entry_before_insert before insert on public.overhead_entries
  for each row execute function public.overhead_entry_before_insert();
drop trigger if exists overhead_entry_immutable on public.overhead_entries;
create trigger overhead_entry_immutable before update or delete on public.overhead_entries
  for each row execute function public.manual_entry_immutable();
drop trigger if exists audit_overhead_entries on public.overhead_entries;
create trigger audit_overhead_entries after insert or update or delete on public.overhead_entries
  for each row execute function public.audit_row_change();
alter table public.overhead_entries enable row level security;
revoke all on public.overhead_entries from anon, public, authenticated;
grant select, insert on public.overhead_entries to authenticated;
drop policy if exists overhead_entries_admin_read on public.overhead_entries;
drop policy if exists overhead_entries_admin_insert on public.overhead_entries;
create policy overhead_entries_admin_read on public.overhead_entries for select to authenticated using (public.is_admin());
create policy overhead_entries_admin_insert on public.overhead_entries for insert to authenticated
  with check (auth.uid() is not null and public.is_admin());
revoke execute on function public.overhead_entry_before_insert() from public, anon;

create or replace view public.pl_overhead_monthly with (security_invoker = true) as
select e.month as month_start, e.source_name, sum(e.amount)::numeric(12,2) as amount, count(*) as entry_count
  from public.overhead_entries e
 where public.is_admin()
   and not exists (select 1 from public.overhead_entries c where c.correction_of = e.id and c.correction_kind = 'supersede')
 group by 1, 2;
comment on view public.pl_overhead_monthly is 'Monthly overhead by source name (current entries: superseded hidden, reversals netted). Admin only.';
-- Weekly share (DEFAULT, not a Kyle ruling): prorate by days, monthly x (days of the week in the month / days in the
-- month), rounded on the running total so the weeks of a month add up to the monthly amount to the cent.
create or replace view public.pl_overhead_weekly with (security_invoker = true) as
with m as (
  select month_start, source_name, amount, (month_start + interval '1 month')::date - month_start as dim
    from public.pl_overhead_monthly),
w as (
  select m.*, ws::date as week_start,
         greatest(ws::date, m.month_start) - m.month_start as d0,
         least(ws::date + 6, (m.month_start + interval '1 month' - interval '1 day')::date) - m.month_start + 1 as d1
    from m cross join generate_series(m.month_start - extract(dow from m.month_start)::int,
                                      (m.month_start + interval '1 month' - interval '1 day')::date, interval '7 days') ws)
select week_start, month_start, source_name, d1 - d0 as days_in_month, dim as days_of_month,
       (round(amount * d1 / dim, 2) - round(amount * d0 / dim, 2))::numeric(12,2) as amount
  from w where public.is_admin();
comment on view public.pl_overhead_weekly is
  'Weekly overhead share per source and month: prorated by days (DEFAULT). A week spanning two months gets a share of each. Admin only.';

create or replace view public.pl_weekly_walk with (security_invoker = true) as
with dd as (
  select week_start, sum(credits) credits, sum(debits) debits, sum(credit_revenue) credit_revenue,
         sum(transfers_ringba) transfers_ringba, sum(transfers_acme) transfers_acme, sum(transfer_revenue) transfer_revenue,
         sum(total_spend) total_spend, sum(deal_commission) deal_commission, sum(spiffs) spiffs, sum(abs_pay) abs_pay,
         sum(projected_commission) projected_commission, sum(net) daily_net
    from public.pl_daily_walk group by 1),
e as (
  select week_start,
         sum(amount) filter (where category = 'allstate_earned') allstate_earned,
         sum(amount) filter (where category = 'deposit_premier_book') premier_book,
         sum(amount) filter (where category = 'deposit_neo_book') neo_book,
         sum(amount) filter (where category = 'deposit_oneil_aca') oneil_aca
    from public.pl_manual_entry_lines where period = 'week' and category in ('allstate_earned', 'deposit_premier_book', 'deposit_neo_book', 'deposit_oneil_aca')
   group by 1),
x as (
  select coalesce(dd.week_start, e.week_start) week_start,
         coalesce(credits, 0) credits, coalesce(debits, 0) debits, coalesce(credit_revenue, 0) credit_revenue,
         coalesce(transfers_ringba, 0) transfers_ringba, coalesce(transfers_acme, 0) transfers_acme,
         coalesce(transfer_revenue, 0) transfer_revenue, coalesce(total_spend, 0) total_spend,
         coalesce(deal_commission, 0) deal_commission, coalesce(spiffs, 0) spiffs, coalesce(abs_pay, 0) abs_pay,
         coalesce(projected_commission, 0) projected_commission, coalesce(daily_net, 0) daily_net,
         coalesce(allstate_earned, 0) allstate_earned, coalesce(premier_book, 0) premier_book,
         coalesce(neo_book, 0) neo_book, coalesce(oneil_aca, 0) oneil_aca
    from dd full join e on e.week_start = dd.week_start),
o as (select week_start, sum(amount) overhead from public.pl_overhead_weekly group by 1),
xo as (select coalesce(x.week_start, o.week_start) week_start, coalesce(credits, 0) credits, coalesce(debits, 0) debits,
              coalesce(credit_revenue, 0) credit_revenue, coalesce(transfers_ringba, 0) transfers_ringba,
              coalesce(transfers_acme, 0) transfers_acme, coalesce(transfer_revenue, 0) transfer_revenue,
              coalesce(total_spend, 0) total_spend, coalesce(deal_commission, 0) deal_commission, coalesce(spiffs, 0) spiffs,
              coalesce(abs_pay, 0) abs_pay, coalesce(projected_commission, 0) projected_commission,
              coalesce(daily_net, 0) daily_net, coalesce(allstate_earned, 0) allstate_earned,
              coalesce(premier_book, 0) premier_book, coalesce(neo_book, 0) neo_book, coalesce(oneil_aca, 0) oneil_aca,
              coalesce(o.overhead, 0) overhead
         from x full join o on o.week_start = x.week_start)
select week_start, week_start + 6 as week_end,
       credits::numeric(12,2), debits::numeric(12,2), credit_revenue::numeric(12,2),
       transfers_ringba::numeric(12,2), transfers_acme::numeric(12,2), transfer_revenue::numeric(12,2),
       total_spend::numeric(12,2), deal_commission::numeric(12,2), spiffs::numeric(12,2), abs_pay::numeric(12,2),
       projected_commission::numeric(12,2), daily_net::numeric(12,2),
       allstate_earned::numeric(12,2), premier_book::numeric(12,2), neo_book::numeric(12,2), oneil_aca::numeric(12,2),
       (allstate_earned + premier_book + neo_book + oneil_aca)::numeric(12,2) as earned_total,
       overhead::numeric(12,2),
       (daily_net + allstate_earned + premier_book + neo_book + oneil_aca - overhead)::numeric(12,2) as net
  from xo where public.is_admin();
comment on view public.pl_weekly_walk is
  'Weekly P&L (Sun-Sat, Kyle 7:24 PM): sum of the daily nets + the four weekly earned lines (Allstate Earned, Premier Book, Neo Book, O''Neil ACA) - overhead (monthly overhead prorated by days, DEFAULT). Admin only.';

create or replace view public.pl_monthly_walk with (security_invoker = true) as
with dd as (
  select month_start, sum(credits) credits, sum(debits) debits, sum(credit_revenue) credit_revenue,
         sum(transfers_ringba) transfers_ringba, sum(transfers_acme) transfers_acme, sum(transfer_revenue) transfer_revenue,
         sum(total_spend) total_spend, sum(deal_commission) deal_commission, sum(spiffs) spiffs, sum(abs_pay) abs_pay,
         sum(projected_commission) projected_commission, sum(net) daily_net
    from public.pl_daily_walk group by 1),
e as (  -- an earned line counts in the month of its week's Sunday (open question in the review)
  select month_start,
         sum(amount) filter (where category = 'allstate_earned') allstate_earned,
         sum(amount) filter (where category = 'deposit_premier_book') premier_book,
         sum(amount) filter (where category = 'deposit_neo_book') neo_book,
         sum(amount) filter (where category = 'deposit_oneil_aca') oneil_aca
    from public.pl_manual_entry_lines where period = 'week' and category in ('allstate_earned', 'deposit_premier_book', 'deposit_neo_book', 'deposit_oneil_aca')
   group by 1),
x as (
  select coalesce(dd.month_start, e.month_start) month_start,
         coalesce(credits, 0) credits, coalesce(debits, 0) debits, coalesce(credit_revenue, 0) credit_revenue,
         coalesce(transfers_ringba, 0) transfers_ringba, coalesce(transfers_acme, 0) transfers_acme,
         coalesce(transfer_revenue, 0) transfer_revenue, coalesce(total_spend, 0) total_spend,
         coalesce(deal_commission, 0) deal_commission, coalesce(spiffs, 0) spiffs, coalesce(abs_pay, 0) abs_pay,
         coalesce(projected_commission, 0) projected_commission, coalesce(daily_net, 0) daily_net,
         coalesce(allstate_earned, 0) allstate_earned, coalesce(premier_book, 0) premier_book,
         coalesce(neo_book, 0) neo_book, coalesce(oneil_aca, 0) oneil_aca
    from dd full join e on e.month_start = dd.month_start),
o as (select month_start, sum(amount) overhead from public.pl_overhead_monthly group by 1),
xo as (select coalesce(x.month_start, o.month_start) month_start, coalesce(credits, 0) credits, coalesce(debits, 0) debits,
              coalesce(credit_revenue, 0) credit_revenue, coalesce(transfers_ringba, 0) transfers_ringba,
              coalesce(transfers_acme, 0) transfers_acme, coalesce(transfer_revenue, 0) transfer_revenue,
              coalesce(total_spend, 0) total_spend, coalesce(deal_commission, 0) deal_commission, coalesce(spiffs, 0) spiffs,
              coalesce(abs_pay, 0) abs_pay, coalesce(projected_commission, 0) projected_commission,
              coalesce(daily_net, 0) daily_net, coalesce(allstate_earned, 0) allstate_earned,
              coalesce(premier_book, 0) premier_book, coalesce(neo_book, 0) neo_book, coalesce(oneil_aca, 0) oneil_aca,
              coalesce(o.overhead, 0) overhead
         from x full join o on o.month_start = x.month_start)
select month_start, (month_start + interval '1 month' - interval '1 day')::date as month_end,
       credits::numeric(12,2), debits::numeric(12,2), credit_revenue::numeric(12,2),
       transfers_ringba::numeric(12,2), transfers_acme::numeric(12,2), transfer_revenue::numeric(12,2),
       total_spend::numeric(12,2), deal_commission::numeric(12,2), spiffs::numeric(12,2), abs_pay::numeric(12,2),
       projected_commission::numeric(12,2), daily_net::numeric(12,2),
       allstate_earned::numeric(12,2), premier_book::numeric(12,2), neo_book::numeric(12,2), oneil_aca::numeric(12,2),
       (allstate_earned + premier_book + neo_book + oneil_aca)::numeric(12,2) as earned_total,
       overhead::numeric(12,2),
       (daily_net + allstate_earned + premier_book + neo_book + oneil_aca - overhead)::numeric(12,2) as net
  from xo where public.is_admin();
comment on view public.pl_monthly_walk is
  'Monthly P&L: sum of the daily nets + earned lines of the weeks whose Sunday is in the month - the full monthly overhead (by source: pl_overhead_monthly). Admin only.';
grant select on public.manual_entries_current, public.pl_manual_entry_lines, public.pl_projected_rep_pay_lines, public.pl_projected_rep_pay_daily,
                public.pl_overhead_monthly, public.pl_overhead_weekly, public.pl_daily_walk, public.pl_weekly_walk, public.pl_monthly_walk to authenticated;
revoke all on public.manual_entries_current, public.pl_manual_entry_lines, public.pl_projected_rep_pay_lines, public.pl_projected_rep_pay_daily,
              public.pl_overhead_monthly, public.pl_overhead_weekly, public.pl_daily_walk, public.pl_weekly_walk, public.pl_monthly_walk from anon;
