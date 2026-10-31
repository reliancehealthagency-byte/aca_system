"""Slice two live verification (line-item P&L) over HTTPS REST/Auth. Run AFTER slice2_paste.sql is applied.

DEFAULT = READ-ONLY. Nothing is written to the live project:
  - service-role GETs check the data (expenses, categories, adjustments, config, sales) and recompute the expected
    P&L from raw rows; the P&L views are checked for existence (they return 0 rows to service_role by design,
    because they require is_admin()).
  - anon-key GETs check that nothing is readable.
  View math, RLS-as-user and chargeback behavior are covered by supabase/tests/verify_slice2.sql (local, rolled back).

--allow-writes = also runs the user-level tests, which WRITE to live:
  - 2 throwaway auth users (verify-<tag>-admin/agent@example.com) + 2 agents rows (display_name 'VERIFY ...'),
  - 1 revenue_adjustments row (description 'VERIFY ...', a -25.00 chargeback),
  - 1 rejected expense insert (unknown category; fails, writes nothing).
  Every row written is tagged VERIFY. Cleanup runs in a finally block and DELETES this run's rows plus any leftover
  VERIFY-tagged expenses / revenue_adjustments / agents rows and verify-*@example.com auth users, then confirms none remain.
  The event log keeps the audit rows for these writes (append-only by design).
Never prints key or password values.
"""
import argparse, json, os, secrets, sys, urllib.request, urllib.error, urllib.parse
from datetime import date, timedelta

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('--allow-writes', action='store_true', help='also run user-level tests that create and delete VERIFY-tagged rows on live')
ARGS = ap.parse_args()
def envf(p):
    d = {}
    for l in open(p):
        l = l.strip()
        if l and not l.startswith('#') and '=' in l:
            k, v = l.split('=', 1); d[k] = v.strip().strip('"')
    return d
E = envf('/workspace/secrets/supabase.env')
URL = E['SUPABASE_URL'].rstrip('/'); ANON = E['SUPABASE_ANON_KEY']; SVC = E['SUPABASE_SERVICE_ROLE_KEY']
SECRETS = [v for v in E.values() if len(v) > 12]
def scrub(s):
    s = str(s)
    for v in SECRETS: s = s.replace(v, '***')
    return s
