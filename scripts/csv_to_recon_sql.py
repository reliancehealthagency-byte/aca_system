#!/usr/bin/env python3
"""Turn a Premier "Member Products" CSV, a Sales Board "Form Responses 1" CSV and/or a hub "Manual Adjustments" CSV into
idempotent SQL inserts for the slice-three staging tables.

DATA MINIMIZATION (rev 2): client data never leaves this script.
  * Premier: only the reconciliation allow-list is kept (ALLOWED below + every '* Fee' column). Names, phones, emails,
    gender, city/state/address-type, company, ethnicity/height/weight/disability, refund comments etc. are DROPPED.
  * Board: all 42 positions A..AP are kept (letters stay stable) but H Customer Name, I Customer Email, J Customer Phone,
    N Email, V Client Name, AC Income and AM Phone Number are BLANKED.
  * For matching only, the normalized phone (last 10 digits) and email (trimmed, lower-case) are hashed: sha256, or
    HMAC-sha256 when RECON_HASH_SALT is set (recommended for real data: a 10-digit phone hash alone is guessable).
    Use the same salt for every import, or hashes won't match across files.
HEADER CONTRACT: every column the database reads must be present BY NAME (Premier) or by position + name (board, the
live Sales Board A..AP). Anything missing stops the script with a clear error before any SQL is written.
OUTPUT: --mock may write to stdout. Real (non --mock) files must use either
  --psql "<psql args>"  stream the SQL straight into psql (nothing written to disk), or
  --out /tmp/<file>.sql  a 0600 file that you delete right after use (e.g. `shred -u FILE`); the script prints a reminder.
The generated SQL holds no client names/phones/emails, but it does hold member IDs and pay data: don't leave it on the box.

  python3 scripts/csv_to_recon_sql.py --premier PHS.csv --board BOARD.csv [--madj MADJ.csv] (--mock | --out F | --psql ARGS)
"""
import argparse, csv, hashlib, hmac, io, os, re, shlex, subprocess, sys

PREMIER_REQUIRED = ['Member ID', 'Product ID', 'Product Label', 'Product Benefit', 'Period Label', 'Agent Label',
                    'Member Created Date', 'Product Created Date', 'Active Date', 'First Billing Date', 'Next Billing Date',
                    'Inactive Date', 'Hold Date', 'Hold Reason', 'Paid', 'Last Payment', 'Refund Requested', 'Refund Provided',
                    'Refund Provided Date', 'Product Fee', 'Enrollment Fee', 'EnrollmentProcessingFee Fee', 'ApplicationFee Fee',
                    'AWALifetimeMembership Fee']
PREMIER_ALLOWED = PREMIER_REQUIRED + ['Agent ID', 'Agent Code', 'Inactive Reason', 'Product Status', 'Paytype',
                                      'Refund Requested Date', 'Next Billing Amount', 'Inactive Date Set']
PREMIER_HASH_SRC = {'phone': 'Phone 1', 'email': 'Email'}          # required: used only to build the hashes
# live Sales Board A..AP: (index, expected header); only these positions are checked
BOARD_EXPECTED = {0: 'Timestamp', 1: 'Member ID', 2: 'Date Booked', 4: 'Active Date', 5: 'Agent', 6: 'Premium',
                  7: 'Customer Name', 8: 'Customer Email', 9: 'Customer Phone', 12: 'Post Date', 13: 'Email',
                  15: 'ABS Addon?', 17: 'Deal Type', 18: 'Agent', 20: 'FFM', 21: 'Client Name', 24: 'Date Booked',
                  28: 'Income', 31: 'Premier/Neo Addon?', 32: 'Premier/Neo Member ID', 33: 'Premier/Neo Premium',
                  34: 'ABS Addon?', 35: 'ABS Member ID', 36: 'ABS Premium', 38: 'Phone Number',
                  40: 'Increased Comm/Spiff Product?', 41: 'Agent'}
BOARD_COLS = 42
BOARD_BLANK = [7, 8, 9, 13, 21, 28, 38]                              # H I J N V AC AM
MADJ_REQUIRED = ['Agent', 'Payday', 'Amount', 'Reason/Note', 'Member ID', 'Entered By', 'Date Entered']   # + optional Covers

def die(msg):
    sys.exit('csv_to_recon_sql: ' + msg)

def norm(h):
    return re.sub(r'\s+', ' ', h.strip()).lower()

def lit(s):
    return "'" + s.replace("'", "''") + "'"

def arr(fields):
    return "array[" + ",".join(lit(f) for f in fields) + "]::text[]"

SALT = os.environ.get('RECON_HASH_SALT', '').encode()
SCHEME = 'hmac-sha256' if SALT else 'sha256'

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
              f" {lit(('MOCK data from /workspace/artifacts/premier_mock (Payroll, 10/31); ' if mock else '') + 'minimized by scripts/csv_to_recon_sql.py (client PII dropped/blanked, ' + SCHEME + ' hashes)')})\n"
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
    out.write(f"-- premier_member_products: {name} ({len(data)} rows; kept {len(kh)} of {len(header)} columns, client PII dropped; {SCHEME} hashes; sha256 {sha})\n")
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
    out.write(f"-- sales_board: {name} ({len(data)} rows, {len(header)} columns; H I J N V AC AM blanked; {SCHEME} hashes; sha256 {sha})\n")
    import_sql('sales_board', name, sha, 'utf-8', ending, header, len(data), mock, out)
    out.write("insert into public.board_submissions (import_id, row_num, raw_fields, phone_sha256, email_sha256)\n"
              "select imp.id, v.n, v.f, v.ph, v.em from imp, (values\n")
    rows = []
    for i, r in enumerate(data):
        ph = phone_norm(r[9]) or phone_norm(r[38]); em = email_norm(r[8])
        f = [('' if j in BOARD_BLANK else v) for j, v in enumerate(r)]
        rows.append(f"  ({i + 1}, {arr(f)}, {h(ph)}, {h(em)})")
    out.write(",\n".join(rows))
    out.write("\n) v(n, f, ph, em);\n\n")

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
                  f"       {lit(mem) if mem else 'null'}, {lit(agent)}, date {lit(f'{yy}-{int(mm):02d}-{int(dd):02d}')}, 'manual', {lit(component)}, {amount},\n"
                  f"       {lit(reason)}, {lit(by)}, {lit(covers) if covers else 'null'}, {lit(ref)}\n"
                  "on conflict (external_ref) do nothing;\n")
    out.write("\n")

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--premier'); ap.add_argument('--board'); ap.add_argument('--madj')
    ap.add_argument('--mock', action='store_true')
    ap.add_argument('--out', help='write a 0600 SQL file (delete it after use)')
    ap.add_argument('--psql', help='stream the SQL into psql with these arguments (no file written)')
    a = ap.parse_args()
    if not a.mock and not (a.out or a.psql):
        die('real (non --mock) imports must use --psql "<args>" (no file) or --out FILE (0600, delete after use)')
    buf = io.StringIO()
    if a.premier:
        emit_premier(a.premier, a.mock, buf)
    if a.board:
        emit_board(a.board, a.mock, buf)
    if a.madj:
        emit_madj(a.madj, a.mock, buf)
    sql = buf.getvalue()
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
