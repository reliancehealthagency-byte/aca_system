-- Slice 4a, part 1 of 3: the ACTUALS LEDGER (Kyle directive 11/01 11:26 AM ET, master-context "Foundation for next slices").
-- An immutable, double-entry ledger of CONFIRMED transactions only. The actual P&L is computed from it and nothing else;
-- projections (the slice-three walk) never post here ("Projections never touch the balanced books").
--
-- Sources posted (each source row posts exactly once; key = (source_kind, source_id)):
--   manual_entry              credits, debits, transfer revenue (Ringba / Acme), lead spend by source, the four earned
--                             deposit lines. premier_premium and policy_count entries are statistics, never money.
--   manual_entry_superseded   a superseding correction posts the new row AND a reversal of the row it replaces
--                             (reversing rows already carry -amount and post as themselves). Ledger net == current entries.
--   overhead_entry(_superseded) monthly overhead by source name, same correction rules.
--   pay_line_lock             finalized payroll per line + component (what payroll paid on a locked payday).
--   pay_adjustment            manual adjustments / true-ups / approved clawbacks on a SUBMITTED payday after the hub cutover
--                             (hub-era adjustments are inside the hub paid totals, never posted twice).
--   hub_paid_lock             pre-cutover paydays: the hub's locked paid total per agent (posted once the cutover exists).
-- Not posted (by design): board estimates, Premier-corrected projections, OPEN / held lines, undecided clawback flags.
-- Sign convention: ledger_lines.amount > 0 = debit, < 0 = credit. Every transaction sums to exactly 0 (deferred check).
-- Cash basis: revenue / costs hit cash on their entry date; payroll hits cash on its payday.

create table if not exists public.ledger_accounts (
  code       text primary key check (code ~ '^[a-z0-9_]+$'),
  name       text not null,
  type       text not null check (type in ('asset', 'liability', 'equity', 'revenue', 'expense')),
  pl_line    text,                 -- the actual-P&L column it feeds (null = balance-sheet only)
  sort       int not null
);
insert into public.ledger_accounts (code, name, type, pl_line, sort) values
  ('cash',                 'Cash (operating)',                        'asset',   null,               100),
  ('rev_premier_credits',  'Premier credits',                         'revenue', 'credits',          400),
  ('rev_premier_debits',   'Premier debits (contra revenue)',         'revenue', 'debits',           401),
  ('rev_transfers_ringba', 'Transfer revenue: Ringba',                'revenue', 'transfers_ringba', 410),
  ('rev_transfers_acme',   'Transfer revenue: Acme',                  'revenue', 'transfers_acme',   411),
  ('rev_allstate_earned',  'Allstate Earned',                         'revenue', 'allstate_earned',  420),
  ('rev_premier_book',     'Premier Book',                            'revenue', 'premier_book',     421),
  ('rev_neo_book',         'Neo Book',                                'revenue', 'neo_book',         422),
  ('rev_oneil_aca',        'O''Neil ACA',                             'revenue', 'oneil_aca',        423),
  ('exp_lead_spend',       'Lead spend',                              'expense', 'lead_spend',       500),
  ('exp_rep_commission',   'Rep pay: deal commission (P / PADD / ACA)', 'expense', 'rep_commission', 510),
  ('exp_rep_spiffs',       'Rep pay: spiffs (claimed + missed)',      'expense', 'rep_spiffs',       511),
  ('exp_rep_abs',          'Rep pay: ABS ($20 per item)',             'expense', 'rep_abs',          512),
  ('exp_rep_adjustments',  'Rep pay: manual adjustments / true-ups',  'expense', 'rep_adjustments',  513),
  ('exp_rep_clawbacks',    'Rep pay: approved clawbacks (negative)',  'expense', 'rep_clawbacks',    514),
  ('exp_rep_hub_paid',     'Rep pay: hub-era paid totals (pre-cutover)', 'expense', 'rep_hub_paid',  515),
  ('exp_overhead',         'Overhead',                                'expense', 'overhead',         600)
on conflict (code) do nothing;
comment on table public.ledger_accounts is 'Chart of accounts for the actuals ledger (slice 4a). Seeded; changes are a migration.';

