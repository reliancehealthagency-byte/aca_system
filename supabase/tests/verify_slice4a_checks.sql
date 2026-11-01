-- Slice 4a checks (actuals ledger LG*, closed-week next-open-payday CW*). Included by verify_slice3.sql at its end
-- when run through verify_slice4a.sql (\set slice4a), against the end state of the slice-three scenario. Do not run alone.
-- ======== slice 4a: the actuals ledger at the end of the scenario (cutover, submit, lock, adjustments, P&L entries) ========
reset role;
set constraints all immediate;   -- run the deferred balance checks now (this script never commits)
select pg_temp.r('LG1. the ledger balances and is complete: total 0, no unbalanced or empty transaction, nothing confirmed left unposted',
  (select transactions > 0 and total = 0 and unbalanced = 0 and empty_transactions = 0 and unposted = 0 from public.ledger_health),
  (select format('txns=%s lines=%s total=%s unbalanced=%s empty=%s unposted=%s', transactions, lines, total, unbalanced, empty_transactions, unposted) from public.ledger_health));
select pg_temp.r('LG2. finalized payroll: ledger rep pay from locks = sum(pay_line_locks) to the cent, one transaction per non-zero lock, on its payday',
  (select coalesce(sum(amount), 0) from public.pay_line_locks)
    = (select coalesce(sum(l.amount), 0) from public.ledger_lines l join public.ledger_transactions t on t.id = l.txn_id where t.source_kind = 'pay_line_lock' and l.account <> 'cash')
  and (select count(*) from public.pay_line_locks where amount <> 0) = (select count(*) from public.ledger_transactions where source_kind = 'pay_line_lock')
  and not exists (select 1 from public.ledger_transactions t join public.pay_line_locks k on k.id = t.source_id where t.source_kind = 'pay_line_lock' and t.txn_date <> k.payday),
  (select format('locks=%s (%s non-zero) ledger txns=%s', sum(amount), count(*) filter (where amount <> 0), (select count(*) from public.ledger_transactions where source_kind = 'pay_line_lock')) from public.pay_line_locks));
select pg_temp.r('LG3. hub-era paydays: the hub paid totals post once each (exp_rep_hub_paid = sum(hub_paid_lock.paid_total))',
  (select coalesce(sum(paid_total), 0) from public.hub_paid_lock) = (select coalesce(sum(amount), 0) from public.ledger_lines where account = 'exp_rep_hub_paid')
  and (select count(*) from public.hub_paid_lock where paid_total <> 0) = (select count(*) from public.ledger_transactions where source_kind = 'hub_paid_lock'),
  (select format('hub=%s ledger=%s', (select sum(paid_total) from public.hub_paid_lock), (select sum(amount) from public.ledger_lines where account = 'exp_rep_hub_paid'))));
select pg_temp.r('LG4. adjustments post only once their payday is submitted and after the cutover (hub-era rows are inside the hub totals, never twice)',
  not exists (select 1 from public.ledger_transactions t join public.pay_adjustments a on a.id = t.source_id
               where t.source_kind = 'pay_adjustment' and (a.payday <= (select last_hub_payday from public.hub_cutover)
                     or not exists (select 1 from public.payroll_cutoffs c where c.payday = a.payday and c.source = 'submit')))
  and (select coalesce(sum(a.amount), 0) from public.pay_adjustments a where a.payday > (select last_hub_payday from public.hub_cutover)
         and exists (select 1 from public.payroll_cutoffs c where c.payday = a.payday and c.source = 'submit'))
      = (select coalesce(sum(amount), 0) from public.ledger_lines where account in ('exp_rep_adjustments', 'exp_rep_clawbacks')),
  (select format('posted=%s not posted=%s', count(*) filter (where exists (select 1 from public.ledger_transactions t where t.source_kind = 'pay_adjustment' and t.source_id = a.id)),
                 count(*) filter (where not exists (select 1 from public.ledger_transactions t where t.source_kind = 'pay_adjustment' and t.source_id = a.id))) from public.pay_adjustments a));
