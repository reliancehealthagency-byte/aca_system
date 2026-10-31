-- Slice two FAKE sample expense lines (no real vendors, invoices or amounts). Idempotent: keyed on
-- (source='seed', external_ref='seed-s2-NN'), so re-running inserts nothing new.
-- Dates are Oct 1-24, 2026 (no Sundays) so the slice-one checks for the week of Sun 10/25 stay unchanged.
insert into public.expenses (date, category, amount, description, vendor, source, external_ref) values
  ('2026-10-01', 'dialer_software', 300.00, 'FAKE seed: dialer seats, October',     'Fake Dialer Co',      'seed', 'seed-s2-01'),
  ('2026-10-01', 'office',         1200.00, 'FAKE seed: office rent, October',      'Fake Landlord LLC',   'seed', 'seed-s2-02'),
  ('2026-10-02', 'lead_spend',      250.00, 'FAKE seed: aged leads batch',          'Fake Leads Inc',      'seed', 'seed-s2-03'),
  ('2026-10-05', 'lead_spend',      400.00, 'FAKE seed: live transfer leads',       'Fake Transfers LLC',  'seed', 'seed-s2-04'),
  ('2026-10-06', 'marketing',       150.00, 'FAKE seed: social ads test',           'Fake Social Ads',     'seed', 'seed-s2-05'),
  ('2026-10-07', 'dialer_software',  97.00, 'FAKE seed: CRM subscription',          'Fake CRM SaaS',       'seed', 'seed-s2-06'),
  ('2026-10-08', 'other',            15.00, 'FAKE seed: bank fee',                  'Fake Bank',           'seed', 'seed-s2-07'),
  ('2026-10-09', 'payroll_spiffs',  180.00, 'FAKE seed: spiffs, week of 10/04',     null,                  'seed', 'seed-s2-08'),
  ('2026-10-12', 'lead_spend',      425.00, 'FAKE seed: live transfer leads',       'Fake Transfers LLC',  'seed', 'seed-s2-09'),
  ('2026-10-13', 'office',          129.99, 'FAKE seed: internet + phones',         'Fake Telecom',        'seed', 'seed-s2-10'),
  ('2026-10-14', 'marketing',        85.50, 'FAKE seed: flyer print run',           'Fake Print Shop',     'seed', 'seed-s2-11'),
  ('2026-10-15', 'dialer_software',  60.00, 'FAKE seed: phone number pool',         'Fake Dialer Co',      'seed', 'seed-s2-12'),
  ('2026-10-16', 'payroll_spiffs',  220.00, 'FAKE seed: spiffs, week of 10/11',     null,                  'seed', 'seed-s2-13'),
  ('2026-10-19', 'lead_spend',      375.00, 'FAKE seed: live transfer leads',       'Fake Transfers LLC',  'seed', 'seed-s2-14'),
  ('2026-10-20', 'office',           42.37, 'FAKE seed: office supplies',           'Fake Supply Store',   'seed', 'seed-s2-15'),
  ('2026-10-21', 'marketing',       150.00, 'FAKE seed: social ads test',           'Fake Social Ads',     'seed', 'seed-s2-16'),
  ('2026-10-22', 'dialer_software',  25.00, 'FAKE seed: e-sign tool',               'Fake eSign',          'seed', 'seed-s2-17'),
  ('2026-10-23', 'payroll_spiffs',  160.00, 'FAKE seed: spiffs, week of 10/18',     null,                  'seed', 'seed-s2-18'),
  ('2026-10-24', 'lead_spend',       90.00, 'FAKE seed: weekend aged leads',        'Fake Leads Inc',      'seed', 'seed-s2-19'),
  ('2026-10-24', 'other',            30.00, 'FAKE seed: parking',                   null,                  'seed', 'seed-s2-20')
on conflict (source, external_ref) where external_ref is not null do nothing;