create table if not exists public.ledger_transactions (
  id             bigint generated always as identity primary key,
  txn_date       date not null,
  source_kind    text not null check (source_kind in ('manual_entry', 'manual_entry_superseded', 'overhead_entry',
                                                       'overhead_entry_superseded', 'pay_line_lock', 'pay_adjustment', 'hub_paid_lock')),
  source_id      bigint not null,
  memo           text not null,
  agent_name     text,
  posted_at      timestamptz not null default now(),
  posted_by_role text not null default coalesce(public.audit_actor_role(), current_user),
  constraint ledger_transactions_once unique (source_kind, source_id)
);
create index if not exists ledger_transactions_date_idx on public.ledger_transactions(txn_date);
create table if not exists public.ledger_lines (
  id          bigint generated always as identity primary key,
  txn_id      bigint not null references public.ledger_transactions(id),
  account     text not null references public.ledger_accounts(code),
  amount      numeric(12,2) not null check (amount <> 0),   -- > 0 debit, < 0 credit
  dimension   text,          -- lead source / overhead source / line_key / agent (drill-down to the source)
  line_type   text           -- P / PADD / ACA / ABS for payroll lines
);
create index if not exists ledger_lines_txn_idx on public.ledger_lines(txn_id);
comment on table public.ledger_transactions is
  'Actuals ledger (slice 4a): one row per posted source row, immutable. Drill-down: (source_kind, source_id) -> the source table row.';
comment on table public.ledger_lines is 'Actuals ledger lines: amount > 0 debit, < 0 credit; each transaction sums to 0. Immutable.';

-- Immutable: no update / delete / truncate for anyone (corrections are new source rows that post their own reversals).
create or replace function public.ledger_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'the actuals ledger is immutable (%): post a correcting source row instead', tg_table_name;
end $$;
do $$ declare t text; begin
  foreach t in array array['ledger_transactions', 'ledger_lines', 'ledger_accounts'] loop
    execute format('drop trigger if exists %I_immutable on public.%I', t, t);
    execute format('create trigger %I_immutable before update or delete on public.%I for each row execute function public.ledger_immutable()', t, t);
    execute format('drop trigger if exists %I_no_truncate on public.%I', t, t);
    execute format('create trigger %I_no_truncate before truncate on public.%I for each statement execute function public.ledger_immutable()', t, t);
  end loop;
end $$;

-- Always balances: checked per transaction at commit (deferred), so a transaction's lines can be inserted one by one.
create or replace function public.ledger_balance_check() returns trigger
language plpgsql as $$
declare s numeric; n int;
begin
  select coalesce(sum(amount), 0), count(*) into s, n from public.ledger_lines where txn_id = new.txn_id;
  if s <> 0 or n < 2 then
    raise exception 'ledger transaction % does not balance (sum %, % lines)', new.txn_id, s, n;
  end if;
  return null;
end $$;
drop trigger if exists ledger_lines_balanced on public.ledger_lines;
create constraint trigger ledger_lines_balanced after insert on public.ledger_lines
  deferrable initially deferred for each row execute function public.ledger_balance_check();

-- ---------- posting ----------
-- One helper posts a two-line transaction (debit / credit pair) unless the source is already posted.
create or replace function public.ledger_post_pair(p_date date, p_kind text, p_id bigint, p_memo text, p_debit text, p_credit text,
                                                   p_amount numeric, p_dimension text, p_agent text, p_line_type text)
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare t bigint;
begin
  if coalesce(p_amount, 0) = 0 then return 0; end if;
  insert into public.ledger_transactions (txn_date, source_kind, source_id, memo, agent_name)
  values (p_date, p_kind, p_id, p_memo, p_agent) on conflict (source_kind, source_id) do nothing returning id into t;
  if t is null then return 0; end if;
  insert into public.ledger_lines (txn_id, account, amount, dimension, line_type) values
    (t, p_debit, p_amount, p_dimension, p_line_type), (t, p_credit, -p_amount, p_dimension, p_line_type);
  return 1;
end $$;

-- Revenue / cost account of a manual entry (null = not money).
create or replace function public.ledger_manual_account(p_kind text, p_source text) returns text
language sql immutable as $$
  select case p_kind
    when 'credit' then 'rev_premier_credits' when 'debit' then 'rev_premier_debits' when 'lead_spend' then 'exp_lead_spend'
    when 'transfer' then case p_source when 'ringba' then 'rev_transfers_ringba' when 'acme' then 'rev_transfers_acme' end
    when 'deposit_box' then case p_source when 'allstate_earned' then 'rev_allstate_earned' when 'premier_book' then 'rev_premier_book'
                                          when 'neo_book' then 'rev_neo_book' when 'oneil_aca' then 'rev_oneil_aca' end
  end