def req(method, path, key, bearer=None, body=None, headers=None):
    h = {'apikey': key, 'Authorization': 'Bearer ' + (bearer or key), 'Content-Type': 'application/json'}
    h.update(headers or {})
    r = urllib.request.Request(URL + path, method=method, headers=h,
                               data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            t = resp.read().decode(); return resp.status, (json.loads(t) if t else None), resp.headers
    except urllib.error.HTTPError as e:
        t = e.read().decode()
        try: return e.code, json.loads(t), e.headers
        except Exception: return e.code, t, e.headers
R = []
def rec(name, ok, detail=''):
    R.append({'check': name, 'pass': bool(ok), 'detail': scrub(detail)})
    print(('PASS' if ok else 'FAIL'), '|', name, '|', scrub(detail)); sys.stdout.flush()
def get(path, bearer=None, key=None):
    s, b, _ = req('GET', '/rest/v1/' + path, key or ANON, bearer); return s, b
def svc(path):
    return get(path, key=SVC)
def money(x): return round(float(x or 0), 2)

NEW_TABLES = ['expense_categories', 'revenue_adjustments']
NEW_VIEWS = ['pl_line_items', 'pl_daily', 'pl_weekly', 'pl_monthly', 'pl_unpriced_sales']
print('mode:', 'READ-ONLY + WRITE TESTS (--allow-writes)' if ARGS.allow_writes else 'READ-ONLY (no writes to live)')

# ---------- 1. data (service role, GET only) ----------
s, exp = svc('expenses?select=id,date,category,amount,description,source,vendor,external_ref,created_by&order=date')
rec('1a. expenses reachable with new columns (source, vendor, external_ref, created_by)', s == 200 and exp and all('source' in e for e in exp),
    f'HTTP {s}' + (f' {exp.get("code")} {exp.get("message")} (before slice two is applied this 400/42703 is expected)' if isinstance(exp, dict) else ''))
exp = exp if isinstance(exp, list) else []
old = sorted([e for e in exp if (e.get('external_ref') or '').startswith('seed-s1-')], key=lambda e: e['external_ref'])
new = [e for e in exp if (e.get('external_ref') or '').startswith('seed-s2-')]
rec('1b. 24 expense lines (4 seed-s1 + 20 seed-s2), none without external_ref', len(exp) == 24 and len(old) == 4 and len(new) == 20 and all(e.get('external_ref') for e in exp),
    f'total={len(exp)} s1={len(old)} s2={len(new)} no_ref={sum(1 for e in exp if not e.get("external_ref"))}')
rec('1c. slice-one rows kept + remapped: seed-s1-01..03 lead_spend 200/175/150, seed-s1-04 dialer_software 49, source=seed',
    [(e['external_ref'], e['category'], money(e['amount'])) for e in old] == [('seed-s1-01', 'lead_spend', 200.0), ('seed-s1-02', 'lead_spend', 175.0),
     ('seed-s1-03', 'lead_spend', 150.0), ('seed-s1-04', 'dialer_software', 49.0)] and all(e['source'] == 'seed' for e in old),
    [(e['external_ref'], e['date'], e['category'], e['amount'], e['source']) for e in old])
rec('1d. slice-two seed: 20 lines totalling 4384.86, dated 2026-10-01..10-24',
    len(new) == 20 and round(sum(money(e['amount']) for e in new), 2) == 4384.86 and all('2026-10-01' <= e['date'] <= '2026-10-24' for e in new),
    f'rows={len(new)} total={round(sum(money(e["amount"]) for e in new), 2)}')
s, cats = svc('expense_categories?select=code&order=sort_order')
rec('1e. 6 expense categories', s == 200 and [c['code'] for c in cats] == ['lead_spend', 'dialer_software', 'payroll_spiffs', 'office', 'marketing', 'other'],
    f'HTTP {s} {[c["code"] for c in cats] if isinstance(cats, list) else cats}')
s, ra = svc('revenue_adjustments?select=id')
rec('1f. revenue_adjustments exists and is empty', s == 200 and ra == [], f'HTTP {s} rows={len(ra) if isinstance(ra, list) else ra}')
s, cfg = svc('commission_config?select=base_rate,addon_bonus_rate')
rec('1g. commission_config unchanged (0.38 / 0.05)', s == 200 and money(cfg[0]['base_rate']) == 0.38 and money(cfg[0]['addon_bonus_rate']) == 0.05, cfg)
st = {}
for v in NEW_VIEWS:
    s, b = svc(f'{v}?select=*&limit=1'); st[v] = (s, len(b) if isinstance(b, list) else b)
rec('1h. all 5 P&L views exist; service_role gets 0 rows (admin-only filter)', all(x == (200, 0) for x in st.values()), st)

# Recompute the expected P&L from raw rows (service role sees sales_commission: RLS bypassed, no is_admin() filter there).
s, sc = svc('sales_commission?select=id,sale_date,board_premium,premier_premium,commission_estimate')
sc = sc if isinstance(sc, list) else []
def wk(d): x = date.fromisoformat(d); return (x - timedelta(days=(x.weekday() + 1) % 7)).isoformat()
def agg(pred):
    rev = sum(money(x['premier_premium'] if x['premier_premium'] is not None else x['board_premium']) for x in sc
              if pred(x['sale_date']) and (x['premier_premium'] is not None or x['board_premium'] is not None))
    com = sum(money(x['commission_estimate']) for x in sc if pred(x['sale_date']) and x['commission_estimate'] is not None)
    ex = sum(money(e['amount']) for e in exp if pred(e['date']))
    return (round(rev, 2), round(com, 2), round(ex, 2), round(rev - com - ex, 2))
got = {'Oct 2026': agg(lambda d: d.startswith('2026-10')), 'week 10/25': agg(lambda d: wk(d) == '2026-10-25'), 'day 10/31': agg(lambda d: d == '2026-10-31'),
       'week 9/27': agg(lambda d: wk(d) == '2026-09-27'), 'week 10/04': agg(lambda d: wk(d) == '2026-10-04'),
       'week 10/11': agg(lambda d: wk(d) == '2026-10-11'), 'week 10/18': agg(lambda d: wk(d) == '2026-10-18')}
want = {'Oct 2026': (560.0, 218.8, 4958.86, -4617.66), 'week 10/25': (560.0, 218.8, 574.0, -232.8), 'day 10/31': (110.0, 41.8, 199.0, -130.8),
        'week 9/27': (0, 0, 1750.0, -1750.0), 'week 10/04': (0, 0, 842.0, -842.0), 'week 10/11': (0, 0, 920.49, -920.49), 'week 10/18': (0, 0, 872.37, -872.37)}
rec('1i. P&L recomputed from raw live rows matches expected (rev, commission, expenses, net)', s == 200 and got == want, got)
unpriced = [x['id'] for x in sc if x['premier_premium'] is None and x['board_premium'] is None]
rec('1j. no unpriced sales in live data (pl_unpriced_sales should be empty)', s == 200 and len(sc) == 5 and not unpriced, f'sales={len(sc)} unpriced={len(unpriced)}')

# ---------- 2. anon (GET only) ----------
bad = {}
for t in NEW_TABLES + NEW_VIEWS + ['expenses']:
    s, b = get(f'{t}?select=*&limit=5')
    if s in (200, 206) and b: bad[t] = f'{s} rows={len(b)}'
    elif s not in (200, 206, 401, 403, 404): bad[t] = s
rec('2. anon reads nothing from new tables/views', not bad, bad or 'all blocked')

# ---------- 3+. write tests (opt-in) ----------
TAG = 'VERIFY'
tag = secrets.token_hex(4)
temp = {'admin': {'email': f'verify-{tag}-admin@example.com', 'role': 'admin'},
        'agent': {'email': f'verify-{tag}-agent@example.com', 'role': 'agent'}}
def cleanup():
    """Runs in finally (only in --allow-writes mode). DELETES everything this script could have written, plus any
    leftover VERIFY-tagged rows from earlier runs, then confirms nothing is left:
      revenue_adjustments.description like 'VERIFY%', expenses.description like 'VERIFY%',
      agents rows with display_name like 'VERIFY%' and email like 'verify-%@example.com',
      auth users with email like 'verify-%@example.com' (this run's two plus any leftovers)."""
    q = urllib.parse.quote
    s_ra, _, _ = req('DELETE', f'/rest/v1/revenue_adjustments?description=like.{TAG}*', SVC)
    s_ex, _, _ = req('DELETE', f'/rest/v1/expenses?description=like.{TAG}*', SVC)
    for k, u in temp.items():
        if u.get('agent_id'): req('DELETE', f'/rest/v1/agents?id=eq.{u["agent_id"]}', SVC)
    s_ag, _, _ = req('DELETE', f'/rest/v1/agents?display_name=like.{TAG}*&email=like.verify-*', SVC)
    uids = {u['uid'] for u in temp.values() if u.get('uid')}
    s_l, lst, _ = req('GET', '/auth/v1/admin/users?page=1&per_page=1000', SVC)
    users = (lst or {}).get('users', []) if isinstance(lst, dict) else []
    uids |= {x['id'] for x in users if (x.get('email') or '').startswith('verify-') and (x.get('email') or '').endswith('@example.com')}
    for uid in uids:
        req('DELETE', f'/auth/v1/admin/users/{uid}', SVC)
    gone = []
    for uid in uids:
        s2, _, _ = req('GET', f'/auth/v1/admin/users/{uid}', SVC); gone.append(s2 == 404)
    s_l2, lst2, _ = req('GET', '/auth/v1/admin/users?page=1&per_page=1000', SVC)
    left_u = [x['id'] for x in ((lst2 or {}).get('users', []) if isinstance(lst2, dict) else []) if (x.get('email') or '').startswith('verify-')]
    _, left_a = svc('agents?select=id&email=like.verify-*')
    _, left_r = svc(f'revenue_adjustments?select=id&description=like.{TAG}*')
    _, left_e = svc(f'expenses?select=id&description=like.{TAG}*')
    ok = all(gone) and not left_u and left_a == [] and left_r == [] and left_e == []
    rec('9. cleanup: VERIFY adjustments, expenses, agents rows and verify-* auth users deleted, none left', ok,
        f'deletes: adjustments {s_ra}, expenses {s_ex}, agents {s_ag}, auth users {len(uids)} (list {s_l}); '
        f'left: users {len(left_u)}, agents {len(left_a or [])}, adjustments {len(left_r or [])}, expenses {len(left_e or [])}')

if not ARGS.allow_writes:
    print('\nskipped write tests (throwaway users, chargeback, FK insert). Re-run with --allow-writes to include them.')
else:
  try:
    s, b, _ = req('POST', '/rest/v1/expenses', SVC, body={'date': '2026-10-31', 'category': 'not_a_category', 'amount': 1,
                  'description': f'{TAG} unknown category (must be rejected)'}, headers={'Prefer': 'return=minimal'})
    rec('3a. unknown category rejected by lookup FK', s in (400, 409) and isinstance(b, dict) and b.get('code') == '23503', f'HTTP {s} {b.get("code") if isinstance(b, dict) else b}')
    for k, u in temp.items():
        u['pw'] = secrets.token_urlsafe(24)
        s, b, _ = req('POST', '/auth/v1/admin/users', SVC, body={'email': u['email'], 'password': u['pw'], 'email_confirm': True,
                      'user_metadata': {'purpose': f'{TAG} slice2 throwaway'}})
        u['uid'] = b.get('id') if isinstance(b, dict) else None
        s2, b2, _ = req('POST', '/rest/v1/agents', SVC, body={'display_name': f'{TAG} {k} {tag} (fake)', 'email': u['email'],
                        'role': u['role'], 'user_id': u['uid']}, headers={'Prefer': 'return=representation'})
        u['agent_id'] = b2[0]['id'] if isinstance(b2, list) and b2 else None
        s3, b3, _ = req('POST', '/auth/v1/token?grant_type=password', ANON, body={'email': u['email'], 'password': u['pw']})
        u['tok'] = b3.get('access_token') if isinstance(b3, dict) else None
        rec(f'3b.{k}. throwaway {k} user created, linked and signed in', u['uid'] and u['agent_id'] and u['tok'], f'create {s}, agents {s2}, login {s3}')
    A = temp['admin']['tok']; G = temp['agent']['tok']

    # admin: P&L values
    s, m = get('pl_monthly?month_start=eq.2026-10-01', A)
    m = m[0] if isinstance(m, list) and m else {}
    rec('4a. Oct 2026: revenue 560.00, commission 218.80, expenses 4958.86, net -4617.66, 35 lines, 5 sales',
        (money(m.get('revenue')), money(m.get('commission')), money(m.get('expenses')), money(m.get('net')), m.get('line_count'), m.get('sales_count'))
        == (560.0, 218.8, 4958.86, -4617.66, 35, 5), f'HTTP {s} {m}')
    s, w = get('pl_weekly?select=*&order=week_start', A)
    wkrows = {x['week_start']: x for x in (w if isinstance(w, list) else [])}
    exp_w = {'2026-09-27': (0, 0, 1750.00, -1750.00), '2026-10-04': (0, 0, 842.00, -842.00), '2026-10-11': (0, 0, 920.49, -920.49),
             '2026-10-18': (0, 0, 872.37, -872.37), '2026-10-25': (560.00, 218.80, 574.00, -232.80)}
    got_w = {k: (money(v['revenue']), money(v['commission']), money(v['expenses']), money(v['net'])) for k, v in wkrows.items()}
    rec('4b. weekly (Sun start) matches expected for all 5 October weeks', all(got_w.get(k) == v for k, v in exp_w.items()), got_w)
    s, d = get('pl_daily?day=eq.2026-10-31', A)
    d = d[0] if isinstance(d, list) and d else {}
    rec('4c. today 10/31: revenue 110.00, commission 41.80, expenses 199.00, net -130.80',
        (money(d.get('revenue')), money(d.get('commission')), money(d.get('expenses')), money(d.get('net'))) == (110.0, 41.8, 199.0, -130.8), f'HTTP {s} {d}')
    s, li = get('pl_line_items?select=*&week_start=eq.2026-10-25', A)
    li = li if isinstance(li, list) else []
    rec('4d. week 10/25 drill-down: 15 lines summing to net -232.80',
        len(li) == 15 and round(sum(money(x['signed_amount']) for x in li), 2) == -232.80, f'lines={len(li)} sum={round(sum(money(x["signed_amount"]) for x in li), 2)}')
    split = {x['category']: money(x['amount']) for x in li if x['ref_id'] == '00000000-0000-4000-8000-00000005a002' and x['line_type'] == 'commission'}
    rec('4e. 10/27 Wellness4You sale commission split: base 45.60 + add-on bonus 6.00', split == {'agent_commission_base': 45.6, 'agent_commission_addon_bonus': 6.0}, split)
    s, ml = get('pl_line_items?select=line_type,category,amount&month_start=eq.2026-10-01', A)
    bycat = {}
    for x in (ml if isinstance(ml, list) else []):
        bycat[(x['line_type'], x['category'])] = round(bycat.get((x['line_type'], x['category']), 0) + money(x['amount']), 2)
    exp_cat = {('revenue', 'premium_premier'): 470.0, ('revenue', 'premium_board_claim'): 90.0,
               ('commission', 'agent_commission_base'): 212.8, ('commission', 'agent_commission_addon_bonus'): 6.0,
               ('expense', 'lead_spend'): 2065.0, ('expense', 'dialer_software'): 531.0, ('expense', 'payroll_spiffs'): 560.0,
               ('expense', 'office'): 1372.36, ('expense', 'marketing'): 385.5, ('expense', 'other'): 45.0}
    rec('4f. Oct category totals', bycat == exp_cat, {f'{a}/{b}': v for (a, b), v in sorted(bycat.items())})
    s, old_w = get('weekly_pl?select=*', A)
    mism = [x['week_start'] for x in (old_w if isinstance(old_w, list) else [])
            if (money(x['premium_total']), money(x['agent_commission']), money(x['expenses']), money(x['net_placeholder']))
            != (got_w.get(x['week_start']) or ())]
    rec('4g. new pl_weekly equals slice-one weekly_pl (no revenue adjustments yet)', s == 200 and not mism and len(old_w) == len(got_w), f'mismatches={mism}')
    s, ev = get('event_log?select=id&table_name=eq.expenses&action=eq.UPDATE&before->>category=eq.Leads&after->>category=eq.lead_spend', A)
    rec('4h. category remap of slice-one rows is in the event log', s == 200 and isinstance(ev, list) and len(ev) == 3, f'HTTP {s} rows={len(ev) if isinstance(ev, list) else ev}')
    s, ev = get('event_log?select=id&table_name=eq.expense_categories&action=eq.INSERT', A)
    rec('4i. expense_categories inserts audited (6)', s == 200 and isinstance(ev, list) and len(ev) == 6, f'HTTP {s} rows={len(ev) if isinstance(ev, list) else ev}')
    # admin write round-trip on revenue_adjustments (audited), then delete
    s, b, _ = req('POST', '/rest/v1/revenue_adjustments', ANON, A, {'date': '2026-10-31', 'category': 'chargeback', 'amount': -25.00,
                  'description': f'{TAG} fake chargeback (deleted by script)', 'source': 'manual'}, {'Prefer': 'return=representation'})
    raid = b[0]['id'] if isinstance(b, list) and b else None
    s2, d2 = get('pl_daily?day=eq.2026-10-31', A); d2 = d2[0] if isinstance(d2, list) and d2 else {}
    s3, _, _ = req('DELETE', f'/rest/v1/revenue_adjustments?id=eq.{raid}', ANON, A)
    s4, ev = get(f'event_log?select=action&table_name=eq.revenue_adjustments&row_id=eq.{raid}', A)
    rec('4j. admin -25.00 chargeback shows as revenue line (today net -155.80), then deleted, both audited',
        raid and money(d2.get('net')) == -155.80 and s3 in (200, 204) and sorted(x['action'] for x in (ev or [])) == ['DELETE', 'INSERT'],
        f'insert {s}, net={d2.get("net")}, delete {s3}, events={[x["action"] for x in (ev or [])]}')

    # agent: nothing new visible, no own sales (throwaway has none), no writes
    res = {}
    for t in NEW_TABLES + NEW_VIEWS + ['expenses', 'daily_pl', 'weekly_pl', 'monthly_pl', 'event_log', 'commission_config']:
        s, b = get(f'{t}?select=*&limit=5', G); res[t] = (s, len(b) if isinstance(b, list) else b)
    rec('5a. agent sees 0 rows in expenses, categories, adjustments, all P&L views, config, event_log',
        all(v[0] in (200, 206) and v[1] == 0 for v in res.values()), res)
    s, b = get('sales?select=id', G); s_svc, b_svc = svc('sales?select=id')
    rec('5b. agent sees only own sales (throwaway agent owns none: 0 of 5)', s == 200 and b == [] and len(b_svc) == 5, f'agent={len(b) if isinstance(b, list) else b} total={len(b_svc)}')
    s, b, _ = req('POST', '/rest/v1/expenses', ANON, G, {'date': '2026-10-31', 'category': 'other', 'amount': 1, 'description': f'{TAG} agent write (must be rejected)'})
    rec('5c. agent cannot insert expenses', s in (401, 403), f'HTTP {s} {b.get("code") if isinstance(b, dict) else b}')
    s, b, _ = req('POST', '/rest/v1/revenue_adjustments', ANON, G, {'date': '2026-10-31', 'category': 'other_revenue', 'amount': 1, 'description': f'{TAG} agent write (must be rejected)'})
    rec('5d. agent cannot insert revenue adjustments', s in (401, 403), f'HTTP {s} {b.get("code") if isinstance(b, dict) else b}')
    s, u = get('pl_unpriced_sales?select=sale_id', A)
    rec('5e. admin: pl_unpriced_sales readable and empty for the seed', s == 200 and u == [], f'HTTP {s} rows={len(u) if isinstance(u, list) else u}')
  finally:
    cleanup()

json.dump(R, open('/workspace/liveverify/results_slice2.json', 'w'), indent=1)
print(f"\n{sum(r['pass'] for r in R)}/{len(R)} passed")
