-- Slice two, part 2 of 3: line-item P&L views.
-- P&L = revenue lines - commission lines - expense lines. Every summary row is the sum of its lines in pl_line_items.
-- Revenue per sale is the same PLACEHOLDER as slice one: premium (Premier when present, else board claim).
-- Commission lines use the slice-one sales_commission view unchanged (commission_config, pay_premium, attribution as-is),
-- split into a base line and an add-on bonus line that add up exactly to commission_estimate.
-- Admin only: every branch is filtered by is_admin(), and the views run as the caller (security_invoker) so table RLS applies.
-- Periods: week starts Sunday (same as slice one weekly_pl), month = calendar month.

create or replace view public.pl_line_items with (security_invoker = true) as
with sc as (
  select c.*, r.base_rate,
         coalesce(c.premier_premium, c.board_premium) as premium_basis,
         round(coalesce(c.premier_premium, c.board_premium) * r.base_rate, 2) as base_commission
    from public.sales_commission c cross join public.commission_rates() r
   where public.is_admin() and coalesce(c.premier_premium, c.board_premium) is not null
),
lines as (
  -- revenue: one line per sale
  select sc.sale_date as line_date, 'revenue'::text as line_type,
         case when sc.premier_premium is not null then 'premium_premier' else 'premium_board_claim' end as category,
         concat_ws(' ', 'Sale premium', sc.carrier, '(' || sc.plan_type || ')',
                   case when cardinality(sc.addon_products) > 0 then '+ add-ons: ' || array_to_string(sc.addon_products, ', ') end)
           as description,
         coalesce(sc.premium_source, 'unknown') as source,
         sc.premium_basis as amount, 'sales'::text as ref_table, sc.id as ref_id, sc.agent_name
    from sc
  union all
  -- revenue: manual adjustments (signed)
  select ra.date, 'revenue', ra.category, ra.description, ra.source, ra.amount, 'revenue_adjustments', ra.id, null
    from public.revenue_adjustments ra where public.is_admin()
  union all
  -- commission: base rate on the premium basis
  select sc.sale_date, 'commission', 'agent_commission_base',
         format('Base %s%% of %s', trim(to_char(sc.base_rate * 100, 'FM990.##')), to_char(sc.premium_basis, 'FM999999990.00')),
         case when sc.premier_premium is not null then 'premier' else 'board_claim_estimate' end,
         sc.base_commission, 'sales', sc.id, sc.agent_name
    from sc
  union all
  -- commission: add-on bonus (difference to the configured total, so lines sum exactly to commission_estimate)
  select sc.sale_date, 'commission', 'agent_commission_addon_bonus',
         'Add-on bonus: ' || array_to_string(sc.addon_products, ', '),
         case when sc.premier_premium is not null then 'premier' else 'board_claim_estimate' end,
         sc.commission_estimate - sc.base_commission, 'sales', sc.id, sc.agent_name
    from sc where sc.qualifying_addon and sc.commission_estimate - sc.base_commission <> 0
  union all
  -- expenses
  select e.date, 'expense', e.category,
         concat_ws(' - ', e.description, e.vendor), e.source, e.amount, 'expenses', e.id, null
    from public.expenses e where public.is_admin()
)
select l.line_date,
       (l.line_date - extract(dow from l.line_date)::int)      as week_start,   -- Sunday
       date_trunc('month', l.line_date)::date                    as month_start,
       l.line_type, l.category,
       coalesce(ec.label, case l.category
         when 'premium_premier' then 'Premium (Premier)'
         when 'premium_board_claim' then 'Premium (board claim, Premier pending)'
         when 'carrier_bonus' then 'Carrier bonus' when 'override' then 'Override'
         when 'chargeback' then 'Chargeback' when 'other_revenue' then 'Other revenue'
         when 'agent_commission_base' then 'Agent commission (base)'
         when 'agent_commission_addon_bonus' then 'Agent commission (add-on bonus)'
         else l.category end)                                     as category_label,
       l.description, l.source,
       l.amount::numeric(12,2)                                    as amount,
       (case when l.line_type = 'revenue' then l.amount else -l.amount end)::numeric(12,2) as signed_amount,
       l.ref_table, l.ref_id, l.agent_name
  from lines l
  left join public.expense_categories ec on l.line_type = 'expense' and ec.code = l.category;