$$;

-- Every confirmed source row not yet posted (drill-down + "nothing left behind" check). Admin / server roles only.
create or replace view public.ledger_pending_sources with (security_invoker = true) as
with cut as (select (select h.last_hub_payday from public.hub_cutover h) as cutover)
select 'manual_entry'::text source_kind, e.id source_id, e.entry_date txn_date, e.amount,
       public.ledger_manual_account(e.kind, e.source) account, coalesce(e.source, e.kind) dimension, e.agent_name, null::text line_type,
       e.kind || coalesce(' ' || e.source, '') || coalesce(' (' || e.correction_kind || ' of #' || e.correction_of || ')', '') memo
  from public.manual_entries e where public.ledger_manual_account(e.kind, e.source) is not null
union all
select 'manual_entry_superseded', o.id, o.entry_date, -o.amount, public.ledger_manual_account(o.kind, o.source), coalesce(o.source, o.kind),
       o.agent_name, null, 'reversal: #' || o.id || ' superseded by #' || c.id
  from public.manual_entries o join public.manual_entries c on c.correction_of = o.id and c.correction_kind = 'supersede'
 where public.ledger_manual_account(o.kind, o.source) is not null
union all
select 'overhead_entry', e.id, e.month, e.amount, 'exp_overhead', e.source_name, null, null,
       'overhead ' || e.source_name || coalesce(' (' || e.correction_kind || ' of #' || e.correction_of || ')', '')
  from public.overhead_entries e
union all
select 'overhead_entry_superseded', o.id, o.month, -o.amount, 'exp_overhead', o.source_name, null, null,
       'reversal: overhead #' || o.id || ' superseded by #' || c.id
  from public.overhead_entries o join public.overhead_entries c on c.correction_of = o.id and c.correction_kind = 'supersede'
union all
select 'pay_line_lock', k.id, k.payday, k.amount,
       case when split_part(k.line_key, '-', 2) = 'ABS' then 'exp_rep_abs'
            when k.component = 'commission' then 'exp_rep_commission' else 'exp_rep_spiffs' end,
       k.line_key, k.agent_name, split_part(k.line_key, '-', 2), 'payroll lock ' || k.component || ' ' || k.line_key
  from public.pay_line_locks k
union all
select 'pay_adjustment', a.id, a.payday, a.amount,
       case when a.kind = 'clawback_approved' then 'exp_rep_clawbacks' else 'exp_rep_adjustments' end,
       coalesce(a.line_key, a.member_id, a.agent_name), a.agent_name, nullif(split_part(coalesce(a.line_key, ''), '-', 2), ''),
       'payroll adjustment ' || a.kind || ': ' || a.reason
  from public.pay_adjustments a, cut
 where cut.cutover is not null and a.payday > cut.cutover
   and exists (select 1 from public.payroll_cutoffs c where c.payday = a.payday and c.source = 'submit')
union all
select 'hub_paid_lock', h.id, h.payday, h.paid_total, 'exp_rep_hub_paid', h.agent_name, h.agent_name, null,
       'hub paid total ' || h.agent_name || ' ' || h.payday
  from public.hub_paid_lock h, cut
 where cut.cutover is not null and h.payday <= cut.cutover;

create or replace view public.ledger_unposted_sources with (security_invoker = true) as
select p.* from public.ledger_pending_sources p
 where p.amount <> 0 and public.recon_can_read()
   and not exists (select 1 from public.ledger_transactions t where t.source_kind = p.source_kind and t.source_id = p.source_id);
comment on view public.ledger_unposted_sources is 'Confirmed source rows not yet in the actuals ledger. Must be empty after every write (triggers post at once).';

