#!/usr/bin/env python3
"""One-time hub cutover: the Payroll Hub "Paid Lock" tab -> hub_paid_lock + the ONE hub_cutover row.

Layout (Kyle 11/01 11:55 AM ET, relayed by the Orchestrator): Pay Friday | Agent | Paid Total | System Total |
Locked At (ET) | Note, exactly these six columns in this order (the hub's PAID_LOCK_HDR_).

  build  --unformatted RAW.csv --formatted FMT.csv --out paid_lock_import.csv
         RAW = the tab read with UNFORMATTED_VALUE (Sheets serials keep the Locked At time the display hides);
         FMT = the same tab as displayed. Both must agree (date, agent, money) or nothing is written.
  check  --csv paid_lock_import.csv [--roster agent_sheets.csv] [--aliases agent_aliases.csv]
         [--finalized finalized.csv] [--lock-open lock_open_items.csv] [--agents-sql "<psql args>"]
         Prints the checks table (markdown). Exit 1 on any hard error.
  sql    --csv paid_lock_import.csv (--dry-run | --confirm-hub) (--out FILE | --psql "<psql args>")
         Writes the SQL Editor paste (one DO block = one transaction). --dry-run ends by raising (nothing persists);
         --confirm-hub writes. Owner-only: the DB lets only the payroll owner's login or the SQL Editor (postgres
         break-glass, audited) insert hub rows. Re-running the same file after it is recorded is a no-op; a different
         file is refused (one-time). It never touches a payday this system locked: refused if any pay_line_locks exist.
"""
import argparse, csv, datetime as dt, hashlib, io, os, re, shlex, subprocess, sys
from decimal import Decimal, ROUND_HALF_UP
from zoneinfo import ZoneInfo

HEADER = ['Pay Friday', 'Agent', 'Paid Total', 'System Total', 'Locked At (ET)', 'Note']
ET = ZoneInfo('America/New_York')
REPO_ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
SERIAL0 = dt.datetime(1899, 12, 30)
TODAY_ET = None   # set in main (overridable for tests with --today)


class Refused(Exception):
    pass


def die(msg):
    print(f'hub_cutover: {msg}', file=sys.stderr)
    sys.exit(2)


def money(v, where, required=True):
    t = (v or '').strip()
    if not t:
        if required:
            raise Refused(f'{where}: amount is blank')
        return None
    neg = t.startswith('(') and t.endswith(')')
    t = t.strip('()').replace('$', '').replace(',', '').strip()
    if t.startswith('-'):
        neg, t = (not neg), t[1:].strip().lstrip('$')
    if not re.fullmatch(r'\d{1,7}(\.\d+)?', t):
        raise Refused(f'{where}: {v!r} is not a money value')
    d = Decimal(t)
    if d != d.quantize(Decimal('0.01')):
        # Sheets floats (e.g. 425.59000000000003) round to cents; anything with real sub-cent value is refused
        if abs(d - d.quantize(Decimal('0.01'))) > Decimal('0.000001'):
            raise Refused(f'{where}: {v!r} has fractions of a cent')
    d = d.quantize(Decimal('0.01'), ROUND_HALF_UP)
    return -d if neg else d


def parse_day(v, where):
    v = (v or '').strip()
    m = re.fullmatch(r'(\d{4})-(\d{1,2})-(\d{1,2})', v) or re.fullmatch(r'(\d{1,2})/(\d{1,2})/(\d{4})', v)
    if not m:
        raise Refused(f'{where}: date {v!r} is not YYYY-MM-DD or MM/DD/YYYY')
    a, b, c = (int(x) for x in m.groups())
    y, mo, d = (a, b, c) if '-' in v else (c, a, b)
    try:
        return dt.date(y, mo, d)
    except ValueError:
        raise Refused(f'{where}: {v!r} is not a real date')


