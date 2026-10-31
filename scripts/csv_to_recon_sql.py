#!/usr/bin/env python3
"""Turn a Premier "Member Products" CSV, a Sales Board "Form Responses 1" CSV and/or a hub "Manual Adjustments" CSV into
idempotent SQL inserts for the slice-three staging tables.

CLIENT DATA (rev 3, Kyle 10/31 relayed via Orchestrator): ops is admin-only (Kyle + co-owner), so client contact
  details MAY be stored. Premier keeps the reconciliation columns plus contact columns (names, phones, emails, city /
  state / county); gender, company/position, refund comments and the empty ethnicity/height/weight/disability columns are
  still dropped. Board keeps A..AP; only AC (Income) is blanked. Free text (Hold Reason, board Source) is stored raw; the
  database derives a normalized ops copy. Matching hashes: HMAC-sha256 with the salt in
  /workspace/secrets/recon_hash_salt.txt (0600, never committed, never printed); real imports refuse to run unsalted.
  --mock uses plain sha256 so the committed mock seed is reproducible.
HUB CUTOVER (rev 3): --hub PAIDLOCK.csv = the hub "Paid Lock" tab (Pay Friday, Agent, Paid Total, Locked At (ET); optional
  System Total, Note). One-time: it starts this system's clock; every payday in it is paid_by_hub.
BOARD EXPORTS (rev 3): the board import is FINALIZED at the end of the same transaction (recon_finalize_board_import). The
  database refuses a stale export (newest Timestamp older than the latest export's) and one that would revert a
  submission to a version a later export replaced; --allow-revert overrides the second check after Kyle has looked.
  Real (non --mock) output is wrapped in one transaction, so a refusal leaves nothing behind.
MANUAL ADJUSTMENTS: Amount must be a plain money value ($, commas and (negative) allowed); anything else stops the script.
HEADER CONTRACT: every column the database reads must be present BY NAME (Premier) or by position + name (board, the
live Sales Board A..AP). Anything missing stops the script with a clear error before any SQL is written.
OUTPUT: --mock may write to stdout. Real (non --mock) files must use either
  --psql "<psql args>"  stream the SQL straight into psql (nothing written to disk), or
  --out /tmp/<file>.sql  a 0600 file that you delete right after use (e.g. `shred -u FILE`); the script prints a reminder.
The generated SQL holds client contact details, member IDs and pay data: it must not linger on the shared box.

  python3 scripts/csv_to_recon_sql.py [--premier PHS.csv] [--board BOARD.csv] [--madj MADJ.csv] [--hub PAIDLOCK.csv]
      (--mock | --out F | --psql ARGS) [--salt-file F] [--allow-revert]
"""
import argparse, csv, hashlib, hmac, io, os, re, shlex, subprocess, sys

PREMIER_REQUIRED = ['Member ID', 'Product ID', 'Product Label', 'Product Benefit', 'Period Label', 'Agent Label',
                    'Member Created Date', 'Product Created Date', 'Active Date', 'First Billing Date', 'Next Billing Date',
                    'Inactive Date', 'Hold Date', 'Hold Reason', 'Paid', 'Last Payment', 'Refund Requested', 'Refund Provided',
                    'Refund Provided Date', 'Product Fee', 'Enrollment Fee', 'EnrollmentProcessingFee Fee', 'ApplicationFee Fee',
                    'AWALifetimeMembership Fee']
PREMIER_ALLOWED = PREMIER_REQUIRED + ['Agent ID', 'Agent Code', 'Inactive Reason', 'Product Status', 'Paytype',
                                      'Refund Requested Date', 'Next Billing Amount', 'Inactive Date Set',
                                      'First Name', 'Last Name', 'Phone 1', 'Phone 1 Ext', 'Phone 2', 'Phone 2 Ext',
                                      'Phone 3', 'Phone 3 Ext', 'Email', 'Email2', 'Email 3', 'City', 'State', 'Country',
                                      'County', 'Other City', 'Other State']