-- Internal: post everything pending. Revenue: Dr cash / Cr revenue. Cost or contra revenue: Dr account / Cr cash.
create or replace function public.ledger_post_pending() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int := 0; r record;
begin
  for r in select p.*, a.type from public.ledger_pending_sources p join public.ledger_accounts a on a.code = p.account
            where p.amount <> 0
              and not exists (select 1 from public.ledger_transactions t where t.source_kind = p.source_kind and t.source_id = p.source_id)
            order by p.txn_date, p.source_kind, p.source_id loop
    if r.type = 'revenue' and r.account <> 'rev_premier_debits' then
      n := n + public.ledger_post_pair(r.txn_date, r.source_kind, r.source_id, r.memo, 'cash', r.account, r.amount, r.dimension, r.agent_name, r.line_type);
    else
      n := n + public.ledger_post_pair(r.txn_date, r.source_kind, r.source_id, r.memo, r.account, 'cash', r.amount, r.dimension, r.agent_name, r.line_type);
    end if;
  end loop;
  if n > 0 then
    insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, detail)
    values ('ledger.posted', public.audit_actor_uid(), public.audit_actor_role(), 'ledger_transactions', null, 'EVENT',
            jsonb_build_object('transactions', n));
  end if;
  return n;
end $$;

-- Public entry point (backfill / repair): any admin or the SQL Editor; the service_role key is refused (no key-only writes).
create or replace function public.ledger_sync() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public.audit_actor_role() = 'service_role' or current_user = 'service_role'
     or not (public.is_admin() or session_user in ('postgres', 'supabase_admin') and auth.uid() is null) then
    raise exception 'ledger_sync: a signed-in admin or the SQL Editor only';
  end if;
  return public.ledger_post_pending();
end $$;

-- Triggers: every write to a source posts at once, in the same transaction (so the ledger never lags the books).
create or replace function public.ledger_post_trigger() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.ledger_post_pending();
  return null;
end $$;
do $$ declare t text; begin
  foreach t in array array['manual_entries', 'overhead_entries', 'pay_line_locks', 'pay_adjustments', 'hub_paid_lock', 'hub_cutover', 'payroll_cutoffs'] loop
    execute format('drop trigger if exists ledger_post_%I on public.%I', t, t);
    execute format('create trigger ledger_post_%I after insert or update on public.%I for each statement execute function public.ledger_post_trigger()', t, t);
  end loop;
end $$;

-- ---------- checks ----------
create or replace view public.ledger_trial_balance with (security_invoker = true) as
select a.code account, a.name, a.type, coalesce(sum(l.amount) filter (where l.amount > 0), 0)::numeric(14,2) debits,
       coalesce(-sum(l.amount) filter (where l.amount < 0), 0)::numeric(14,2) credits, coalesce(sum(l.amount), 0)::numeric(14,2) balance
  from public.ledger_accounts a left join public.ledger_lines l on l.account = a.code
 where public.recon_can_read()
 group by a.code, a.name, a.type, a.sort order by a.sort;
create or replace view public.ledger_health with (security_invoker = true) as
select (select count(*) from public.ledger_transactions) transactions,
       (select count(*) from public.ledger_lines) lines,
       (select coalesce(sum(amount), 0) from public.ledger_lines)::numeric(14,2) total,
       (select count(*) from (select txn_id from public.ledger_lines group by txn_id having sum(amount) <> 0 or count(*) < 2) x) unbalanced,
       (select count(*) from public.ledger_transactions t where not exists (select 1 from public.ledger_lines l where l.txn_id = t.id)) empty_transactions,
       (select count(*) from public.ledger_unposted_sources) unposted
 where public.recon_can_read();
comment on view public.ledger_health is 'One row: the ledger always balances (total 0, unbalanced 0, empty 0) and nothing confirmed is unposted.';

-- ---------- the ACTUAL P&L (from the ledger only) ----------
-- Same shape as the projected walk, so the two read side by side. Rep pay = what was actually paid, on its payday.
create or replace view public.pl_actual_lines with (security_invoker = true) as
select t.txn_date as day, (t.txn_date - extract(dow from t.txn_date)::int) as week_start, date_trunc('month', t.txn_date)::date as month_start,
       a.pl_line, a.type, case when a.type = 'revenue' then -l.amount else l.amount end as amount,
       l.dimension, l.line_type, t.agent_name, t.source_kind, t.source_id, t.id as txn_id, t.memo
  from public.ledger_lines l join public.ledger_transactions t on t.id = l.txn_id join public.ledger_accounts a on a.code = l.account
 where a.pl_line is not null and public.recon_can_read();