comment on view public.pl_line_items is
  'Every P&L line (revenue / commission / expense) with day, Sunday week_start and month_start keys. signed_amount: revenue +, commission and expense -. Admin only.';

-- Summaries: straight sums of pl_line_items, so a drill-down always adds back to the summary row.
create or replace view public.pl_daily with (security_invoker = true) as
select line_date as day, week_start, month_start,
       count(distinct ref_id) filter (where ref_table = 'sales')                    as sales_count,
       count(*)                                                                     as line_count,
       coalesce(sum(amount) filter (where line_type = 'revenue'), 0)::numeric(12,2)   as revenue,
       coalesce(sum(amount) filter (where line_type = 'commission'), 0)::numeric(12,2) as commission,
       coalesce(sum(amount) filter (where line_type = 'expense'), 0)::numeric(12,2)    as expenses,
       sum(signed_amount)::numeric(12,2)                                            as net
  from public.pl_line_items group by line_date, week_start, month_start;

create or replace view public.pl_weekly with (security_invoker = true) as
select week_start, (week_start + 6) as week_end,
       count(distinct ref_id) filter (where ref_table = 'sales')                    as sales_count,
       count(*)                                                                     as line_count,
       coalesce(sum(amount) filter (where line_type = 'revenue'), 0)::numeric(12,2)   as revenue,
       coalesce(sum(amount) filter (where line_type = 'commission'), 0)::numeric(12,2) as commission,
       coalesce(sum(amount) filter (where line_type = 'expense'), 0)::numeric(12,2)    as expenses,
       sum(signed_amount)::numeric(12,2)                                            as net
  from public.pl_line_items group by week_start;

create or replace view public.pl_monthly with (security_invoker = true) as
select month_start, (month_start + interval '1 month' - interval '1 day')::date as month_end,
       count(distinct ref_id) filter (where ref_table = 'sales')                    as sales_count,
       count(*)                                                                     as line_count,
       coalesce(sum(amount) filter (where line_type = 'revenue'), 0)::numeric(12,2)   as revenue,
       coalesce(sum(amount) filter (where line_type = 'commission'), 0)::numeric(12,2) as commission,
       coalesce(sum(amount) filter (where line_type = 'expense'), 0)::numeric(12,2)    as expenses,
       sum(signed_amount)::numeric(12,2)                                            as net
  from public.pl_line_items group by month_start;

comment on view public.pl_daily   is 'Line-item P&L per day (sum of pl_line_items). Admin only.';
comment on view public.pl_weekly  is 'Line-item P&L per Sun-Sat week (sum of pl_line_items). Admin only.';
comment on view public.pl_monthly is 'Line-item P&L per calendar month (sum of pl_line_items). Admin only.';

-- Sales with neither a Premier nor a board premium produce no P&L line. They are listed here instead of
-- disappearing silently; /pl shows the count. Admin only.
create or replace view public.pl_unpriced_sales with (security_invoker = true) as
select c.id as sale_id, c.sale_date,
       (c.sale_date - extract(dow from c.sale_date)::int) as week_start,
       date_trunc('month', c.sale_date)::date             as month_start,
       c.agent_name, c.carrier, c.plan_type, c.post_dated, c.application_status
  from public.sales_commission c
 where public.is_admin() and c.premier_premium is null and c.board_premium is null;
comment on view public.pl_unpriced_sales is
  'Sales with no Premier premium and no board premium: not in pl_line_items until one is recorded. Admin only.';
