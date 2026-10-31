#!/usr/bin/env python3
"""Turn a Premier "Member Products" CSV and/or a Sales Board "Form Responses 1" CSV into idempotent SQL inserts for the
slice-three staging tables. Every raw field is kept as-is (raw_fields text[]); parsing happens in the database trigger.

  python3 scripts/csv_to_recon_sql.py --premier PHS.csv --board BOARD.csv [--mock] > out.sql

Premier files are cp1252 / CRLF (hub-ingested shape: 132 columns, PII already dropped). Board files are UTF-8 / CRLF,
42 columns A..AP. Re-running the SQL is a no-op: an import is keyed by the sha256 of the raw file bytes.
"""
import argparse, csv, hashlib, io, os, sys

def lit(s):
    return "'" + s.replace("'", "''") + "'"

def arr(fields):
    return "array[" + ",".join(lit(f) for f in fields) + "]::text[]"

def load(path, encoding, expect_cols):
    raw = open(path, 'rb').read()
    text = raw.decode(encoding)
    crlf = text.count('\r\n'); lf = text.count('\n')
    rows = list(csv.reader(io.StringIO(text, newline='')))
    while rows and rows[-1] == []:
        rows.pop()
    header, data = rows[0], rows[1:]
    if expect_cols and len(header) != expect_cols:
        sys.exit(f"{path}: expected {expect_cols} columns, found {len(header)}")
    bad = [i + 2 for i, r in enumerate(data) if len(r) != len(header)]
    if bad:
        sys.exit(f"{path}: rows with the wrong field count at lines {bad[:10]}")
    ending = 'CRLF' if crlf and crlf >= lf - sum(f.count('\n') for r in rows for f in r) else 'LF'
    return hashlib.sha256(raw).hexdigest(), ending, header, data

def emit(kind, table, path, encoding, expect_cols, mock, out):
    sha, ending, header, data = load(path, encoding, expect_cols)
    name = os.path.basename(path)
    out.write(f"-- {kind}: {name} ({len(data)} rows, {len(header)} columns, {encoding}, {ending}, sha256 {sha})\n")
    out.write(f"with imp as (\n  insert into public.recon_imports (kind, file_name, file_sha256, encoding, line_ending, header, row_count, is_mock, note)\n"
              f"  values ({lit(kind)}, {lit(name)}, {lit(sha)}, {lit(encoding)}, {lit(ending)}, {arr(header)}, {len(data)}, {'true' if mock else 'false'},"
              f" {lit('MOCK data from /workspace/artifacts/premier_mock (Payroll, 10/31)' if mock else 'ingested by scripts/csv_to_recon_sql.py')})\n"
              f"  on conflict (kind, file_sha256) do nothing returning id)\n"
              f"insert into public.{table} (import_id, row_num, raw_fields)\nselect imp.id, v.n, v.f from imp, (values\n")
    out.write(",\n".join(f"  ({i + 1}, {arr(r)})" for i, r in enumerate(data)))
    out.write("\n) v(n, f);\n\n")

def emit_madj(path, mock, out):
    """Hub "Manual Adjustments" tab export (Agent, Payday, Amount, Reason/Note, Member ID, Entered By, Date Entered, Covers)
    -> pay_adjustments (kind manual). Linked to the board line of that member when one exists."""
    sha, ending, header, data = load(path, 'utf-8', 8)
    out.write(f"-- manual adjustments: {os.path.basename(path)} ({len(data)} rows, sha256 {sha})\n")
    for i, r in enumerate(data):
        agent, payday, amount, reason, member, by, entered, covers = r
        m, d, y = payday.split('/')
        mem = ''.join(ch for ch in member if ch.isdigit())
        ref = f"{'mock-' if mock else ''}madj-{sha[:12]}-{i + 1}"
        out.write("insert into public.pay_adjustments (line_key, member_id, agent_name, payday, kind, component, amount, reason, entered_by, covers, external_ref)\n"
                  f"select (select to_char(b.submitted_at at time zone 'America/New_York', 'YYYYMMDDHH24MISS') || '-' || b.member_id || '-P'\n"
                  f"          from public.board_submissions b where b.member_id = {lit(mem)} and b.line_kind = 'premier' order by b.submitted_at limit 1),\n"
                  f"       {lit(mem) if mem else 'null'}, {lit(agent)}, date {lit(f'{y}-{int(m):02d}-{int(d):02d}')}, 'manual', 'spiff', {amount},\n"
                  f"       {lit(reason)}, {lit(by)}, {lit(covers) if covers.strip() else 'null'}, {lit(ref)}\n"
                  "on conflict (external_ref) do nothing;\n")
    out.write("\n")

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--premier'); ap.add_argument('--board'); ap.add_argument('--madj'); ap.add_argument('--mock', action='store_true')
    a = ap.parse_args()
    o = sys.stdout
    if a.premier:
        emit('premier_member_products', 'premier_member_products', a.premier, 'cp1252', 132, a.mock, o)
    if a.board:
        emit('sales_board', 'board_submissions', a.board, 'utf-8', 42, a.mock, o)
    if a.madj:
        emit_madj(a.madj, a.mock, o)