comment on view public.pl_actual_lines is
  'Every actual-P&L line from the ledger (revenue positive, Premier debits positive as a deduction, costs positive). Drill-down: source_kind / source_id. Admin only.';

create or replace view public.pl_actual_daily with (security_invoker = true) as
with p as (
  select day, sum(amount) filter (where pl_line = 'credits') credits, sum(amount) filter (where pl_line = 'debits') debits_neg,
         sum(amount) filter (where pl_line = 'transfers_ringba') transfers_ringba, sum(amount) filter (where pl_line = 'transfers_acme') transfers_acme,
         sum(amount) filter (where pl_line = 'lead_spend') lead_spend,
         sum(amount) filter (where pl_line = 'rep_commission') rep_commission, sum(amount) filter (where pl_line = 'rep_spiffs') rep_spiffs,
         sum(amount) filter (where pl_line = 'rep_abs') rep_abs, sum(amount) filter (where pl_line = 'rep_adjustments') rep_adjustments,
         sum(amount) filter (where pl_line = 'rep_clawbacks') rep_clawbacks, sum(amount) filter (where pl_line = 'rep_hub_paid') rep_hub_paid
    from public.pl_actual_lines where pl_line not in ('allstate_earned', 'premier_book', 'neo_book', 'oneil_aca', 'overhead') group by day),
w as (select day, coalesce(credits, 0) credits, -coalesce(debits_neg, 0) debits, coalesce(transfers_ringba, 0) transfers_ringba,
             coalesce(transfers_acme, 0) transfers_acme, coalesce(lead_spend, 0) lead_spend, coalesce(rep_commission, 0) rep_commission,
             coalesce(rep_spiffs, 0) rep_spiffs, coalesce(rep_abs, 0) rep_abs, coalesce(rep_adjustments, 0) rep_adjustments,
             coalesce(rep_clawbacks, 0) rep_clawbacks, coalesce(rep_hub_paid, 0) rep_hub_paid from p)
select day, (day - extract(dow from day)::int) as week_start, date_trunc('month', day)::date as month_start,
       credits::numeric(12,2), debits::numeric(12,2), (credits - debits)::numeric(12,2) as credit_revenue,
       transfers_ringba::numeric(12,2), transfers_acme::numeric(12,2), (transfers_ringba + transfers_acme)::numeric(12,2) as transfer_revenue,
       lead_spend::numeric(12,2) as total_spend,
       rep_commission::numeric(12,2), rep_spiffs::numeric(12,2), rep_abs::numeric(12,2), rep_adjustments::numeric(12,2),
       rep_clawbacks::numeric(12,2), rep_hub_paid::numeric(12,2),
       (rep_commission + rep_spiffs + rep_abs + rep_adjustments + rep_clawbacks + rep_hub_paid)::numeric(12,2) as actual_rep_pay,
       ((credits - debits) + (transfers_ringba + transfers_acme) - lead_spend
        - (rep_commission + rep_spiffs + rep_abs + rep_adjustments + rep_clawbacks + rep_hub_paid))::numeric(12,2) as net
  from w where public.recon_can_read();
comment on view public.pl_actual_daily is
  'ACTUAL daily P&L from the ledger: (credits - debits) + transfer revenue - lead spend - rep pay actually paid (on its payday). Admin only.';

-- Overhead: the monthly ledger total, weekly share prorated by days exactly like pl_overhead_weekly (same DEFAULT).
create or replace view public.pl_actual_overhead_weekly with (security_invoker = true) as
with m as (select month_start, dimension source_name, sum(amount) amount, (month_start + interval '1 month')::date - month_start dim
             from public.pl_actual_lines where pl_line = 'overhead' group by 1, 2),
w as (select m.*, ws::date week_start, greatest(ws::date, m.month_start) - m.month_start d0,
             least(ws::date + 6, (m.month_start + interval '1 month' - interval '1 day')::date) - m.month_start + 1 d1
        from m cross join generate_series(m.month_start - extract(dow from m.month_start)::int,
                                          (m.month_start + interval '1 month' - interval '1 day')::date, interval '7 days') ws)
select week_start, month_start, source_name, (round(amount * d1 / dim, 2) - round(amount * d0 / dim, 2))::numeric(12,2) amount
  from w where public.recon_can_read();

