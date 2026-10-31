import { notFound, redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { PERIOD_VIEW, isPeriod, isIsoDate, periodTitle, usd, head, cell, num, type Line, type Summary } from '@/lib/pl';

export const dynamic = 'force-dynamic';

const TYPES: { type: Line['line_type']; label: string; sign: string }[] = [
  { type: 'revenue', label: 'Revenue', sign: '+' },
  { type: 'commission', label: 'Agent commission', sign: '−' },
  { type: 'expense', label: 'Expenses', sign: '−' },
];

export default async function PLPeriod({ params }: { params: Promise<{ period: string; key: string }> }) {
  const { period, key } = await params;
  if (!isPeriod(period) || !isIsoDate(key)) notFound();
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

  const [summary, lines] = await Promise.all([
    supabase.from(cfg.view).select('*').eq(cfg.key, key).maybeSingle<Summary>(),
    supabase
      .from('pl_line_items')
      .select('line_date, line_type, category, category_label, description, source, amount, signed_amount, ref_table, ref_id, agent_name')
      .eq(cfg.keyCol, key)
      .order('line_date', { ascending: true })
      .order('category', { ascending: true })
      .limit(5000)
      .returns<Line[]>(),
  ]);
  const all = lines.data ?? [];
  const s = summary.data;

  return (
    <main>
      <p><a href={`/pl?period=${period}`}>← {cfg.label} P&amp;L</a></p>
      <h1>P&amp;L: {periodTitle(period, key)}</h1>
      {lines.error || summary.error ? <p style={{ color: '#b00' }}>Could not load the P&amp;L lines.</p> : null}
      {s ? (
        <p>
          Revenue <strong>{usd(s.revenue)}</strong> − commission <strong>{usd(s.commission)}</strong> − expenses{' '}
          <strong>{usd(s.expenses)}</strong> = net{' '}
          <strong style={{ color: Number(s.net) < 0 ? '#b00' : '#070' }}>{usd(s.net)}</strong>{' '}
          ({s.sales_count} sales, {s.line_count} lines)
        </p>
      ) : (
        <p>No P&amp;L lines in this period.</p>
      )}

      {TYPES.map(({ type, label, sign }) => {
        const ofType = all.filter((l) => l.line_type === type);
        if (ofType.length === 0) return null;
        const cats = Array.from(new Set(ofType.map((l) => l.category)));
        const typeTotal = ofType.reduce((t, l) => t + Number(l.amount), 0);
        return (
          <section key={type} style={{ marginTop: 24 }}>
            <h2 style={{ fontSize: 20 }}>
              {sign} {label}: {usd(typeTotal)}
            </h2>
            {cats.map((cat) => {
              const rows = ofType.filter((l) => l.category === cat);
              const catTotal = rows.reduce((t, l) => t + Number(l.amount), 0);
              return (
                <details key={cat} open style={{ marginBottom: 12 }}>
                  <summary style={{ cursor: 'pointer' }}>
                    <strong>{rows[0].category_label}</strong>: {usd(catTotal)} ({rows.length} line{rows.length === 1 ? '' : 's'})
                  </summary>
                  <table style={{ borderCollapse: 'collapse', width: '100%', marginTop: 4 }}>
                    <thead>
                      <tr>
                        <th style={head}>Date</th>
                        <th style={head}>Description</th>
                        <th style={head}>Agent</th>
                        <th style={head}>Source</th>
                        <th style={{ ...head, textAlign: 'right' }}>Amount</th>
                      </tr>
                    </thead>
                    <tbody>
                      {rows.map((l) => (
                        <tr key={`${l.ref_table}-${l.ref_id}-${l.category}`}>
                          <td style={cell}>{l.line_date}</td>
                          <td style={cell}>{l.description ?? ''}</td>
                          <td style={cell}>{l.agent_name ?? ''}</td>
                          <td style={cell}>{l.source}</td>
                          <td style={num}>{usd(l.amount)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </details>
              );
            })}
          </section>
        );
      })}
    </main>
  );
}
