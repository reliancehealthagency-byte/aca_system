-- Commission (derived from commission_config at read time), premium-mismatch events, P&L views.

-- Role helpers (security definer so policies can call them without recursion).
create or replace function public.current_agent_id() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select id from public.agents where user_id = auth.uid() and active
$$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select role = 'admin' from public.agents where user_id = auth.uid() and active), false)
$$;

-- Rates for anyone allowed to read their own sales; the config table itself stays admin-only.
create or replace function public.commission_rates()
returns table(base_rate numeric, addon_bonus_rate numeric, qualifying_addon_patterns text[])
language sql stable security definer set search_path = public, pg_temp as $$
  select base_rate, addon_bonus_rate, qualifying_addon_patterns from public.commission_config where id
$$;

create or replace function public.sale_qualifies_for_addon(products text[]) returns boolean
language sql stable as $$
  select exists (select 1 from unnest(coalesce(products,'{}')) p,
                               unnest((select qualifying_addon_patterns from public.commission_rates())) pat
                  where p like pat)
$$;

-- Commission is never stored: it's computed from the one config row, so a rate change needs no migration.
create view public.sales_commission with (security_invoker = true) as
select s.id, s.contact_id, s.application_id, s.agent_of_record, ag.display_name as agent_name,
       s.attribution_source, s.premier_agent_ref, s.sale_date, s.board_premium, s.premier_premium, s.pay_premium,
       s.addon_products, s.post_dated, ap.carrier, ap.plan_type, ap.status as application_status, ap.premier_billing_date,
       q.qualifies as qualifying_addon,
       (r.base_rate + case when q.qualifies then r.addon_bonus_rate else 0 end)                as commission_rate,
       round(s.pay_premium * (r.base_rate + case when q.qualifies then r.addon_bonus_rate else 0 end), 2) as commission,
       round(coalesce(s.premier_premium, s.board_premium)
             * (r.base_rate + case when q.qualifies then r.addon_bonus_rate else 0 end), 2)    as commission_estimate,
       case when s.premier_premium is not null then 'premier' when s.board_premium is not null then 'board_claim_pending' end
                                                                                                as premium_source,
       pb.pay_basis_date,
       (pb.pay_basis_date - extract(dow from pb.pay_basis_date)::int + 12)                     as commission_pay_friday,
       s.created_at
  from public.sales s
  left join public.applications ap on ap.id = s.application_id
  left join public.agents ag on ag.id = s.agent_of_record
  cross join public.commission_rates() r
  cross join lateral (select public.sale_qualifies_for_addon(s.addon_products) as qualifies) q
  cross join lateral (select case when ap.premier_billing_date is not null
                                   and (s.post_dated or ap.premier_billing_date > s.sale_date + 1)
                                  then ap.premier_billing_date else s.sale_date end as pay_basis_date) pb;
comment on view public.sales_commission is
  'commission = pay_premium (Premier) x rate; NULL until Premier reports. commission_estimate uses board claim when Premier is pending. Pay Friday = Friday after the Sun-Sat week of pay_basis_date (Premier billing date for post-dated deals).';

-- Premium mismatch: Premier is truth, board is a claim. Log the diff; attribution unchanged.
create or replace function public.log_premium_mismatch() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.premier_premium is not null and new.board_premium is not null
     and abs(new.premier_premium - new.board_premium) > 0.01
     and (tg_op = 'INSERT'
          or new.premier_premium is distinct from old.premier_premium
          or new.board_premium is distinct from old.board_premium) then
    insert into public.event_log(event_type, actor_uid, actor_role, table_name, row_id, action, detail)
    values ('premium_mismatch', public.audit_actor_uid(), public.audit_actor_role(), 'sales', new.id::text, 'EVENT',
            jsonb_build_object('board_premium', new.board_premium, 'premier_premium', new.premier_premium,
                               'diff', new.premier_premium - new.board_premium,
                               'agent_of_record', new.agent_of_record, 'attribution', 'unchanged',
                               'paid_on', 'premier_premium'));
  end if;
  return new;
end $$;
create trigger sales_premium_mismatch after insert or update of board_premium, premier_premium on public.sales
  for each row execute function public.log_premium_mismatch();

-- P&L. PLACEHOLDER revenue: premium (Premier when present, else board claim), pending the 42% question.
-- Agent commission = commission_estimate from the config. Admin only (filtered by is_admin()).
create view public.daily_pl with (security_invoker = true) as
with s as (
  select sale_date as day, count(*) as sales_count,
         sum(coalesce(premier_premium, board_premium)) as premium_total,
         sum(commission_estimate) as agent_commission
    from public.sales_commission where public.is_admin() group by sale_date),
e as (select date as day, sum(amount) as expenses from public.expenses where public.is_admin() group by date),
d as (select day from s union select day from e)
select d.day,
       coalesce(s.sales_count, 0)                                                   as sales_count,
       coalesce(s.premium_total, 0)::numeric(12,2)                                  as premium_total,
       coalesce(s.agent_commission, 0)::numeric(12,2)                               as agent_commission,
       coalesce(e.expenses, 0)::numeric(12,2)                                       as expenses,
       (coalesce(s.premium_total,0) - coalesce(s.agent_commission,0) - coalesce(e.expenses,0))::numeric(12,2)
                                                                                    as net_placeholder
  from d left join s using (day) left join e using (day);
comment on view public.daily_pl is
  'PLACEHOLDER P&L: premium_total (Premier premium, else board claim) - agent_commission (config rate) - expenses. Real agency revenue rate is unverified (P&L 42% vs 38/43%).';

create view public.weekly_pl with (security_invoker = true) as
select (day - extract(dow from day)::int) as week_start,      -- Sunday
       (day - extract(dow from day)::int + 6) as week_end,    -- Saturday
       sum(sales_count)::int as sales_count, sum(premium_total) as premium_total,
       sum(agent_commission) as agent_commission, sum(expenses) as expenses, sum(net_placeholder) as net_placeholder
  from public.daily_pl group by 1, 2;

create view public.monthly_pl with (security_invoker = true) as
select date_trunc('month', day)::date as month,
       sum(sales_count)::int as sales_count, sum(premium_total) as premium_total,
       sum(agent_commission) as agent_commission, sum(expenses) as expenses, sum(net_placeholder) as net_placeholder
  from public.daily_pl group by 1;