def parse_ts(v, where):
    """Locked At (ET): 'YYYY-MM-DD HH:MM[:SS]' or 'MM/DD/YYYY[ HH:MM[:SS]]' -> naive ET datetime (+ had_time)."""
    v = (v or '').strip()
    m = re.fullmatch(r'(\S+)(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?', v)
    if not v or not m:
        raise Refused(f'{where}: Locked At (ET) {v!r} is blank or not a date-time')
    day = parse_day(m.group(1), where)
    if m.group(2) is None:
        return dt.datetime.combine(day, dt.time()), False
    h, mi, s = int(m.group(2)), int(m.group(3)), int(m.group(4) or 0)
    if h > 23 or mi > 59 or s > 59:
        raise Refused(f'{where}: Locked At (ET) {v!r} is not a real time')
    return dt.datetime.combine(day, dt.time(h, mi, s)), True


def serial_day(v, where):
    try:
        f = float(v)
    except ValueError:
        raise Refused(f'{where}: {v!r} is not a Sheets date serial')
    if f != int(f):
        raise Refused(f'{where}: Pay Friday serial {v!r} has a time part')
    return (SERIAL0 + dt.timedelta(days=int(f))).date()


def serial_ts(v, where):
    try:
        f = float(v)
    except ValueError:
        raise Refused(f'{where}: {v!r} is not a Sheets date-time serial')
    return SERIAL0 + dt.timedelta(seconds=round(f * 86400))


def fmt_ts(t):
    return t.strftime('%Y-%m-%d %H:%M') if t.second == 0 else t.strftime('%Y-%m-%d %H:%M:%S')


def read_csv(path):
    raw = open(path, 'rb').read()
    if raw.startswith(b'\xef\xbb\xbf'):
        raw = raw[3:]
    rows = list(csv.reader(io.StringIO(raw.decode('utf-8'), newline='')))
    while rows and not any(c.strip() for c in rows[-1]):
        rows.pop()
    return rows


def load(path, today=None):
    """Strict reader for the import CSV. Returns (sha256, rows, warnings); raises Refused on any hard error."""
    today = today or TODAY_ET
    sha = hashlib.sha256(open(path, 'rb').read()).hexdigest()
    rows = read_csv(path)
    if not rows:
        raise Refused(f'{path}: empty file')
    hdr = [h.strip() for h in rows[0]]
    if hdr != HEADER:
        raise Refused(f'{path}: header must be exactly {" | ".join(HEADER)} (got {" | ".join(hdr)})')
    out, warns, seen = [], [], {}
    for i, r in enumerate(rows[1:], start=1):
        w = f'line {i + 1}'
        if not any(c.strip() for c in r):
            raise Refused(f'{w}: blank row inside the file')
        if len(r) != 6:
            raise Refused(f'{w}: {len(r)} columns, expected 6')
        day = parse_day(r[0], w)
        if day.weekday() != 4:
            raise Refused(f'{w}: Pay Friday {day} is a {day:%A}, not a Friday')
        if day > today:
            raise Refused(f'{w}: Pay Friday {day} is after today ET ({today}): the hub can\'t have paid it')
        agent = re.sub(r'\s+', ' ', r[1].strip())
        if not agent:
            raise Refused(f'{w}: Agent is blank')
        paid = money(r[2], f'{w} Paid Total')
        sys_t = money(r[3], f'{w} System Total', required=False)
        locked, had_time = parse_ts(r[4], w)
        if not had_time:
            warns.append(f'{w}: Locked At {r[4]!r} has no time; read as 00:00 ET')
        if locked.date() < day - dt.timedelta(days=7) or locked.date() > today:
            raise Refused(f'{w}: Locked At {locked} is not between Pay Friday - 7 days and today ET')
        key = (day, agent.casefold())
        if key in seen:
            raise Refused(f'{w}: duplicate Pay Friday + Agent ({day}, {agent}); first at line {seen[key]}')
        seen[key] = i + 1
        out.append(dict(row_num=i, payday=day, agent=agent, paid=paid, system=sys_t, locked=locked,
                        note=r[5].strip() or None))
    if not out:
        raise Refused(f'{path}: no data rows')
    return sha, out, warns


