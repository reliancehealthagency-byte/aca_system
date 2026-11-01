import { notFound, redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { PERIOD_VIEW, isPeriod, isIsoDate, periodTitle, usd, head, cell, num } from '@/lib/pl';
import { loadPeriod, columnsFor, type Db } from '@/lib/plmodel';

export const dynamic = 'force-dynamic';

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

  const { model, summary, sections, error } = await loadPeriod(supabase as unknown as Db, period, key);
  const cols = columnsFor(model, period);

  return (
    <main>
      <p><a href={`/pl?period=${period}`}>← {cfg.label} P&amp;L</a></p>
      <h1>P&amp;L: {periodTitle(period, key)}</h1>
      {model === 'legacy' ? <p style={{ color: '#555' }}>Older line-item P&amp;L (premium as revenue), until the new P&amp;L is installed.</p> : null}
      {model === 'none' ? <p>No P&amp;L views are installed in the database yet.</p> : null}
      {error ? <p style={{ color: '#b00' }}>Could not load the P&amp;L lines.</p> : null}
      {summary ? (
        <dl style={{ display: 'grid', gridTemplateColumns: 'auto auto', gap: '4px 16px', maxWidth: 420 }}>
          {cols.map((c) => (
            <div key={c.key} style={{ display: 'contents' }}>
              <dt style={c.strong ? { fontWeight: 700 } : undefined}>{c.label}</dt>
              <dd style={{ margin: 0, textAlign: 'right', fontWeight: c.strong ? 700 : 400 }}>
                {c.money ? usd(summary[c.key]) : String(summary[c.key] ?? '')}
              </dd>
            </div>
          ))}
        </dl>
      ) : model === 'walk' || model === 'legacy' ? <p>No P&amp;L rows in this period.</p> : null}

      {sections.map((s) => (
        <section key={s.title} style={{ marginTop: 24 }}>
          <h2 style={{ fontSize: 20 }}>{s.sign} {s.title}</h2>
          <table style={{ borderCollapse: 'collapse', width: '100%' }}>
            <thead>
              <tr>
                <th style={head}>Date</th><th style={head}>Line</th><th style={head}>Note</th><th style={head}>By / source</th>
                <th style={{ ...head, textAlign: 'right' }}>Amount</th>
              </tr>
            </thead>
            <tbody>
              {s.rows.map((l, i) => (
                <tr key={`${s.title}-${i}`}>
                  <td style={cell}>{l.date}</td><td style={cell}>{l.label}</td><td style={cell}>{l.description}</td>
                  <td style={cell}>{l.source}</td><td style={num}>{usd(l.amount)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      ))}
    </main>
  );
}