PREMIER_HASH_SRC = {'phone': 'Phone 1', 'email': 'Email'}          # required: used only to build the hashes
# live Sales Board A..AP: (index, expected header); only these positions are checked
BOARD_EXPECTED = {0: 'Timestamp', 1: 'Member ID', 2: 'Date Booked', 4: 'Active Date', 5: 'Agent', 6: 'Premium',
                  7: 'Customer Name', 8: 'Customer Email', 9: 'Customer Phone', 12: 'Post Date', 13: 'Email',
                  15: 'ABS Addon?', 17: 'Deal Type', 18: 'Agent', 20: 'FFM', 21: 'Client Name', 24: 'Date Booked',
                  28: 'Income', 31: 'Premier/Neo Addon?', 32: 'Premier/Neo Member ID', 33: 'Premier/Neo Premium',
                  34: 'ABS Addon?', 35: 'ABS Member ID', 36: 'ABS Premium', 38: 'Phone Number',
                  40: 'Increased Comm/Spiff Product?', 41: 'Agent'}
BOARD_COLS = 42
BOARD_BLANK = [28]                                                   # AC Income (not contact, not needed)
MADJ_REQUIRED = ['Agent', 'Payday', 'Amount', 'Reason/Note', 'Member ID', 'Entered By', 'Date Entered']   # + optional Covers
HUB_REQUIRED = ['Pay Friday', 'Agent', 'Paid Total', 'Locked At (ET)']   # + optional System Total, Note
ALLOW_REVERT = False
DEFAULT_SALT_FILE = '/workspace/secrets/recon_hash_salt.txt'

def money(v, where):
    """Strict money parse for an Amount cell -> canonical SQL numeric literal (never raw text in SQL)."""
    from decimal import Decimal, InvalidOperation
    t = (v or '').strip()
    neg = t.startswith('(') and t.endswith(')')
    if neg:
        t = t[1:-1].strip()
    t = t.replace('$', '').replace(',', '').strip()
    if not re.fullmatch(r'-?\d{1,7}(\.\d{1,2})?', t):
        die(f'{where}: Amount {v!r} is not a money value (e.g. 75, -12.50, $1,234.00, (20.00))')
    d = Decimal(t)
    if neg:
        d = -d
    if d == 0:
        die(f'{where}: Amount is 0 (an adjustment must change pay)')
    return format(d.quantize(Decimal('0.01')), 'f')

def die(msg):
    sys.exit('csv_to_recon_sql: ' + msg)

def norm(h):
    return re.sub(r'\s+', ' ', h.strip()).lower()

def lit(s):
    return "'" + s.replace("'", "''") + "'"

def arr(fields):
    return "array[" + ",".join(lit(f) for f in fields) + "]::text[]"

SALT = b''
SCHEME = 'sha256'

def load_salt(path, mock):
    """Real imports: HMAC salt from a 0600 file (never printed). Mock: plain sha256 (reproducible committed seed)."""
    global SALT, SCHEME
    if mock:
        return
    if not path or not os.path.exists(path):
        die(f'real imports need the hash salt file ({path or DEFAULT_SALT_FILE}); unsalted hashes are reversible')
    if os.stat(path).st_mode & 0o077:
        die(f'salt file {path} must be mode 0600')
    SALT = open(path, 'rb').read().strip()
    if len(SALT) < 16:
        die(f'salt file {path} is too short')
    SCHEME = 'hmac-sha256'

def h(value):
    if not value:
        return 'null'
    d = hmac.new(SALT, value.encode(), hashlib.sha256).hexdigest() if SALT else hashlib.sha256(value.encode()).hexdigest()
    return lit(d)

def phone_norm(v):
    d = re.sub(r'\D', '', v or '')
    return d[-10:] if len(d) >= 10 else ''

def email_norm(v):
    v = (v or '').strip().lower()
    return v if '@' in v else ''

def load(path, encoding):
    raw = open(path, 'rb').read()
    try:
        text = raw.decode(encoding)
    except UnicodeDecodeError as e:
        die(f'{path}: not {encoding}: {e}')
    crlf = text.count('\r\n'); lf = text.count('\n')
    rows = list(csv.reader(io.StringIO(text, newline='')))
    while rows and rows[-1] == []:
        rows.pop()
    if not rows:
        die(f'{path}: empty file')
    header, data = rows[0], rows[1:]
    bad = [i + 2 for i, r in enumerate(data) if len(r) != len(header)]
    if bad:
        die(f'{path}: rows with the wrong field count at lines {bad[:10]}')
    ending = 'CRLF' if crlf and crlf >= lf - sum(f.count('\n') for r in rows for f in r) else 'LF'
    return hashlib.sha256(raw).hexdigest(), ending, header, data