select pg_temp.act('authenticated','admin.test@example.com');
create temp table lg_me as
  select (select coalesce(sum(case when kind = 'debit' then -amount else amount end), 0) from public.manual_entries_current
           where kind in ('credit', 'debit', 'transfer', 'deposit_box')) me_rev,
         (select coalesce(sum(amount), 0) from public.manual_entries_current where kind = 'lead_spend') me_spend,
         (select coalesce(sum(amount), 0) from public.pl_overhead_monthly) me_oh,
         (select coalesce(sum(amount), 0) from public.pl_actual_lines where type = 'revenue' and pl_line <> 'debits')
           - (select coalesce(sum(-amount), 0) from public.pl_actual_lines where pl_line = 'debits') led_rev,
         (select coalesce(sum(amount), 0) from public.pl_actual_lines where pl_line = 'lead_spend') led_spend,
         (select coalesce(sum(amount), 0) from public.pl_actual_lines where pl_line = 'overhead') led_oh,
         (select count(*) from public.manual_entries where correction_kind = 'supersede') n_sup,
         (select count(*) from public.ledger_transactions where source_kind in ('manual_entry_superseded', 'overhead_entry_superseded')) n_rev;
select pg_temp.r('LG5. P&L entries: ledger revenue / lead spend / overhead = the current manual + overhead entries (corrections: one reversal per superseded row)',
  (select me_rev = led_rev and me_spend = led_spend and me_oh = led_oh and n_rev >= n_sup from lg_me),
  (select format('rev %s/%s spend %s/%s overhead %s/%s superseded=%s reversals=%s', me_rev, led_rev, me_spend, led_spend, me_oh, led_oh, n_sup, n_rev) from lg_me));
select pg_temp.r('LG6. projected vs actual: every week''s confirmed lines (credits/debits, transfers, spend, earned, overhead) match exactly; the only difference is rep pay',
  (select count(*) > 0 and bool_and(confirmed_lines_match) and bool_and(variance = rep_pay_timing_and_true_up) from public.pl_projected_vs_actual_weekly),
  (select string_agg(format('%s proj=%s act=%s rp %s/%s', week_start, projected_net, actual_net, projected_rep_pay, actual_rep_pay), '; ' order by week_start)
     from public.pl_projected_vs_actual_weekly));
select pg_temp.r('LG7. the projected P&L is the slice-three walk, unchanged (pl_projected_* = pl_*_walk, row for row)',
  not exists ((select * from public.pl_projected_daily) except (select * from public.pl_daily_walk))
  and not exists ((select * from public.pl_projected_weekly) except (select * from public.pl_weekly_walk))
  and not exists ((select * from public.pl_projected_monthly) except (select * from public.pl_monthly_walk))
  and (select count(*) from public.pl_projected_weekly) = (select count(*) from public.pl_weekly_walk));
select pg_temp.r('LG8. projections never touch the books: actual rep pay = locks + posted adjustments + hub totals only (OPEN / held / unlocked lines add nothing)',
  (select coalesce(sum(actual_rep_pay), 0) from public.pl_actual_daily)
    = (select coalesce(sum(amount), 0) from public.ledger_lines where account like 'exp_rep_%')
  and (select coalesce(sum(actual_rep_pay), 0) from public.pl_actual_daily) <> (select coalesce(sum(projected_commission), 0) from public.pl_daily_walk),
  (select format('actual=%s projected=%s', (select sum(actual_rep_pay) from public.pl_actual_daily), (select sum(projected_commission) from public.pl_daily_walk))));
do $$ begin
  insert into public.ledger_transactions (txn_date, source_kind, source_id, memo) values (current_date, 'manual_entry', -1, 'VERIFY');
  perform pg_temp.r('LG9. an admin cannot write the ledger directly (posting only through the source tables)', false, 'insert succeeded');
exception when others then perform pg_temp.r('LG9. an admin cannot write the ledger directly (posting only through the source tables)', true, sqlerrm); end $$;
select pg_temp.r('LG9b. an admin reads the ledger; ledger_sync() by an admin posts nothing new (already complete)',
  (select count(*) from public.ledger_transactions) > 0 and public.ledger_sync() = 0);
select pg_temp.act('authenticated','agent.test@example.com');
select pg_temp.r('LG10. an agent sees no ledger rows and no actual P&L',
  (select count(*) from public.ledger_transactions) = 0 and (select count(*) from public.pl_actual_daily) = 0 and (select count(*) from public.ledger_lines) = 0);