create or replace view public.pl_actual_weekly with (security_invoker = true) as
with dd as (select week_start, sum(credits) credits, sum(debits) debits, sum(credit_revenue) credit_revenue, sum(transfer_revenue) transfer_revenue,
                   sum(total_spend) total_spend, sum(actual_rep_pay) actual_rep_pay, sum(net) daily_net from public.pl_actual_daily group by 1),
e as (select week_start, sum(amount) filter (where pl_line = 'allstate_earned') allstate_earned, sum(amount) filter (where pl_line = 'premier_book') premier_book,
             sum(amount) filter (where pl_line = 'neo_book') neo_book, sum(amount) filter (where pl_line = 'oneil_aca') oneil_aca
        from public.pl_actual_lines where pl_line in ('allstate_earned', 'premier_book', 'neo_book', 'oneil_aca') group by 1),
o as (select week_start, sum(amount) overhead from public.pl_actual_overhead_weekly group by 1),
k as (select week_start from dd union select week_start from e union select week_start from o)
select k.week_start, k.week_start + 6 as week_end,
       coalesce(credits, 0)::numeric(12,2) credits, coalesce(debits, 0)::numeric(12,2) debits, coalesce(credit_revenue, 0)::numeric(12,2) credit_revenue,
       coalesce(transfer_revenue, 0)::numeric(12,2) transfer_revenue, coalesce(total_spend, 0)::numeric(12,2) total_spend,
       coalesce(actual_rep_pay, 0)::numeric(12,2) actual_rep_pay, coalesce(daily_net, 0)::numeric(12,2) daily_net,
       coalesce(allstate_earned, 0)::numeric(12,2) allstate_earned, coalesce(premier_book, 0)::numeric(12,2) premier_book,
       coalesce(neo_book, 0)::numeric(12,2) neo_book, coalesce(oneil_aca, 0)::numeric(12,2) oneil_aca,
       (coalesce(allstate_earned, 0) + coalesce(premier_book, 0) + coalesce(neo_book, 0) + coalesce(oneil_aca, 0))::numeric(12,2) earned_total,
       coalesce(overhead, 0)::numeric(12,2) overhead,
       (coalesce(daily_net, 0) + coalesce(allstate_earned, 0) + coalesce(premier_book, 0) + coalesce(neo_book, 0) + coalesce(oneil_aca, 0)
        - coalesce(overhead, 0))::numeric(12,2) net
  from k left join dd using (week_start) left join e using (week_start) left join o using (week_start)
 where public.recon_can_read();
comment on view public.pl_actual_weekly is 'ACTUAL weekly P&L (Sun-Sat) from the ledger: daily nets + earned lines - overhead (prorated by days, DEFAULT). Admin only.';

create or replace view public.pl_actual_monthly with (security_invoker = true) as
with dd as (select month_start, sum(credit_revenue) credit_revenue, sum(transfer_revenue) transfer_revenue, sum(total_spend) total_spend,
                   sum(actual_rep_pay) actual_rep_pay, sum(net) daily_net from public.pl_actual_daily group by 1),
e as (select month_start, sum(amount) earned_total from public.pl_actual_lines
       where pl_line in ('allstate_earned', 'premier_book', 'neo_book', 'oneil_aca') group by 1),   -- month of the entry date (C8)
o as (select month_start, sum(amount) overhead from public.pl_actual_lines where pl_line = 'overhead' group by 1),
k as (select month_start from dd union select month_start from e union select month_start from o)
select k.month_start, (k.month_start + interval '1 month' - interval '1 day')::date month_end,
       coalesce(credit_revenue, 0)::numeric(12,2) credit_revenue, coalesce(transfer_revenue, 0)::numeric(12,2) transfer_revenue,
       coalesce(total_spend, 0)::numeric(12,2) total_spend, coalesce(actual_rep_pay, 0)::numeric(12,2) actual_rep_pay,
       coalesce(daily_net, 0)::numeric(12,2) daily_net, coalesce(earned_total, 0)::numeric(12,2) earned_total,
       coalesce(overhead, 0)::numeric(12,2) overhead,
       (coalesce(daily_net, 0) + coalesce(earned_total, 0) - coalesce(overhead, 0))::numeric(12,2) net
  from k left join dd using (month_start) left join e using (month_start) left join o using (month_start)
 where public.recon_can_read();