def import_sql(kind, name, sha, encoding, ending, header, n, mock, out):
    out.write(f"with imp as (\n  insert into public.recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, hash_scheme, note)\n"
              f"  values ({lit(kind)}, {lit(name)}, {lit(sha)}, {lit(encoding)}, {lit(ending)}, {arr(header)}, {n}, {'true' if mock else 'false'}, {lit(SCHEME)},"
              f" {lit(('MOCK data from /workspace/artifacts/premier_mock (Payroll, 10/31); ' if mock else '') + 'via scripts/csv_to_recon_sql.py (ops allow-list, ' + SCHEME + ' hashes)')})\n"
              f"  on conflict (kind, file_sha256) do nothing returning id)\n")

def emit_premier(path, mock, out):
    sha, ending, header, data = load(path, 'cp1252')
    missing = [c for c in PREMIER_REQUIRED + list(PREMIER_HASH_SRC.values()) if c not in header]
    if missing:
        die(f'{path}: required Premier column(s) missing: {", ".join(missing)}')
    keep = [i for i, c in enumerate(header) if c in PREMIER_ALLOWED or c.endswith(' Fee')]
    kh = [header[i] for i in keep]
    pi, ei = header.index(PREMIER_HASH_SRC['phone']), header.index(PREMIER_HASH_SRC['email'])
    name = os.path.basename(path)
    out.write(f"-- premier_member_products: {name} ({len(data)} rows; kept {len(kh)} of {len(header)} columns (ops allow-list); {SCHEME} hashes; sha256 {sha})\n")
    import_sql('premier_member_products', name, sha, 'cp1252', ending, kh, len(data), mock, out)
    out.write("insert into public.premier_member_products (import_id, row_num, raw_fields, phone_sha256, email_sha256)\n"
              "select imp.id, v.n, v.f, v.ph, v.em from imp, (values\n")
    out.write(",\n".join(f"  ({i + 1}, {arr([r[j] for j in keep])}, {h(phone_norm(r[pi]))}, {h(email_norm(r[ei]))})" for i, r in enumerate(data)))
    out.write("\n) v(n, f, ph, em);\n\n")

def emit_board(path, mock, out):
    sha, ending, header, data = load(path, 'utf-8')
    if len(header) != BOARD_COLS:
        die(f'{path}: expected the live Sales Board columns A..AP ({BOARD_COLS}), found {len(header)} '
            '(payhub/data/board_live.csv is a stale 41-column layout; export the live board)')
    wrong = [f'{chr(65 + i) if i < 26 else "A" + chr(65 + i - 26)} {exp!r} (found {header[i]!r})'
             for i, exp in BOARD_EXPECTED.items() if norm(header[i]) != norm(exp)]
    if wrong:
        die(f'{path}: required board column(s) missing or moved: ' + '; '.join(wrong))
    stamps = {}
    for i, r in enumerate(data):
        stamps.setdefault(r[0].strip(), []).append(i + 2)
    dup = {k: v for k, v in stamps.items() if len(v) > 1}
    if dup:
        die(f'{path}: rows share a Timestamp (submission identity is ambiguous): {dup}')
    name = os.path.basename(path)
    out.write(f"-- sales_board: {name} ({len(data)} rows, {len(header)} columns; AC blanked; {SCHEME} hashes; sha256 {sha})\n")
    import_sql('sales_board', name, sha, 'utf-8', ending, header, len(data), mock, out)
    out.write("insert into public.board_submissions (import_id, row_num, raw_fields, phone_sha256, email_sha256)\n"
              "select imp.id, v.n, v.f, v.ph, v.em from imp, (values\n")
    rows = []
    for i, r in enumerate(data):
        ph = phone_norm(r[9]) or phone_norm(r[38]); em = email_norm(r[8])
        f = [('' if j in BOARD_BLANK else v) for j, v in enumerate(r)]
        rows.append(f"  ({i + 1}, {arr(f)}, {h(ph)}, {h(em)})")
    out.write(",\n".join(rows))
    out.write("\n) v(n, f, ph, em);\n")
    # finalize in the same transaction: stale / reverting exports are refused by the database
    out.write(f"select public.recon_finalize_board_import(id, {'true' if ALLOW_REVERT else 'false'}) from public.recon_imports\n"
              f" where kind = 'sales_board' and file_sha256 = {lit(sha)} and finalized_at is null;\n\n")

