-- Row-level security on every table. Anon gets nothing.
-- Agents: their own agent row and their own sales (plus the contact/application on those sales).
-- Admin (agents.role = 'admin'): everything. Expenses, P&L, commission_config and event_log: admin only.

alter table public.agents            enable row level security;
alter table public.contacts          enable row level security;
alter table public.applications      enable row level security;
alter table public.sales             enable row level security;
alter table public.call_metrics      enable row level security;
alter table public.expenses          enable row level security;
alter table public.commission_config enable row level security;
alter table public.event_log         enable row level security;

-- Anon: no table or view access at all.
revoke all on all tables in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
revoke execute on all functions in schema public from anon;
alter default privileges in schema public revoke execute on functions from anon;

-- Authenticated: read via RLS; writes only where a policy allows (admin).
revoke all on all tables in schema public from authenticated;
grant select on public.agents, public.contacts, public.applications, public.sales, public.call_metrics,
                public.expenses, public.commission_config, public.event_log,
                public.sales_commission, public.daily_pl, public.weekly_pl, public.monthly_pl to authenticated;
grant insert, update, delete on public.contacts, public.applications, public.sales, public.call_metrics,
                public.expenses to authenticated;
grant update on public.commission_config to authenticated;

-- agents
create policy agents_self_or_admin on public.agents for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- sales
create policy sales_own_or_admin on public.sales for select to authenticated
  using (agent_of_record = public.current_agent_id() or public.is_admin());
create policy sales_admin_write on public.sales for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- contacts / applications: visible to the agent of record on a sale that uses them
create policy contacts_own_or_admin on public.contacts for select to authenticated
  using (public.is_admin() or exists (select 1 from public.sales s
          where s.contact_id = contacts.id and s.agent_of_record = public.current_agent_id()));
create policy contacts_admin_write on public.contacts for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy applications_own_or_admin on public.applications for select to authenticated
  using (public.is_admin() or exists (select 1 from public.sales s
          where s.application_id = applications.id and s.agent_of_record = public.current_agent_id()));
create policy applications_admin_write on public.applications for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- call_metrics: own rows by display name or dialer alias, admin all
create policy call_metrics_own_or_admin on public.call_metrics for select to authenticated
  using (public.is_admin() or exists (select 1 from public.agents a where a.user_id = auth.uid()
          and call_metrics.agent_name in (a.display_name, a.dialer_alias)));
create policy call_metrics_admin_write on public.call_metrics for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- admin-only tables
create policy expenses_admin on public.expenses for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy commission_config_admin_read on public.commission_config for select to authenticated
  using (public.is_admin());
create policy commission_config_admin_update on public.commission_config for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy event_log_admin_read on public.event_log for select to authenticated
  using (public.is_admin());

grant execute on function public.current_agent_id(), public.is_admin(), public.commission_rates(),
                          public.sale_qualifies_for_addon(text[]) to authenticated;

-- Functions are executable by PUBLIC by default; lock our helpers to signed-in users.
revoke execute on function public.current_agent_id(), public.is_admin(), public.commission_rates(),
                           public.sale_qualifies_for_addon(text[]), public.audit_actor_uid(), public.audit_actor_role()
  from public;
grant execute on function public.current_agent_id(), public.is_admin(), public.commission_rates(),
                          public.sale_qualifies_for_addon(text[]), public.audit_actor_uid(), public.audit_actor_role()
  to authenticated, service_role;
revoke execute on function public.audit_row_change(), public.log_premium_mismatch(),
                           public.event_log_immutable(), public.lock_sale_attribution() from public, anon, authenticated;