select pg_temp.act('service_role','admin.test@example.com');
do $$ begin
  perform public.ledger_sync();
  reset role; perform pg_temp.r('LG11. the service_role key cannot run ledger_sync', false, 'ran');
exception when others then reset role; perform pg_temp.r('LG11. the service_role key cannot run ledger_sync', true, sqlerrm); end $$;
select pg_temp.srv();
do $$ begin
  update public.ledger_lines set amount = amount + 1 where true;
  perform pg_temp.r('LG12. immutable even for postgres: update, delete and truncate are refused', false, 'updated');
exception when others then
  begin
    delete from public.ledger_transactions where true;
    perform pg_temp.r('LG12. immutable even for postgres: update, delete and truncate are refused', false, 'deleted');
  exception when others then
    begin
      truncate public.ledger_lines;
      perform pg_temp.r('LG12. immutable even for postgres: update, delete and truncate are refused', false, 'truncated');
    exception when others then perform pg_temp.r('LG12. immutable even for postgres: update, delete and truncate are refused', sqlerrm like '%immutable%', sqlerrm);
    end;
  end;
end $$;
do $$ declare t bigint; begin
  insert into public.ledger_transactions (txn_date, source_kind, source_id, memo) values (current_date, 'manual_entry', -2, 'VERIFY unbalanced') returning id into t;
  insert into public.ledger_lines (txn_id, account, amount) values (t, 'cash', 10), (t, 'rev_premier_credits', -9.99);
  set constraints all immediate;
  perform pg_temp.r('LG13. always balances: a transaction whose lines don''t sum to 0 is refused', false, 'accepted');
exception when others then perform pg_temp.r('LG13. always balances: a transaction whose lines don''t sum to 0 is refused', sqlerrm like '%does not balance%', sqlerrm); end $$;
-- a supersede + a reverse on a fresh credit: ledger follows, net = the current entry
insert into public.manual_entries (kind, entry_date, period, amount, note) values ('credit', '2026-11-02', 'day', 500, 'VERIFY LG14');
insert into public.manual_entries (kind, entry_date, period, amount, note, correction_of, correction_kind)
  select 'credit', '2026-11-02', 'day', 450, 'VERIFY LG14 fix', id, 'supersede' from public.manual_entries where note = 'VERIFY LG14';
insert into public.manual_entries (kind, entry_date, period, amount, note, correction_of, correction_kind)
  select 'credit', '2026-11-02', 'day', -450, 'VERIFY LG14 undo', id, 'reverse' from public.manual_entries where note = 'VERIFY LG14 fix';
set constraints all immediate;
select pg_temp.r('LG14. corrections: credit 500 superseded by 450 then reversed -> ledger 11/02 credits net 0 (500 - 500 + 450 - 450), 4 transactions, still balanced',
  (select coalesce(sum(-l.amount), 0) from public.ledger_lines l join public.ledger_transactions t on t.id = l.txn_id
     where l.account = 'rev_premier_credits' and t.txn_date = '2026-11-02') = 0
  and (select count(*) from public.ledger_transactions t where t.txn_date = '2026-11-02' and t.source_kind like 'manual_entry%') = 4
  and (select total = 0 and unbalanced = 0 and unposted = 0 from public.ledger_health),
  (select string_agg(source_kind || ':' || memo, '; ' order by id) from public.ledger_transactions where txn_date = '2026-11-02'));

-- ======== slice 4a: closed-week rows on the NEXT OPEN payday (Kyle directive 11/01; Hub v19.11 L1771-1779) ========
select pg_temp.r('CW0. closed_week_policy at start: next_open_payday once migration 20261101100200 ran (fresh build; column default next_open_payday), else hold (live today)',
  (select case when col_default ~ 'next_open_payday' then policy = 'next_open_payday' else policy = 'hold' end from cw_start),
  (select format('policy=%s default=%s', policy, col_default) from cw_start));
create temp table cw_before as
  select (select count(*) from public.pay_line_locks where payday <= '2026-11-13') locks_0, (select sum(amount) from public.pay_line_locks where payday <= '2026-11-13') amt_0,
         (select count(*) from public.board_week_freezes) frz_0,
         (select md5(string_agg(row(f.*)::text, '|' order by f.submission_key)) from public.board_week_freezes f) frz_md5;