def emit_madj(path, mock, out):
    """Hub "Manual Adjustments" tab export -> pay_adjustments (kind manual). Columns are read BY NAME. component comes from
    the row's Covers item (spiff:/comm:/xfer), else 'other'. Linked to the current board P line of that member if any.
    entered_by is set by the database (server-side); the file's "Entered By" is kept as source_entered_by only."""
    sha, ending, header, data = load(path, 'utf-8')
    missing = [c for c in MADJ_REQUIRED if c not in header]
    if missing:
        die(f'{path}: required Manual Adjustments column(s) missing: {", ".join(missing)}')
    ix = {c: header.index(c) for c in MADJ_REQUIRED}
    ci = header.index('Covers') if 'Covers' in header else None
    out.write(f"-- manual adjustments: {os.path.basename(path)} ({len(data)} rows, sha256 {sha})\n")
    for i, r in enumerate(data):
        agent, payday, amount, reason, member, by = (r[ix[c]] for c in MADJ_REQUIRED[:6])
        covers = r[ci].strip() if ci is not None else ''
        m = re.match(r'^\s*(\d{1,2})/(\d{1,2})/(\d{4})\s*$', payday)
        if not m:
            die(f'{path} line {i + 2}: Payday {payday!r} is not MM/DD/YYYY')
        mm, dd, yy = m.groups()
        mem = ''.join(ch for ch in member if ch.isdigit())
        item = covers.split(' ', 1)[1] if ' ' in covers else ''
        component = 'spiff' if item.startswith('spiff:') else 'commission' if item.startswith('comm:') else 'other'
        ref = f"{'mock-' if mock else ''}madj-{sha[:12]}-{i + 1}"
        out.write("insert into public.pay_adjustments (line_key, member_id, agent_name, payday, kind, component, amount, reason, source_entered_by, covers, external_ref)\n"
                  f"select (select b.submission_key || '-P' from public.board_submissions_current b\n"
                  f"          where b.member_id = {lit(mem)} and b.line_kind = 'premier' order by b.submitted_at limit 1),\n"
                  f"       {lit(mem) if mem else 'null'}, {lit(agent)}, date {lit(f'{yy}-{int(mm):02d}-{int(dd):02d}')}, 'manual', {lit(component)}, {money(amount, f'{path} line {i + 2}')},\n"
                  f"       {lit(reason)}, {lit(by)}, {lit(covers) if covers else 'null'}, {lit(ref)}\n"
                  "on conflict (external_ref) do nothing;\n")
    out.write("\n")

def parse_day(v, where):
    v = (v or '').strip()
    m = re.fullmatch(r'(\d{1,2})/(\d{1,2})/(\d{4})', v) or re.fullmatch(r'(\d{4})-(\d{2})-(\d{2})', v)
    if not m:
        die(f'{where}: date {v!r} is not MM/DD/YYYY or YYYY-MM-DD')
    a, b, c = m.groups()
    y, mo, d = (int(c), int(a), int(b)) if '/' in v else (int(a), int(b), int(c))
    import datetime
    try:
        day = datetime.date(y, mo, d)
    except ValueError:
        die(f'{where}: {v!r} is not a real date')
    return day

