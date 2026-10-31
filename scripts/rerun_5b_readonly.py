"""Slice-one check 5b, re-run READ-ONLY (GET requests only) on 2026-10-31.
weekly_pl is admin-only (security_invoker + is_admin()), so a service-role GET returns 0 rows and there is no admin
session available without writing (test passwords are not on the box any more, and creating a throwaway admin is a write).
So 5b is re-run two ways, both read-only:
  (a) the live weekly_pl response captured on the first run (results.json) evaluated against the CORRECTED expected value;
  (b) a fresh service-role GET of the raw live rows (sales_commission + expenses), recomputing weekly_pl's formula for
      the week of Sun 2026-10-25, against the same corrected expected value. The weekly_pl GET is also recorded.
Never prints key values.
"""
import ast, json, urllib.request, urllib.error
from datetime import date, timedelta
E = {}
for l in open('/workspace/secrets/supabase.env'):
    l = l.strip()
    if l and not l.startswith('#') and '=' in l: k, v = l.split('=', 1); E[k] = v.strip().strip('"')
URL = E['SUPABASE_URL'].rstrip('/'); SVC = E['SUPABASE_SERVICE_ROLE_KEY']
def get(path):
    r = urllib.request.Request(URL + '/rest/v1/' + path, method='GET', headers={'apikey': SVC, 'Authorization': 'Bearer ' + SVC})
    try:
        with urllib.request.urlopen(r, timeout=20) as x: return x.status, json.load(x)
    except urllib.error.HTTPError as e: return e.code, e.read().decode()[:200]
EXPECTED = (5, 560.0, 218.8, 574.0, -232.8)   # sales, premium_total, agent_commission, expenses, net_placeholder
out = {'run_at': '2026-10-31 (ET)', 'mode': 'read-only GETs', 'expected_5b': EXPECTED, 'checks': []}
def rec(name, ok, detail):
    out['checks'].append({'check': name, 'pass': bool(ok), 'detail': detail}); print('PASS' if ok else 'FAIL', '|', name, '|', detail)

first = {r[0]: r for r in json.load(open('/workspace/liveverify/results.json'))}
row = next(v for k, v in first.items() if k.startswith('5b.'))
w = ast.literal_eval(row[2])
got_a = (w['sales_count'], float(w['premium_total']), float(w['agent_commission']), float(w['expenses']), float(w['net_placeholder']))
rec('5b(a). first-run live weekly_pl 10/25 vs corrected expected (5, 560.00, 218.80, 574.00, -232.80)', got_a == EXPECTED, got_a)

s0, wv = get('weekly_pl?week_start=eq.2026-10-25')
s1, sc = get('sales_commission?select=id,sale_date,board_premium,premier_premium,commission_estimate')
s2, ex = get('expenses?select=date,amount')
ws = lambda d: (lambda x: (x - timedelta(days=(x.weekday() + 1) % 7)).isoformat())(date.fromisoformat(d))
wk = [x for x in sc if ws(x['sale_date']) == '2026-10-25'] if s1 == 200 else []
prem = round(sum(float(x['premier_premium'] if x['premier_premium'] is not None else x['board_premium'] or 0) for x in wk), 2)
com = round(sum(float(x['commission_estimate'] or 0) for x in wk), 2)
exp = round(sum(float(e['amount']) for e in ex if ws(e['date']) == '2026-10-25'), 2) if s2 == 200 else None
got_b = (len(wk), prem, com, exp, round(prem - com - (exp or 0), 2))
rec('5b(b). fresh read-only recompute from live rows (weekly_pl formula) vs corrected expected', s1 == 200 and s2 == 200 and got_b == EXPECTED,
    {'recomputed': got_b, 'GET sales_commission': s1, 'GET expenses': s2,
     'GET weekly_pl as service_role': f'HTTP {s0}, rows={len(wv) if isinstance(wv, list) else wv} (admin-only view: 0 rows expected)'})
json.dump(out, open('/workspace/liveverify/results_5b_rerun.json', 'w'), indent=1)
