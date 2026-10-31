import json, os, urllib.request, urllib.error
def envf(p):
    d={}
    for l in open(p):
        l=l.strip()
        if l and not l.startswith('#') and '=' in l:
            k,v=l.split('=',1); d[k]=v.strip().strip('"')
    return d
E=envf('/workspace/secrets/supabase.env'); T=envf('/workspace/secrets/test_users.env')
URL=E['SUPABASE_URL'].rstrip('/'); ANON=E['SUPABASE_ANON_KEY']; SVC=E['SUPABASE_SERVICE_ROLE_KEY']
SECRETS=[v for v in list(E.values())+list(T.values()) if len(v)>12]
def scrub(s):
    s=str(s)
    for v in SECRETS: s=s.replace(v,'***')
    return s
def req(method, path, key, bearer=None, body=None, headers=None):
    h={'apikey':key,'Authorization':'Bearer '+(bearer or key),'Content-Type':'application/json'}
    h.update(headers or {})
    r=urllib.request.Request(URL+path, method=method, headers=h, data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(r, timeout=20) as resp:
            t=resp.read().decode(); return resp.status, (json.loads(t) if t else None), resp.headers
    except urllib.error.HTTPError as e:
        t=e.read().decode()
        try: return e.code, json.loads(t), e.headers
        except Exception: return e.code, t, e.headers
def login(email,pw):
    s,b,_=req('POST','/auth/v1/token?grant_type=password',ANON,body={'email':email,'password':pw})
    return s,(b.get('access_token') if isinstance(b,dict) else None),(b.get('user',{}).get('id') if isinstance(b,dict) else None)
R=[]
def rec(name, ok, detail=''):
    R.append((name, bool(ok), scrub(detail))); print(('PASS' if ok else 'FAIL'), '|', name, '|', scrub(detail))
def cnt(path, key, bearer=None):
    s,b,h=req('GET', path, key, bearer, headers={'Prefer':'count=exact','Range':'0-999'})
    c=h.get('Content-Range','') if h else ''
    return s,b,(c.split('/')[-1] if '/' in c else None)

TABLES=['agents','contacts','applications','sales','call_metrics','expenses','commission_config','event_log']
VIEWS=['sales_commission','daily_pl','weekly_pl','monthly_pl']
# 1 existence + counts via service key
counts={}
for t in TABLES+VIEWS:
    s,b,c=cnt(f'/rest/v1/{t}?select=*', SVC); counts[t]=(s,c)
exp={'contacts':'10','sales':'5','applications':'5','call_metrics':'5','expenses':'4','commission_config':'1','agents':'3'}
ok=all(counts[t][0] in (200,206) for t in TABLES+VIEWS)
rec('1a. all 8 tables + 4 views reachable (service key)', ok, {t:counts[t][0] for t in TABLES+VIEWS})
rec('1b. seed counts', all(counts[t][1]==v for t,v in exp.items()), {t:counts[t][1] for t in exp})
# 2 anon
bad={}
for t in TABLES+VIEWS:
    s,b,_=req('GET',f'/rest/v1/{t}?select=*&limit=5',ANON)
    if s in (200,206) and b: bad[t]=f'{s} rows={len(b)}'
    elif s not in (200,206,401,403,404): bad[t]=s
    counts[t+'_anon']=(s, (b.get('code') if isinstance(b,dict) else len(b) if isinstance(b,list) else b))
rec('2a. anon reads nothing from any table/view', not bad, bad or {t:counts[t+'_anon'] for t in TABLES+VIEWS})
for fn in ['commission_rates','is_admin','current_agent_id']:
    s,b,_=req('POST',f'/rest/v1/rpc/{fn}',ANON,body={})
    rec(f'2b. anon cannot call rpc {fn}()', s in (401,403,404), f'HTTP {s} {b.get("code") if isinstance(b,dict) else b} {b.get("message") if isinstance(b,dict) else ""}')
# 3 users
sA,adm,admid=login(T['TEST_ADMIN_EMAIL'],T['TEST_ADMIN_PASSWORD'])
sG,agt,agtid=login(T['TEST_AGENT_EMAIL'],T['TEST_AGENT_PASSWORD'])
rec('3a. admin + agent sign in (email/password)', sA==200 and sG==200, f'admin {sA}, agent {sG}')
s,b,_=req('GET','/rest/v1/agents?select=display_name,email,role,user_id',SVC)
link={a['email']:(a['role'], a['user_id']) for a in b}
rec('3b. seed linked test users to agent rows', link.get('admin.test@example.com',(0,0))[1]==admid and link.get('agent.test@example.com',(0,0))[1]==agtid and admid and agtid,
    {e:(r, 'linked' if u else 'NOT linked') for e,(r,u) in link.items()})
s,b,c=cnt('/rest/v1/sales?select=id,agent_of_record',ANON,agt)
others=[x for x in (b or []) if x['agent_of_record']!='00000000-0000-4000-8000-00000000a002']
rec('3c. agent sees only own sales', s in (200,206) and c=='3' and not others, f'HTTP {s} visible={c} others={len(others)}')
s,b,c=cnt('/rest/v1/contacts?select=id',ANON,agt); rec('3d. agent sees only contacts on own sales (3)', c=='3', f'HTTP {s} visible={c}')
res={}
for t in ['expenses','daily_pl','weekly_pl','monthly_pl','commission_config','event_log']:
    s,b,c=cnt(f'/rest/v1/{t}?select=*',ANON,agt); res[t]=(s,c)
rec('3e. agent sees nothing in expenses / P&L / config / event_log', all(v[1] in ('0',None) and v[0] in (200,206) for v in res.values()), res)
s,b,_=req('PATCH','/rest/v1/sales?id=eq.00000000-0000-4000-8000-00000005a001',ANON,agt,{'board_premium':999},{'Prefer':'return=representation'})
rec('3f. agent cannot edit sales', (s in (200,204) and not b) or s in (401,403), f'HTTP {s} rows changed={len(b) if isinstance(b,list) else b}')
s,b,c=cnt('/rest/v1/sales?select=id',ANON,adm); rec('3g. admin sees all 5 sales', c=='5', f'HTTP {s} visible={c}')
# 4 commission
s,b,_=req('GET','/rest/v1/sales_commission?select=id,agent_name,sale_date,board_premium,premier_premium,commission_rate,commission,commission_estimate,premium_source,commission_pay_friday&order=sale_date',ANON,adm)
by={x['id'][-4:]:x for x in b}
print(json.dumps(b,indent=0))
rec('4a. 38% base: $100 -> $38.00', float(by['a001']['commission_rate'])==0.38 and float(by['a001']['commission'])==38.0, by['a001']['commission'])
rec('4b. 43% with Wellness4You: $120 -> $51.60', float(by['a002']['commission_rate'])==0.43 and float(by['a002']['commission'])==51.6, by['a002']['commission'])
rec('4c. mismatch sale paid on Premier $140 -> $53.20, agent unchanged', float(by['a003']['commission'])==53.2 and by['a003']['agent_name']=='Blair Sample (fake)', by['a003']['commission'])
rec('4d. post-dated pending: estimate $34.20, pays 2026-11-13', by['a004']['commission'] is None and float(by['a004']['commission_estimate'])==34.2 and by['a004']['commission_pay_friday']=='2026-11-13', (by['a004']['commission_estimate'],by['a004']['commission_pay_friday']))
s,b,_=req('GET','/rest/v1/sales_commission?select=commission&id=eq.00000000-0000-4000-8000-00000005a002',ANON,agt)
rec('4e. agent gets derived commission on own sale ($51.60)', b and float(b[0]['commission'])==51.6, b)
# 5 P&L
s,d,_=req('GET','/rest/v1/daily_pl?day=eq.2026-10-31',ANON,adm)
s2,w,_=req('GET','/rest/v1/weekly_pl?week_start=eq.2026-10-25',ANON,adm)
dd=d[0] if d else {}; ww=w[0] if w else {}
rec('5a. daily_pl 2026-10-31 = 1 sale, $110, $41.80, $199, net -$130.80',
    dd and (dd['sales_count'],float(dd['premium_total']),float(dd['agent_commission']),float(dd['expenses']),float(dd['net_placeholder']))==(1,110.0,41.8,199.0,-130.8), dd)
# 5b expected corrected 10/31: the seed math is 100+120+140+90+110 = 560 premium and 38+51.60+53.20+34.20+41.80 = 218.80
# commission (post-dated 10/30 sale uses the board-claim estimate), net 560-218.80-574 = -232.80. The old 565/220.70 came
# from local verify.sql reading the week AFTER its 9b step set a Premier premium of 95 on that sale.
rec('5b. weekly_pl 10/25 = 5 sales, $560, $218.80, $574, net -$232.80',
    ww and (ww['sales_count'],float(ww['premium_total']),float(ww['agent_commission']),float(ww['expenses']),float(ww['net_placeholder']))==(5,560.0,218.8,574.0,-232.8), ww)
# 6 event log
s,b,c=cnt('/rest/v1/event_log?select=id&event_type=eq.row.insert',ANON,adm)
rec('6a. seed insert events present (admin read)', c and int(c)>=32, f'row.insert events={c}')
s,b,_=req('GET','/rest/v1/event_log?select=row_id,detail,actor_role&event_type=eq.premium_mismatch',ANON,adm)
rec('6b. premium_mismatch event for seeded sale (diff -10.00)', any(x['row_id'].endswith('5a003') and float(x['detail']['diff'])==-10.0 for x in b), b)
# 7 live insert/update audit as admin
s,b,_=req('POST','/rest/v1/expenses',ANON,adm,{'category':'Verification','amount':1.00,'date':'2026-10-31','description':'VERIFY TEST - safe to ignore'},{'Prefer':'return=representation'})
eid=b[0]['id'] if s==201 else None
rec('7a. admin inserts VERIFY TEST expense', eid, f'HTTP {s}')
s,b,_=req('PATCH',f'/rest/v1/expenses?id=eq.{eid}',ANON,adm,{'amount':2.00},{'Prefer':'return=representation'})
rec('7b. admin updates it (1.00 -> 2.00)', s==200 and b and float(b[0]['amount'])==2.0, f'HTTP {s}')
s,b,_=req('GET',f'/rest/v1/event_log?select=id,action,actor_uid,actor_role,before,after,changed_fields&table_name=eq.expenses&row_id=eq.{eid}&order=id',ANON,adm)
ins=[x for x in b if x['action']=='INSERT']; upd=[x for x in b if x['action']=='UPDATE']
rec('7c. INSERT event with after + actor', ins and ins[0]['before'] is None and ins[0]['after']['description']=='VERIFY TEST - safe to ignore' and ins[0]['actor_uid']==admid,
    ins and {'actor_role':ins[0]['actor_role'],'actor_is_admin_uid':ins[0]['actor_uid']==admid})
rec('7d. UPDATE event with before/after + changed_fields', upd and float(upd[0]['before']['amount'])==1.0 and float(upd[0]['after']['amount'])==2.0 and upd[0]['changed_fields']==['amount'],
    upd and upd[0]['changed_fields'])
evid=ins[0]['id'] if ins else None
for who,k,bt in [('admin',ANON,adm),('service key',SVC,None)]:
    s,b,_=req('PATCH',f'/rest/v1/event_log?id=eq.{evid}',k,bt,{'table_name':'tampered'},{'Prefer':'return=representation'})
    rec(f'7e. event_log UPDATE rejected ({who})', s in (401,403), f'HTTP {s} {b.get("code") if isinstance(b,dict) else b}: {b.get("message") if isinstance(b,dict) else ""}')
    s,b,_=req('DELETE',f'/rest/v1/event_log?id=eq.{evid}',k,bt,None,{'Prefer':'return=representation'})
    rec(f'7f. event_log DELETE rejected ({who})', s in (401,403), f'HTTP {s} {b.get("code") if isinstance(b,dict) else b}: {b.get("message") if isinstance(b,dict) else ""}')
s,b,_=req('GET',f'/rest/v1/event_log?select=table_name&id=eq.{evid}',ANON,adm)
rec('7g. event row unchanged after attempts', b and b[0]['table_name']=='expenses', b)
s,b,_=req('DELETE',f'/rest/v1/expenses?id=eq.{eid}',ANON,adm,None,{'Prefer':'return=representation'})
s2,b2,_=req('GET',f'/rest/v1/event_log?select=action,before&table_name=eq.expenses&row_id=eq.{eid}&action=eq.DELETE',ANON,adm)
rec('7h. test expense deleted; DELETE event logged with before', s==200 and b2 and float(b2[0]['before']['amount'])==2.0, f'HTTP {s}; delete events={len(b2) if isinstance(b2,list) else b2}')
s,b,c=cnt('/rest/v1/expenses?select=id',SVC); rec('7i. expenses back to 4 seed rows', c=='4', c)
json.dump(R, open('/workspace/liveverify/results.json','w'), indent=1)
