-- Slice two, part 3 of 3: RLS + grants for the new objects. Same model as slice one:
-- anon gets nothing; expenses, categories, revenue adjustments and every P&L view are admin only.

alter table public.expense_categories  enable row level security;
alter table public.revenue_adjustments enable row level security;

revoke all on public.expense_categories, public.revenue_adjustments,
              public.pl_line_items, public.pl_daily, public.pl_weekly, public.pl_monthly, public.pl_unpriced_sales
  from public, anon, authenticated;

grant select on public.expense_categories, public.revenue_adjustments,
                public.pl_line_items, public.pl_daily, public.pl_weekly, public.pl_monthly, public.pl_unpriced_sales to authenticated;
grant insert, update, delete on public.expense_categories, public.revenue_adjustments to authenticated;

drop policy if exists expense_categories_admin on public.expense_categories;
create policy expense_categories_admin on public.expense_categories for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists revenue_adjustments_admin on public.revenue_adjustments;
create policy revenue_adjustments_admin on public.revenue_adjustments for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- expenses keeps its slice-one admin-only policy (expenses_admin) and grants; nothing changes there.

revoke execute on function public.touch_updated_at() from public, anon, authenticated;
