-- Slice one: core Premier-first schema (Kyle approved 10/31).
-- ACA comes later as a separate table/flag; no retention-status field (GoHighLevel retention is a separate system).
-- Seed data only: no GHL, Kimbo, Ringba or Premier integrations in this slice.

create extension if not exists pgcrypto;

-- Agents / profiles: maps a Supabase Auth user to an agent and a role.
create table public.agents (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid unique references auth.users(id) on delete set null,
  display_name     text not null unique,
  email            text unique,
  role             text not null default 'agent' check (role in ('agent','admin')),
  dialer_alias     text,                -- e.g. call-log name; null = intentionally unmapped
  no_spiff         boolean not null default false,
  no_transfer_pay  boolean not null default false,
  active           boolean not null default true,
  created_at       timestamptz not null default now()
);
comment on table public.agents is 'One row per agent/admin. user_id links to auth.users. role=admin sees everything.';

create table public.contacts (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  email               text,
  phone               text,
  state               text check (state is null or state ~ '^[A-Z]{2}$'),
  preferred_language  text,
  created_at          timestamptz not null default now()
);

create table public.applications (
  id                    uuid primary key default gen_random_uuid(),
  contact_id            uuid not null references public.contacts(id) on delete restrict,
  carrier               text not null,          -- e.g. 'Premier'
  plan_type             text,
  status                text not null default 'submitted'
                          check (status in ('submitted','pending','active','cancelled','declined')),
  submitted_date        date not null,
  premier_billing_date  date,                   -- Premier's billing date: post-dated deals pay off this, never the form's future date
  created_at            timestamptz not null default now()
);

create table public.sales (
  id                  uuid primary key default gen_random_uuid(),
  contact_id          uuid not null references public.contacts(id) on delete restrict,
  application_id      uuid references public.applications(id) on delete restrict,
  agent_of_record     uuid not null references public.agents(id),   -- form submitter or CRM converter; locked
  attribution_source  text not null default 'sales_form' check (attribution_source in ('sales_form','crm_converter')),
  premier_agent_ref   text,             -- Premier's agent field: reference only, NEVER used for attribution
  sale_date           date not null,    -- = form "Date Booked"
  board_premium       numeric(12,2) check (board_premium is null or board_premium >= 0),    -- the agent's claim
  premier_premium     numeric(12,2) check (premier_premium is null or premier_premium >= 0), -- Premier = truth
  pay_premium         numeric(12,2) generated always as (premier_premium) stored,           -- paid on Premier only
  addon_products      text[] not null default '{}',
  post_dated          boolean not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
comment on column public.sales.premier_agent_ref is 'Reference only. Attribution is agent_of_record (form submitter / CRM converter).';
comment on column public.sales.pay_premium is 'Premier premium; NULL until Premier reports it. Board premium is a claim, never paid.';
create index sales_agent_idx on public.sales(agent_of_record);
create index sales_date_idx on public.sales(sale_date);

-- Attribution is locked once written.
create or replace function public.lock_sale_attribution() returns trigger
language plpgsql as $$
begin
  if new.agent_of_record is distinct from old.agent_of_record then
    raise exception 'agent_of_record is locked (attribution = form submitter / CRM converter); use a reviewed correction';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger sales_lock_attribution before update on public.sales
  for each row execute function public.lock_sale_attribution();

create table public.call_metrics (
  id                uuid primary key default gen_random_uuid(),
  agent_name        text not null,
  date              date not null,
  calls_made        integer not null default 0 check (calls_made >= 0),
  connects          integer not null default 0 check (connects >= 0),
  appointments_set  integer not null default 0 check (appointments_set >= 0),
  created_at        timestamptz not null default now(),
  unique (agent_name, date)
);

create table public.expenses (
  id           uuid primary key default gen_random_uuid(),
  category     text not null,
  amount       numeric(12,2) not null check (amount >= 0),
  date         date not null,
  description  text,
  created_at   timestamptz not null default now()
);

-- The ONE place commission rates live. Single row; edit it, no migration needed.
create table public.commission_config (
  id                         boolean primary key default true check (id),
  base_rate                  numeric(6,4) not null default 0.38,
  addon_bonus_rate           numeric(6,4) not null default 0.05,
  qualifying_addon_patterns  text[] not null default array[
                               'ConsultCare Asset','ConsultCare Edge','ConsultCare Ultra',
                               'Consult Care Asset','Consult Care Edge','Consult Care Ultra',
                               'Wellness4You','AD&D%','ADD','ADD %','Any ADD type%','Champion%'],
  updated_at                 timestamptz not null default now(),
  note                       text
);
comment on table public.commission_config is 'Single-row config: 38% base, +5% with a qualifying add-on (case-sensitive LIKE patterns). Kyle 10/31.';
insert into public.commission_config (id, note) values (true, 'Kyle 10/31: 38% base, +5% for ConsultCare Asset/Edge/Ultra, Wellness4You, any ADD type');