comment on view public.pl_actual_monthly is 'ACTUAL monthly P&L from the ledger: daily nets + earned lines of the month - full monthly overhead. Admin only.';

-- ---------- the PROJECTED P&L: the slice-three walk, renamed for the dual-layer model (never trued up in place) ----------
create or replace view public.pl_projected_daily with (security_invoker = true) as select * from public.pl_daily_walk;
create or replace view public.pl_projected_weekly with (security_invoker = true) as select * from public.pl_weekly_walk;
create or replace view public.pl_projected_monthly with (security_invoker = true) as select * from public.pl_monthly_walk;
comment on view public.pl_projected_daily is 'PROJECTED P&L (= pl_daily_walk): rep pay is projected by Date Booked. Never mixed into the actual P&L.';
comment on view public.pl_projected_weekly is 'PROJECTED weekly P&L (= pl_weekly_walk).';
comment on view public.pl_projected_monthly is 'PROJECTED monthly P&L (= pl_monthly_walk).';

-- Side by side. The revenue / spend / earned / overhead lines come from the same confirmed entries in both layers, so
-- they must match exactly; the only legitimate difference is rep pay (projected by Date Booked vs paid on payday).
create or replace view public.pl_projected_vs_actual_weekly with (security_invoker = true) as
select coalesce(p.week_start, a.week_start) week_start,
       coalesce(p.net, 0)::numeric(12,2) projected_net, coalesce(a.net, 0)::numeric(12,2) actual_net,
       (coalesce(a.net, 0) - coalesce(p.net, 0))::numeric(12,2) variance,
       coalesce(p.projected_commission, 0)::numeric(12,2) projected_rep_pay, coalesce(a.actual_rep_pay, 0)::numeric(12,2) actual_rep_pay,
       (coalesce(p.projected_commission, 0) - coalesce(a.actual_rep_pay, 0))::numeric(12,2) rep_pay_timing_and_true_up,
       (coalesce(p.credit_revenue, 0), coalesce(p.transfer_revenue, 0), coalesce(p.total_spend, 0), coalesce(p.earned_total, 0), coalesce(p.overhead, 0))
         = (coalesce(a.credit_revenue, 0), coalesce(a.transfer_revenue, 0), coalesce(a.total_spend, 0), coalesce(a.earned_total, 0), coalesce(a.overhead, 0))
         as confirmed_lines_match
  from public.pl_weekly_walk p full join public.pl_actual_weekly a on a.week_start = p.week_start
 where public.recon_can_read();
comment on view public.pl_projected_vs_actual_weekly is
  'Projected vs actual per week: variance = projected rep pay - actual rep pay (timing / true-up); confirmed_lines_match must be true. Admin only.';

-- ---------- security ----------
do $$ declare t text; begin
  foreach t in array array['ledger_accounts', 'ledger_transactions', 'ledger_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, public, authenticated, service_role', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists %I_admin_read on public.%I', t, t);
    execute format('create policy %I_admin_read on public.%I for select to authenticated using (public.is_admin())', t, t);
  end loop;
  foreach t in array array['ledger_pending_sources', 'ledger_unposted_sources', 'ledger_trial_balance', 'ledger_health', 'pl_actual_lines',
                           'pl_actual_daily', 'pl_actual_overhead_weekly', 'pl_actual_weekly', 'pl_actual_monthly', 'pl_projected_daily',
                           'pl_projected_weekly', 'pl_projected_monthly', 'pl_projected_vs_actual_weekly'] loop
    execute format('revoke all on public.%I from anon, public, authenticated, service_role', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;
revoke execute on function public.ledger_post_pair(date, text, bigint, text, text, text, numeric, text, text, text),
                           public.ledger_post_pending(), public.ledger_post_trigger(), public.ledger_balance_check(), public.ledger_immutable()
  from public, anon, authenticated, service_role;
revoke execute on function public.ledger_sync() from public, anon, service_role;
grant execute on function public.ledger_sync() to authenticated;
grant execute on function public.ledger_manual_account(text, text) to authenticated;

-- Backfill: post every confirmed row that already exists (live: the manual entries entered since slice three).
select public.ledger_post_pending();
