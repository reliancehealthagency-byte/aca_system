import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { PERIODS, PERIOD_VIEW, isPeriod, periodTitle, usd, head, cell, num, type Summary } from '@/lib/pl';

export const dynamic = 'force-dynamic';

export default async function PLIndex({ searchParams }: { searchParams: Promise<{ period?: string }> }) {
  const { period: raw } = await searchParams;
  const period = isPeriod(raw) ? raw : 'weekly';
  const cfg = PERIOD_VIEW[period];

  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) redirect('/login');
  const { data: isAdmin } = await supabase.rpc('is_admin');

  if (isAdmin !== true) {
    return (
      <main>
        <h1>P&amp;L</h1>
        <p>P&amp;L is admin-only.</p>
        <p><a href="/">Back to dashboard</a></p>
      </main>
    );
  }

  const { data, error } = await supabase
    .from(cfg.view)
    .select('*')
    .order(cfg.key, { ascending: false })
    .limit(period === 'daily' ? 62 : 60)
    .returns<Summary[]>();

  const rows = data ?? [];
  const totals = rows.reduce(
    (t, r) => ({ revenue: t.revenue + Number(r.revenue), commission: t.commission + Number(r.commission),
                 expenses: t.expenses + Number(r.expenses), net: t.net + Number(r.net) }),
    { revenue: 0, commission: 0, expenses: 0, net: 0 },
  );

  return (
    <main>
      <p><a href="/">← Dashboard</a></p>
      <h1>Line-item P&amp;L</h1>
      <nav style={{ display: 'flex', gap: 12, marginBottom: 12 }}>
        {PERIODS.map((p) => (
          <a key={p} href={`/pl?period=${p}`} style={{ fontWeight: p === period ? 700 : 400 }}>
            {PERIOD_VIEW[p].label}
          </a>
        ))}
      </nav>
      <p style={{ color: '#555' }}>
        Net = revenue lines − commission lines − expense lines. Revenue is still the placeholder (Premier premium, else the
        board claim) until the revenue-rate question is settled. Click a period to see its lines.
      </p>
      {error ? <p style={{ color: '#b00' }}>Could not load the P&amp;L.</p> : null}
      <table style={{ borderCollapse: 'collapse', width: '100%' }}>
        <thead>
          <tr>
            {['Period', 'Sales', 'Lines', 'Revenue', 'Commission', 'Expenses', 'Net'].map((h) => (
              <th key={h} style={h === 'Period' ? head : { ...head, textAlign: 'right' }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const key = String(r[cfg.key as keyof Summary]);
            return (
              <tr key={key}>
                <td style={cell}><a href={`/pl/${period}/${key}`}>{periodTitle(period, key)}</a></td>
                <td style={num}>{r.sales_count}</td>
                <td style={num}>{r.line_count}</td>
                <td style={num}>{usd(r.revenue)}</td>
                <td style={num}>{usd(r.commission)}</td>
                <td style={num}>{usd(r.expenses)}</td>
                <td style={{ ...num, fontWeight: 600, color: Number(r.net) < 0 ? '#b00' : '#070' }}>{usd(r.net)}</td>
              </tr>
            );
          })}
          {rows.length === 0 ? (
            <tr><td style={cell} colSpan={7}>No P&amp;L lines yet.</td></tr>
          ) : (
            <tr>
              <td style={{ ...cell, fontWeight: 700 }}>Total shown</td>
              <td style={num} />
              <td style={num} />
              <td style={{ ...num, fontWeight: 700 }}>{usd(totals.revenue)}</td>
              <td style={{ ...num, fontWeight: 700 }}>{usd(totals.commission)}</td>
              <td style={{ ...num, fontWeight: 700 }}>{usd(totals.expenses)}</td>
              <td style={{ ...num, fontWeight: 700 }}>{usd(totals.net)}</td>
            </tr>
          )}
        </tbody>
      </table>
    </main>
  );
}
