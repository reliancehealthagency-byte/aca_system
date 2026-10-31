-- FAKE seed data only (no real PII). Names say "(fake)"; emails are @example.com; phones are 555-01xx.
-- Dates fall in the week of Sun 2026-10-25 to Sat 2026-10-31 (today in the build).
-- Agents link to Supabase Auth users by email when those users exist (see scripts/create_test_users.sh).

insert into public.agents (id, display_name, email, role, dialer_alias, user_id) values
  ('00000000-0000-4000-8000-00000000a001', 'Test Admin (fake)',     'admin.test@example.com', 'admin', null,       (select id from auth.users where email = 'admin.test@example.com')),
  ('00000000-0000-4000-8000-00000000a002', 'Alex Testagent (fake)', 'agent.test@example.com', 'agent', 'Alex 901', (select id from auth.users where email = 'agent.test@example.com')),
  ('00000000-0000-4000-8000-00000000a003', 'Blair Sample (fake)',   'agent2.test@example.com','agent', 'Blair 902',(select id from auth.users where email = 'agent2.test@example.com'));

insert into public.contacts (id, name, email, phone, state, preferred_language) values
  ('00000000-0000-4000-8000-0000000c0001', 'Fake Person One',   'fake.one@example.com',   '555-0101', 'FL', 'English'),
  ('00000000-0000-4000-8000-0000000c0002', 'Fake Person Two',   'fake.two@example.com',   '555-0102', 'TX', 'Spanish'),
  ('00000000-0000-4000-8000-0000000c0003', 'Fake Person Three', 'fake.three@example.com', '555-0103', 'GA', 'English'),
  ('00000000-0000-4000-8000-0000000c0004', 'Fake Person Four',  'fake.four@example.com',  '555-0104', 'NC', 'English'),
  ('00000000-0000-4000-8000-0000000c0005', 'Fake Person Five',  'fake.five@example.com',  '555-0105', 'FL', 'Spanish'),
  ('00000000-0000-4000-8000-0000000c0006', 'Fake Person Six',   'fake.six@example.com',   '555-0106', 'TX', 'English'),
  ('00000000-0000-4000-8000-0000000c0007', 'Fake Person Seven', 'fake.seven@example.com', '555-0107', 'OH', 'English'),
  ('00000000-0000-4000-8000-0000000c0008', 'Fake Person Eight', 'fake.eight@example.com', '555-0108', 'AZ', 'Spanish'),
  ('00000000-0000-4000-8000-0000000c0009', 'Fake Person Nine',  'fake.nine@example.com',  '555-0109', 'FL', 'English'),
  ('00000000-0000-4000-8000-0000000c0010', 'Fake Person Ten',   'fake.ten@example.com',   '555-0110', 'TN', 'English');

insert into public.applications (id, contact_id, carrier, plan_type, status, submitted_date, premier_billing_date) values
  ('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-0000000c0001', 'Premier', 'Health Access (fake)', 'active',    '2026-10-26', '2026-10-26'),
  ('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-0000000c0002', 'Premier', 'Health Access (fake)', 'active',    '2026-10-27', '2026-10-27'),
  ('00000000-0000-4000-8000-0000000a0003', '00000000-0000-4000-8000-0000000c0003', 'Premier', 'Health Access (fake)', 'active',    '2026-10-28', '2026-10-28'),
  ('00000000-0000-4000-8000-0000000a0004', '00000000-0000-4000-8000-0000000c0004', 'Premier', 'Health Access (fake)', 'pending',   '2026-10-30', '2026-11-05'),
  ('00000000-0000-4000-8000-0000000a0005', '00000000-0000-4000-8000-0000000c0005', 'Premier', 'Health Access (fake)', 'submitted', '2026-10-31', null);

insert into public.sales (id, contact_id, application_id, agent_of_record, attribution_source, premier_agent_ref,
                          sale_date, board_premium, premier_premium, addon_products, post_dated) values
  -- 38% base
  ('00000000-0000-4000-8000-00000005a001', '00000000-0000-4000-8000-0000000c0001', '00000000-0000-4000-8000-0000000a0001',
   '00000000-0000-4000-8000-00000000a002', 'sales_form',    'PREM-REF-FAKE-1', '2026-10-26', 100.00, 100.00, '{}', false),
  -- qualifying add-on -> 43%
  ('00000000-0000-4000-8000-00000005a002', '00000000-0000-4000-8000-0000000c0002', '00000000-0000-4000-8000-0000000a0002',
   '00000000-0000-4000-8000-00000000a002', 'sales_form',    'PREM-REF-FAKE-1', '2026-10-27', 120.00, 120.00, '{Wellness4You}', false),
  -- premium mismatch: board claim 150, Premier 140 -> paid on 140, event logged.
  -- premier_agent_ref points at a different agent on purpose: it must NOT change attribution.
  ('00000000-0000-4000-8000-00000005a003', '00000000-0000-4000-8000-0000000c0003', '00000000-0000-4000-8000-0000000a0003',
   '00000000-0000-4000-8000-00000000a003', 'crm_converter', 'PREM-REF-FAKE-1', '2026-10-28', 150.00, 140.00, '{}', false),
  -- post-dated, Premier not reported yet: pays off Premier billing date 11/05 -> Friday 11/13
  ('00000000-0000-4000-8000-00000005a004', '00000000-0000-4000-8000-0000000c0004', '00000000-0000-4000-8000-0000000a0004',
   '00000000-0000-4000-8000-00000000a003', 'sales_form',    'PREM-REF-FAKE-2', '2026-10-30',  90.00,   null, '{}', true),
  -- today
  ('00000000-0000-4000-8000-00000005a005', '00000000-0000-4000-8000-0000000c0005', '00000000-0000-4000-8000-0000000a0005',
   '00000000-0000-4000-8000-00000000a002', 'sales_form',    null,              '2026-10-31', 110.00, 110.00, '{}', false);

insert into public.call_metrics (agent_name, date, calls_made, connects, appointments_set) values
  ('Alex Testagent (fake)', '2026-10-29', 120, 31, 4),
  ('Alex Testagent (fake)', '2026-10-30', 135, 28, 5),
  ('Alex Testagent (fake)', '2026-10-31',  60, 14, 2),
  ('Blair Sample (fake)',   '2026-10-29', 110, 25, 3),
  ('Blair Sample (fake)',   '2026-10-30', 128, 30, 4);

-- Slice two: categories are lookup codes (expense_categories) and source is required. On the live project these rows
-- were inserted by slice one as 'Leads'/'Software' and remapped in place by migration 20261031200000.
insert into public.expenses (category, amount, date, description, source) values
  ('lead_spend',      200.00, '2026-10-26', 'FAKE seed: lead spend',   'seed'),
  ('lead_spend',      175.00, '2026-10-29', 'FAKE seed: lead spend',   'seed'),
  ('lead_spend',      150.00, '2026-10-31', 'FAKE seed: lead spend',   'seed'),
  ('dialer_software',  49.00, '2026-10-31', 'FAKE seed: subscription', 'seed');

-- (Re)link agents to auth users by email, in case the users were created after the seed ran.
update public.agents a set user_id = u.id from auth.users u where u.email = a.email and a.user_id is null;