# ------------------------------------------------------------------ build
def cmd_build(a):
    u, f = read_csv(a.unformatted), read_csv(a.formatted)
    for name, t in (('unformatted', u), ('formatted', f)):
        if [h.strip() for h in t[0]] != HEADER:
            die(f'{name} export header is not the Paid Lock layout: {t[0]}')
    if len(u) != len(f):
        die(f'unformatted has {len(u) - 1} rows, formatted {len(f) - 1}: re-read the tab')
    lines = []
    try:
        for i, (ru, rf) in enumerate(zip(u[1:], f[1:]), start=2):
            w = f'row {i}'
            day = serial_day(ru[0], w)
            if day != parse_day(rf[0], w):
                raise Refused(f'{w}: Pay Friday serial {ru[0]} = {day} but the tab shows {rf[0]}')
            if ru[1].strip() != rf[1].strip():
                raise Refused(f'{w}: agent differs between reads')
            paid = money(ru[2], w); sys_t = money(ru[3], w, required=False)
            if paid != money(rf[2], w) or sys_t != money(rf[3], w, required=False):
                raise Refused(f'{w}: money differs between reads')
            lk = serial_ts(ru[4], w)
            shown, had_time = parse_ts(rf[4], w)
            if lk.date() != shown.date() or (had_time and fmt_ts(lk)[:16] != fmt_ts(shown)[:16]):
                raise Refused(f'{w}: Locked At serial = {lk} but the tab shows {rf[4]}')
            lines.append([day.isoformat(), ru[1].strip(), f'{paid:.2f}', '' if sys_t is None else f'{sys_t:.2f}',
                          fmt_ts(lk), ru[5].strip()])
    except Refused as e:
        die(str(e))
    op = os.path.realpath(a.out)
    if op.startswith(REPO_ROOT + os.sep):
        die('--out is inside the git tree: real pay data stays out of the (public) repo')
    buf = io.StringIO(); wr = csv.writer(buf, lineterminator='\n'); wr.writerow(HEADER); wr.writerows(lines)
    fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as fh:
        fh.write(buf.getvalue())
    print(f'wrote {a.out}: {len(lines)} rows, sha256 {hashlib.sha256(buf.getvalue().encode()).hexdigest()}')


# ------------------------------------------------------------------ check
def roster_names(a):
    std, alias = set(), {}
    if a.roster:
        for r in read_csv(a.roster)[1:]:
            if r and r[0].strip():
                std.add(r[0].strip())
    if a.aliases:
        for r in read_csv(a.aliases)[2:]:
            if len(r) >= 2 and r[0].strip() and r[1].strip():
                alias[r[0].strip().casefold()] = r[1].strip()
    return std, alias


