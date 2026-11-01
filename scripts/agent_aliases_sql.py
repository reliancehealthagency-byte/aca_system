#!/usr/bin/env python3
"""Agent alias seed: the hub's "Agent Aliases" tab -> agent_name_aliases (C5; Payroll agent_name_map.md 11/01).

  agent_aliases_sql.py --tab Agent_Aliases.csv [--defaults code_defaults.csv] [--roster roster.csv] (--out FILE | --psql "<psql args>")

The tab has two blocks side by side: BOARD NAME ALIASES (Alias, Standard Name) and DIALER AGENT MAP (Dialer Agent Name,
Standard Name). Read the LIVE tab (an older backup copy lacks a dialer row). Like the hub (L586-L618): the tab's rows come
first; the hub's code-only defaults (CODE_ALIASES_ / CODE_DIALER_, L177-L179; --defaults CSV kind,alias,standard) are added
only for names the tab does not already map. --roster (header + one standard name per line, the hub Agent Sheets tab) adds
roster agents missing from agents (no login, role agent); an existing agent is never changed. Real names never go in this
public repo: the tab / defaults / roster CSVs and the generated SQL live in the private deploy package. Matching is case- and whitespace-insensitive (recon_name_key). A standard name must be a roster agent
(agents.display_name); rows whose standard name is not on the roster are skipped and listed (e.g. pre-start-line names).
The SQL is one transaction, owner-only like every agent_name_aliases write, and a re-run is a no-op. It never changes an
existing alias that points elsewhere: that is reported as a conflict for the owner to resolve.
"""
import argparse, csv, io, re, subprocess, shlex, sys



def key(s):
    return re.sub(r'\s+', ' ', (s or '').strip()).lower()


def q(s):
    return "'" + s.replace("'", "''") + "'"


def read_tab(path):
    raw = open(path, 'rb').read()
    if raw.startswith(b'\xef\xbb\xbf'):
        raw = raw[3:]
    rows = list(csv.reader(io.StringIO(raw.decode('utf-8'), newline='')))
    hdr_i = next((i for i, r in enumerate(rows) if r and r[0].strip().lower() == 'alias'), None)
    if hdr_i is None:
        sys.exit('agent_aliases_sql: no "Alias" header row found (expected the hub Agent Aliases tab layout)')
    h = [c.strip().lower() for c in rows[hdr_i]]
    try:
        di = h.index('dialer agent name')
    except ValueError:
        sys.exit('agent_aliases_sql: no "Dialer Agent Name" column found')
    out = []
    for r in rows[hdr_i + 1:]:
        r = r + [''] * (di + 2 - len(r))
        if r[0].strip() and r[1].strip():
            out.append(('board', r[0].strip(), r[1].strip(), 'hub Agent Aliases tab'))
        if r[di].strip() and r[di + 1].strip():
            out.append(('dialer', r[di].strip(), r[di + 1].strip(), 'hub Agent Aliases tab (dialer map)'))
    return out


def read_defaults(path):
    if not path:
        return []
    rows = list(csv.DictReader(open(path, encoding='utf-8-sig', newline='')))
    out = []
    for r in rows:
        k = (r.get('kind') or '').strip()
        if k not in ('board', 'dialer') or not (r.get('alias') or '').strip() or not (r.get('standard') or '').strip():
            sys.exit(f'agent_aliases_sql: bad defaults row {r!r} (need kind board|dialer, alias, standard)')
        out.append((k, r['alias'].strip(), r['standard'].strip()))
    return out


def read_roster(path):
    if not path:
        return []
    rows = list(csv.reader(open(path, encoding='utf-8-sig', newline='')))
    return [r[0].strip() for r in rows[1:] if r and r[0].strip()]


def build(rows, defaults, roster):
    seen, final = {}, []
    for kind, alias, std, note in rows:
        k = (kind, key(alias))
        if k in seen:
            if key(seen[k]) != key(std):
                sys.exit(f'agent_aliases_sql: the tab maps {alias!r} twice ({seen[k]!r} and {std!r})')
            continue
        seen[k] = std; final.append((kind, alias, std, note))
    for kind, alias, std in defaults:
        if (kind, key(alias)) not in seen:
            seen[(kind, key(alias))] = std
            final.append((kind, alias, std, 'hub code-only default (CODE_ALIASES_/CODE_DIALER_ v19.11)'))
    if len({key(n) for n in roster}) != len(roster):
        sys.exit('agent_aliases_sql: the roster lists a name twice')
    ros = ',\n  '.join(f'({q(n)})' for n in roster) or None
    roster_sql = '' if not ros else f"""-- roster: add hub Agent Sheets names that match no agent (display name or alias); existing agents are never changed
insert into public.agents (display_name, role)
select r.n, 'agent' from (values
  {ros}) r(n)
 where not exists (select 1 from public.agents a where public.recon_name_key(a.display_name) = public.recon_name_key(r.n))
   and not exists (select 1 from public.agent_name_aliases x where public.recon_name_key(x.alias) = public.recon_name_key(r.n))
returning 'roster agent added' as result, display_name;
"""
    vals = ',\n  '.join(f'({q(k)}, {q(a)}, {q(s)}, {q(n)})' for k, a, s, n in final)
    return f"""-- roster ({len(roster)}) + agent_name_aliases seed ({len(final)} rows: hub Agent Aliases tab + code-only defaults). ONE transaction; re-run = no-op.
begin;
{roster_sql}create temp table _alias_in (kind text, alias text, standard text, note text) on commit drop;
insert into _alias_in values
  {vals};
-- report: standard names not on the roster (skipped), and existing aliases that point at another agent (conflicts, unchanged)
select 'skipped: standard name not on the roster' as result, i.kind, i.alias, i.standard from _alias_in i
 where not exists (select 1 from public.agents a where public.recon_name_key(a.display_name) = public.recon_name_key(i.standard))
union all
select 'CONFLICT: existing alias points elsewhere (unchanged)', i.kind, i.alias, i.standard
  from _alias_in i join public.agent_name_aliases x on public.recon_name_key(x.alias) = public.recon_name_key(i.alias)
  join public.agents a on a.id = x.agent_id
 where public.recon_name_key(a.display_name) <> public.recon_name_key(i.standard)
order by 1, 2, 3;
insert into public.agent_name_aliases (alias, agent_id, kind, note)
select i.alias, a.id, i.kind, i.note
  from _alias_in i
  join lateral (select a.id from public.agents a where public.recon_name_key(a.display_name) = public.recon_name_key(i.standard)
                 order by a.active desc, a.created_at limit 1) a on true
 where not exists (select 1 from public.agent_name_aliases x where public.recon_name_key(x.alias) = public.recon_name_key(i.alias))
on conflict (alias) do nothing;
select 'loaded' as result, count(*) filter (where kind = 'board') board, count(*) filter (where kind = 'dialer') dialer
  from public.agent_name_aliases;
commit;
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tab', required=True); ap.add_argument('--defaults'); ap.add_argument('--roster')
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--out'); g.add_argument('--psql')
    a = ap.parse_args()
    sql = build(read_tab(a.tab), read_defaults(a.defaults), read_roster(a.roster))
    if a.out:
        open(a.out, 'w').write(sql); print(a.out)
    else:
        subprocess.run(['psql', '-X', '-v', 'ON_ERROR_STOP=1', *shlex.split(a.psql)], input=sql, text=True, check=True)


if __name__ == '__main__':
    main()