update public.recon_pay_config set closed_week_policy = 'next_open_payday' where id;
select pg_temp.r('CW1. next_open_payday: the brand-new 10/30 deal first seen after the 11/06 submit pays 119.32 on 11/20 (11/06 and 11/13 are submitted, so the next open payday), carried from 11/06, no hold',
  (select hold_status = 'carried_to_next_open_payday' and pay_commission = 119.32 and final_payable = 119.32 and carried_commission_payday = '2026-11-20'
          and carried_from_payday = '2026-11-06' and not commission_locked and not due_on_submitted_payday_unlocked
     from public.premier_recon_trueup where line_key = '20261030163000-P'),
  (select format('hold=%s pay=%s final=%s carried=%s from=%s unlocked_due=%s', hold_status, pay_commission, final_payable, carried_commission_payday, carried_from_payday, due_on_submitted_payday_unlocked)
     from public.premier_recon_trueup where line_key = '20261030163000-P'));
select pg_temp.r('CW2. a re-added duplicate of an already-locked deal still pays nothing (status rule: one paying line per deal)',
  (select sum(coalesce(final_payable, 0)) from public.premier_recon_trueup where line_key like '20261030130%-ABS') = 20
  and (select count(*) from public.pay_line_locks where line_key like '20261030130%-ABS') = 1,
  (select string_agg(line_key || ' ' || coalesce(final_payable::text, 'NULL') || ' ' || coalesce(hold_status, '-'), ', ') from public.premier_recon_trueup where line_key like '20261030130%-ABS'));
insert into public.payroll_cutoffs (payday, cutoff_at, source, note) values ('2026-11-20', '2026-11-19 14:30-05', 'submit', 'VERIFY submit 11/20')
  on conflict (payday) do update set source = 'submit', cutoff_at = excluded.cutoff_at, note = excluded.note;
select pg_temp.r('CW3. recording the 11/20 submit anchors the carried components on 11/20 (first detection; never moves after)',
  exists (select 1 from public.closed_week_carry_anchors where line_key = '20261030163000-P' and component = 'commission' and payday = '2026-11-20' and orig_payday = '2026-11-06'),
  (select string_agg(line_key || ':' || component || '@' || payday, ', ') from public.closed_week_carry_anchors));
create temp table cw_lk as select public.premier_lock_payday('2026-11-20') n;
set constraints all immediate;
select pg_temp.r('CW4. lock 11/20 locks the carried line on 11/20 (its own line); the closed 11/06 and 11/13 paydays, their locks and the frozen weeks are unchanged',
  exists (select 1 from public.pay_line_locks where line_key = '20261030163000-P' and component = 'commission' and payday = '2026-11-20' and amount = 119.32)
  and not exists (select 1 from public.pay_line_locks where line_key = '20261030163000-P' and payday <= '2026-11-13')
  and (select locks_0 = (select count(*) from public.pay_line_locks where payday <= '2026-11-13')
              and amt_0 = (select sum(amount) from public.pay_line_locks where payday <= '2026-11-13')
              and frz_md5 = (select md5(string_agg(row(f.*)::text, '|' order by f.submission_key)) from public.board_week_freezes f where f.week_payday <= '2026-11-13')
         from cw_before),
  (select format('locked on 11/20: %s', string_agg(line_key || ':' || component || '=' || amount, ', ')) from public.pay_line_locks where payday = '2026-11-20'));
select pg_temp.r('CW5. the ledger posts the carried pay on 11/20 (actual rep pay), and still balances with nothing unposted',
  exists (select 1 from public.ledger_transactions t join public.pay_line_locks k on k.id = t.source_id
           where t.source_kind = 'pay_line_lock' and k.line_key = '20261030163000-P' and t.txn_date = '2026-11-20')
  and (select total = 0 and unbalanced = 0 and unposted = 0 from public.ledger_health));
do $$ begin
  update public.closed_week_carry_anchors set payday = payday + 7 where true;
  perform pg_temp.r('CW6. carry anchors are immutable', false, 'updated');
exception when others then perform pg_temp.r('CW6. carry anchors are immutable', sqlerrm like '%immutable%', sqlerrm); end $$;