def db_agents(psql_args):
    q = "select display_name || '|' || id from public.agents union all select alias || '|' || agent_id from public.agent_name_aliases"
    r = subprocess.run(['psql', '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q] + shlex.split(psql_args), capture_output=True, text=True)
    if r.returncode:
        die(f'--agents-sql failed: {r.stderr.strip()}')
    return {ln.split('|')[0].casefold(): ln.split('|')[1] for ln in r.stdout.splitlines() if '|' in ln}


def cmd_check(a):
    try:
        sha, rows, warns = load(a.csv)
    except Refused as e:
        print(f'| file | **REFUSED** | {e} |'); sys.exit(1)
    hard = []
    P = print
    P(f'### Checks: {os.path.basename(a.csv)} (sha256 {sha})\n')
    days = sorted({r['payday'] for r in rows})
    P('| Pay Friday | Rows | Paid Total | System Total | Paid − System | Locked At (ET) |')
    P('|---|---:|---:|---:|---:|---|')
    for d in days:
        rs = [r for r in rows if r['payday'] == d]
        paid = sum(r['paid'] for r in rs)
        has_sys = [r for r in rs if r['system'] is not None]
        st = sum(r['system'] for r in has_sys) if has_sys else None
        var = (sum(r['paid'] for r in has_sys) - st) if has_sys else None
        lks = sorted({fmt_ts(r['locked']) for r in rs})
        P(f"| {d} | {len(rs)} | {paid:,.2f} | {'—' if st is None else f'{st:,.2f}'}"
          f"{'' if len(has_sys) in (0, len(rs)) else f' ({len(has_sys)} rows)'} | {'n/a' if var is None else f'{var:+,.2f}'} | {', '.join(lks)} |")
        if len(lks) > 1:
            warns.append(f'{d}: {len(lks)} different Locked At values')
    P(f"| **all** | **{len(rows)}** | **{sum(r['paid'] for r in rows):,.2f}** | | | |\n")
    vr = [r for r in rows if r['system'] is not None and r['paid'] != r['system']]
    P('**Paid vs System variances** (the hub\'s Paid Total is final; never carried forward):\n')
    P('| Pay Friday | Agent | Paid | System | Paid − System |\n|---|---|---:|---:|---:|')
    for r in vr:
        P(f"| {r['payday']} | {r['agent']} | {r['paid']:,.2f} | {r['system']:,.2f} | {r['paid'] - r['system']:+,.2f} |")
    if not vr:
        P('| — | none | | | |')
    nos = [r for r in rows if r['system'] is None]
    if nos:
        P(f"\nNo System Total on {len(nos)} row(s) (paydays {', '.join(sorted({str(r['payday']) for r in nos}))}): no variance check possible.")
    # mapping
    std, alias = roster_names(a)
    dbmap = db_agents(a.agents_sql) if a.agents_sql else None
    P('\n**Agent mapping**\n')
    P('| Agent (file) | Hub roster (Agent Sheets / Aliases) | Backend agent id | $ in file |\n|---|---|---|---:|')
    for ag in sorted({r['agent'] for r in rows}):
        tot = sum(r['paid'] for r in rows if r['agent'] == ag)
        hub = ag if ag in std else alias.get(ag.casefold())
        hub_s = ('standard name' if ag in std else f'alias → {hub}') if hub else '**UNMAPPED**'
        if not (a.roster or a.aliases):
            hub, hub_s = ag, 'not checked (no --roster)'
        if dbmap is None:
            db_s = 'not checked'
        else:
            db_s = (dbmap.get(ag.casefold()) or dbmap.get((hub or '').casefold()) or '**UNMAPPED**')
            if db_s != '**UNMAPPED**':
                db_s = db_s[:8] + '…'
        P(f'| {ag} | {hub_s} | {db_s} | {tot:,.2f} |')
        if not hub and tot != 0:
            hard.append(f'agent {ag!r} is not on the hub roster and carries {tot}')
        elif not hub:
            warns.append(f'agent {ag!r} is not on the hub roster ($0.00 only: kept, as the hub keeps it)')
    # cross-checks
    if a.finalized:
        fin = {}
        for r in read_csv(a.finalized)[1:]:
            try:
                fin[(parse_day(r[0], 'fin'), r[1].strip())] = money(r[3], 'fin')
            except Refused:
                pass
        mism = [(r['payday'], r['agent'], r['system'], fin.get((r['payday'], r['agent'])))
                for r in rows if r['system'] is not None and fin.get((r['payday'], r['agent'])) != r['system']]
        cov = sum(1 for r in rows if (r['payday'], r['agent']) in fin)
        P(f"\n**System Total vs hub Finalized Paydays \"Final Pay\"**: {cov} rows matched by Pay Friday + Agent, "
          f"{len(mism)} differ{': ' + '; '.join(f'{m[0]} {m[1]} {m[2]} vs {m[3]}' for m in mism) if mism else ''}. "
          f"Finalized rows not in the file: {len(set(fin) - {(r['payday'], r['agent']) for r in rows})}.")
        if mism:
            hard.append('System Total differs from Finalized Paydays')
    if a.lock_open:
        lo = read_csv(a.lock_open)
        h = [x.strip() for x in lo[0]]
        op = [r for r in lo[1:] if not r[h.index('Paid On')].strip()]
        est = sum(money(r[h.index('Est Commission')], 'lock open') for r in op)
        P(f"\n**Hub Lock Open Items** (not part of this file): {len(lo) - 1} rows, **{len(op)} still open** (no Paid On), est. commission "
          f"{est:,.2f}: " + '; '.join(f"{r[h.index('Agent')]} {r[h.index('Member ID')]} orig {r[h.index('Original Pay Friday')]} "
                                       f"{r[h.index('Est Commission')]}" for r in op))
    P('\n**Duplicates** (Pay Friday + Agent, case-insensitive): none (the loader refuses any).')
    P(f"\n**Date parsing (ET)**: every Pay Friday is a Friday on/before today ET ({TODAY_ET}); Locked At is written as "
      f"`timestamp '<value>' at time zone 'America/New_York'` (no DateStyle dependence):")
    for r in sorted({(r['payday'], fmt_ts(r['locked'])) for r in rows}):
        utc = r[1] and dt.datetime.fromisoformat(r[1]).replace(tzinfo=ET).astimezone(dt.timezone.utc)
        P(f'- {r[0]} → locked {r[1]} ET = {utc:%Y-%m-%d %H:%M} UTC')
    if warns:
        P('\n**Warnings**\n' + '\n'.join(f'- {w}' for w in warns))
    if hard:
        P('\n**HARD ERRORS**\n' + '\n'.join(f'- {x}' for x in hard)); sys.exit(1)
    P(f'\nResult: PASS ({len(rows)} rows, {len(days)} paydays, last_hub_payday {days[-1]}).')


# ------------------------------------------------------------------ sql
def lit(s):
    return 'null' if s is None else "'" + str(s).replace("'", "''") + "'"


def build_sql(path, confirm, today=None):
    sha, rows, warns = load(path, today)
    days = sorted({r['payday'] for r in rows})
    total = sum(r['paid'] for r in rows)
    per = ', '.join(f"('{d}'::date, {sum(1 for r in rows if r['payday'] == d)}, "
                    f"{sum(r['paid'] for r in rows if r['payday'] == d):.2f})" for d in days)
    vals = ',\n      '.join(
        f"({r['row_num']}, date '{r['payday']}', {lit(r['agent'])}, {r['paid']:.2f}, "
        f"{'null' if r['system'] is None else format(r['system'], '.2f')}, "
        f"timestamp '{r['locked']:%Y-%m-%d %H:%M:%S}' at time zone 'America/New_York', {lit(r['note'])})" for r in rows)
    mode = 'APPLY (--confirm-hub)' if confirm else 'DRY RUN (writes nothing: ends by raising, so the whole block rolls back)'
    fname = os.path.basename(path)
    return f"""-- HUB CUTOVER {mode}
-- One-time import of the hub Paid Lock tab (Kyle 11/01 11:55 AM ET layout: Pay Friday | Agent | Paid Total | System Total |
-- Locked At (ET) | Note). File {fname}: {len(rows)} rows, sha256 {sha}; paydays {', '.join(map(str, days))};
-- last_hub_payday {days[-1]}; Paid Total sum {total:.2f}. Built by scripts/hub_cutover.py.
-- Run in the Supabase SQL Editor (postgres break-glass, audited) or as the payroll owner. ONE statement (a DO block), so it
-- is one transaction whatever the editor does. Re-running after it is recorded from this same file is a no-op; any other
-- file is refused. Refused if this system already locked any payday (pay_line_locks), so no live locked week is touched.
do $hub$
declare
  c_sha    constant text    := '{sha}';
  c_file   constant text    := {lit(fname)};
  c_rows   constant int     := {len(rows)};
  c_total  constant numeric := {total:.2f};
  c_last   constant date    := date '{days[-1]}';
  c_dry    constant boolean := {'false' if confirm else 'true'};
  cur record; b record; n int; s numeric; bad text; unmapped text; frozen int; summary text;
begin
  if to_regclass('public.hub_cutover') is null or to_regclass('public.hub_paid_lock') is null then
    raise exception 'hub cutover REFUSED: slice three (hub_paid_lock / hub_cutover) is not applied';
  end if;
  perform public.recon_owner_or_sql_editor('hub cutover');          -- payroll owner, or the SQL Editor; never service_role
  select * into cur from public.hub_cutover;
  if found then
    if cur.file_sha256 = c_sha and cur.row_count = c_rows then
      if c_dry then raise exception 'HUB CUTOVER DRY RUN: already recorded from this file at % (% rows, last_hub_payday %): nothing to do', cur.recorded_at, cur.row_count, cur.last_hub_payday; end if;
      raise notice 'hub cutover already recorded from this file at % (% rows, last_hub_payday %): no-op', cur.recorded_at, cur.row_count, cur.last_hub_payday;
      return;
    end if;
    raise exception 'hub cutover REFUSED: already recorded from another file (sha % , % rows, last_hub_payday %): the cutover is one-time and immutable',
      left(cur.file_sha256, 12), cur.row_count, cur.last_hub_payday;
  end if;
  select count(*) into n from public.hub_paid_lock;
  if n > 0 then raise exception 'hub cutover REFUSED: hub_paid_lock already holds % row(s) without a cutover record: investigate first', n; end if;
  select * into b from public.recon_cutover_bounds();
  if b.first_locked is not null then
    raise exception 'hub cutover REFUSED: this system already locked payday % (pay_line_locks): the cutover must come first and never touches a locked week', b.first_locked;
  end if;
  if b.last_submit is not null and b.last_submit > c_last then
    raise exception 'hub cutover REFUSED: payday % is already submitted here but the hub file ends %: that payroll would count twice', b.last_submit, c_last;
  end if;

  create temp table _hub_rows (row_num int primary key, payday date not null, agent_name text not null, paid_total numeric(12,2) not null,
                               system_total numeric(12,2), locked_at timestamptz not null, note text) on commit drop;
  insert into _hub_rows values
      {vals};
  select string_agg(format('%s %s x%s', payday, k, c), '; ') into bad
    from (select payday, lower(btrim(agent_name)) k, count(*) c from _hub_rows group by 1, 2 having count(*) > 1) d;
  if bad is not null then raise exception 'hub cutover REFUSED: duplicate Pay Friday + Agent: %', bad; end if;
  select string_agg(format('row %s %s', row_num, payday), '; ') into bad from _hub_rows
   where extract(dow from payday) <> 5 or payday > (now() at time zone 'America/New_York')::date;
  if bad is not null then raise exception 'hub cutover REFUSED: not a past Friday: %', bad; end if;
  select string_agg(format('%s: %s rows / %s (expected %s / %s)', e.d, coalesce(g.n, 0), coalesce(g.s, 0), e.n, e.s), '; ') into bad
    from (values {per}) e(d, n, s)
    full join (select payday, count(*) n, sum(paid_total) s from _hub_rows group by 1) g on g.payday = e.d
   where e.d is null or g.payday is null or g.n <> e.n or g.s <> e.s;
  if bad is not null then raise exception 'hub cutover REFUSED: per-payday counts / sums differ from the checked file: %', bad; end if;

  insert into public.hub_paid_lock (file_sha256, row_num, payday, agent_name, paid_total, system_total, locked_at, note)
  select c_sha, row_num, payday, agent_name, paid_total, system_total, locked_at, note from _hub_rows order by row_num;
  insert into public.hub_cutover (file_name, file_sha256, note)
  values (c_file, c_sha, 'hub Paid Lock export, one-time cutover (layout: Kyle 11/01 11:55 AM ET)');

  select count(*), sum(paid_total) into n, s from public.hub_paid_lock where file_sha256 = c_sha;
  select * into cur from public.hub_cutover;
  if n <> c_rows or s <> c_total or cur.last_hub_payday <> c_last or cur.row_count <> c_rows then
    raise exception 'hub cutover verify FAILED: % rows / % (expected % / %), last_hub_payday %', n, s, c_rows, c_total, cur.last_hub_payday;
  end if;
  if has_table_privilege('public.event_log', 'select') then
    select coalesce((detail->>'board_submissions_frozen')::int, 0) into frozen from public.event_log
     where event_type = 'payroll.hub_cutover.recorded' and row_id = c_sha order by id desc limit 1;
  end if;
  select string_agg(distinct agent_name, ', ') into unmapped from _hub_rows where public.recon_agent_id(agent_name) is null;
  -- the trigger hub_cutover_recorded (security definer) always logs payroll.hub_cutover.recorded; this extra, detailed
  -- import event is written on the SQL Editor path (an owner session has no direct insert grant on event_log)
  if has_table_privilege('public.event_log', 'insert') then
  insert into public.event_log (event_type, actor_uid, actor_role, table_name, row_id, action, detail)
  values ('payroll.hub_cutover.import', public.audit_actor_uid(), public.audit_actor_role(), 'hub_paid_lock', c_sha, 'EVENT',
          jsonb_build_object('file_name', c_file, 'rows', n, 'paid_total_sum', s, 'last_hub_payday', c_last,
                             'per_payday', (select jsonb_object_agg(payday, jsonb_build_object('rows', k, 'paid', p))
                                              from (select payday, count(*) k, sum(paid_total) p from _hub_rows group by 1) x),
                             'unmapped_agent_names', unmapped,
                             'path', case when public.audit_actor_role() in ('postgres', 'supabase_admin')
                                          then 'break-glass:' || public.audit_actor_role() else 'owner-login' end,
                             'ruling', 'Kyle 11/01 11:55 AM ET (relayed by Orchestrator): Paid Lock layout for the one-time import'));
  end if;
  summary := format('%s rows, %s paid, paydays %s, last_hub_payday %s, board submissions frozen %s, agent names with no backend agent id: %s',
                    n, s, cur.paydays, cur.last_hub_payday, frozen, coalesce(unmapped, 'none'));
  if c_dry then
    raise exception 'HUB CUTOVER DRY RUN OK (rolled back, nothing written): %', summary;
  end if;
  raise notice 'HUB CUTOVER RECORDED: %', summary;
end $hub$;

-- After an APPLY, this grid should read: rows {len(rows)} | paid {total:.2f} | last_hub_payday {days[-1]} | events 1 | 1
select (select count(*) from public.hub_paid_lock) as rows, (select sum(paid_total) from public.hub_paid_lock) as paid,
       (select last_hub_payday from public.hub_cutover) as last_hub_payday,
       (select count(*) from public.event_log where event_type = 'payroll.hub_cutover.recorded') as recorded_events,
       (select count(*) from public.event_log where event_type = 'payroll.hub_cutover.import') as import_events;
""", sha, rows, warns


def cmd_sql(a):
    if a.dry_run == a.confirm_hub:
        die('choose exactly one of --dry-run or --confirm-hub')
    if not (a.out or a.psql):
        die('use --out FILE (outside the repo) or --psql "<args>"')
    try:
        sql, sha, rows, warns = build_sql(a.csv, a.confirm_hub)
    except Refused as e:
        die(f'REFUSED: {e}')
    for w in warns:
        print(f'warning: {w}', file=sys.stderr)
    print(f"hub cutover {'APPLY' if a.confirm_hub else 'DRY RUN'}: {len(rows)} rows, sha256 {sha}", file=sys.stderr)
    if a.out:
        op = os.path.realpath(a.out)
        if op.startswith(REPO_ROOT + os.sep):
            die('--out is inside the git tree: write it outside the repo')
        fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as fh:
            fh.write(sql)
        print(f'wrote {a.out} sha256 {hashlib.sha256(sql.encode()).hexdigest()}', file=sys.stderr)
    else:
        r = subprocess.run(['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1'] + shlex.split(a.psql), input=sql.encode())
        sys.exit(r.returncode)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--today', help='override today (ET) for tests, YYYY-MM-DD')
    sp = ap.add_subparsers(dest='cmd', required=True)
    b = sp.add_parser('build'); b.add_argument('--unformatted', required=True); b.add_argument('--formatted', required=True); b.add_argument('--out', required=True)
    c = sp.add_parser('check'); c.add_argument('--csv', required=True)
    for o in ('--roster', '--aliases', '--finalized', '--lock-open', '--agents-sql'):
        c.add_argument(o)
    s = sp.add_parser('sql'); s.add_argument('--csv', required=True); s.add_argument('--dry-run', action='store_true')
    s.add_argument('--confirm-hub', action='store_true'); s.add_argument('--out'); s.add_argument('--psql')
    a = ap.parse_args()
    TODAY_ET = dt.date.fromisoformat(a.today) if a.today else dt.datetime.now(ET).date()
    {'build': cmd_build, 'check': cmd_check, 'sql': cmd_sql}[a.cmd](a)