def emit_hub(path, mock, out):
    """Hub "Paid Lock" tab export -> hub_paid_lock rows + the one-time hub_cutover row (starts this system's clock)."""
    sha, ending, header, data = load(path, 'utf-8')
    missing = [c for c in HUB_REQUIRED if c not in header]
    if missing:
        die(f'{path}: required hub Paid Lock column(s) missing: {", ".join(missing)}')
    if not data:
        die(f'{path}: no rows')
    ix = {c: header.index(c) for c in header}
    rows = []
    for i, r in enumerate(data):
        w = f'{path} line {i + 2}'
        day = parse_day(r[ix['Pay Friday']], w)
        if day.weekday() != 4:
            die(f'{w}: Pay Friday {day} is not a Friday')
        agent = r[ix['Agent']].strip()
        if not agent:
            die(f'{w}: Agent is blank')
        paid = money_any(r[ix['Paid Total']], w)
        sys_t = money_any(r[ix['System Total']], w) if 'System Total' in ix and r[ix['System Total']].strip() else 'null'
        la = r[ix['Locked At (ET)']].strip()
        locked = f"(timestamp {lit(la)} at time zone 'America/New_York')" if la else 'null'
        note = lit(r[ix['Note']]) if 'Note' in ix and r[ix['Note']].strip() else 'null'
        rows.append(f"  ({lit(sha)}, {i + 1}, date {lit(day.isoformat())}, {lit(agent)}, {paid}, {sys_t}, {locked}, {note})")
    out.write(f"-- hub cutover: {os.path.basename(path)} ({len(data)} Paid Lock rows, sha256 {sha}); ONE-TIME, owner / SQL Editor only\n")
    out.write("insert into public.hub_paid_lock (file_sha256, row_num, payday, agent_name, paid_total, system_total, locked_at, note) values\n")
    out.write(",\n".join(rows) + ";\n")
    out.write(f"insert into public.hub_cutover (file_name, file_sha256, note) values ({lit(os.path.basename(path))}, {lit(sha)},"
              f" {lit(('MOCK ' if mock else '') + 'hub Paid Lock export')});\n\n")

def money_any(v, where):
    """Like money() but 0 is allowed (a hub total can be 0)."""
    t = (v or '').strip()
    if t.replace('$', '').replace(',', '').strip('() ') in ('0', '0.0', '0.00'):
        return '0.00'
    return money(v, where)

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--premier'); ap.add_argument('--board'); ap.add_argument('--madj')
    ap.add_argument('--mock', action='store_true')
    ap.add_argument('--out', help='write a 0600 SQL file (delete it after use)')
    ap.add_argument('--psql', help='stream the SQL into psql with these arguments (no file written)')
    ap.add_argument('--hub', help='hub "Paid Lock" tab CSV: one-time cutover')
    ap.add_argument('--salt-file', default=os.environ.get('RECON_HASH_SALT_FILE', DEFAULT_SALT_FILE),
                    help='HMAC salt for phone/email hashes (0600 file; required for real imports)')
    ap.add_argument('--allow-revert', action='store_true', help='finalize a board export even if it reverts a submission (after checking)')
    a = ap.parse_args()
    ALLOW_REVERT = a.allow_revert
    if not a.mock and not (a.out or a.psql):
        die('real (non --mock) imports must use --psql "<args>" (no file) or --out FILE (0600, delete after use)')
    load_salt(a.salt_file, a.mock)
    buf = io.StringIO()
    if a.premier:
        emit_premier(a.premier, a.mock, buf)
    if a.board:
        emit_board(a.board, a.mock, buf)
    if a.hub:   # after the board: recording the cutover freezes the hub-paid weeks of the board as loaded
        emit_hub(a.hub, a.mock, buf)
    if a.madj:
        emit_madj(a.madj, a.mock, buf)
    sql = buf.getvalue()
    if not a.mock:
        sql = 'begin;\n' + sql + 'commit;\n'   # one transaction: a refused board export leaves nothing behind
    if a.psql:
        r = subprocess.run(['psql', '-v', 'ON_ERROR_STOP=1', '-q'] + shlex.split(a.psql), input=sql.encode())
        sys.exit(r.returncode)
    elif a.out:
        fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(sql)
        if not a.mock:
            print(f'wrote {a.out} (0600). Delete it right after use: shred -u {shlex.quote(a.out)}', file=sys.stderr)
    else:
        sys.stdout.write(sql)
