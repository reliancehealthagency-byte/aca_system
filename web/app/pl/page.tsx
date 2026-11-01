import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { PERIODS, PERIOD_VIEW, isPeriod, periodTitle, usd, head, cell, num } from '@/lib/pl';
import { loadIndex, columnsFor, periodKey, type Db } from '@/lib/plmodel';

export const dynamic = 'force-dynamic';

export default async function PLIndex({ searchParams }: { searchParams: Promise<{ period?: string }> }) {
  const { period: raw } = await searchParams;
  const period = isPeriod(raw) ? raw : 'weekly';

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

  const { model, rows, error, unpriced } = await loadIndex(supabase as unknown as Db, period);
  const cols = columnsFor(model, period);
  const key = periodKey(period);

  return (
    <main>
      <p><a href="/">← Dashboard</a></p>
      <h1>P&amp;L</h1>
      <nav style={{ display: 'flex', gap: 12, marginBottom: 12 }}>
        {PERIODS.map((p) => (
          <a key={p} href={`/pl?period=${p}`} style={{ fontWeight: p === period ? 700 : 400 }}>
            {PERIOD_VIEW[p].label}
          </a>
        ))}
      </nav>
      {model === 'walk' ? (
        <p style={{ color: '#555' }}>
          {period === 'daily'
            ? 'Daily net = (credits − debits) + transfers − lead spend − projected rep pay (deal commission + spiffs + ABS).'
            : 'Net = the daily nets + Allstate Earned, Premier Book, Neo Book and O\u2019Neil ACA − overhead (monthly overhead prorated by days).'}{' '}
          Click a period to see its lines.
        </p>
      ) : null}
      {model === 'legacy' ? (
        <p style={{ color: '#555' }}>
          Older line-item P&amp;L (premium as revenue), shown until the new P&amp;L is installed in the database.
          {unpriced != null ? ` Unpriced sales: ${unpriced}.` : ''}
        </p>
      ) : null}
      {model === 'none' ? <p>No P&amp;L views are installed in the database yet.</p> : null}
      {error ? <p style={{ color: '#b00' }}>Could not load the P&amp;L.</p> : null}
      {cols.length > 0 ? (
        <table style={{ borderCollapse: 'collapse', width: '100%' }}>
          <thead>
            <tr>
              <th style={head}>Period</th>
              {cols.map((c) => <th key={c.key} style={{ ...head, textAlign: 'right' }}>{c.label}</th>)}
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const k = String(r[key]);
              return (
                <tr key={k}>
                  <td style={cell}><a href={`/pl/${period}/${k}`}>{periodTitle(period, k)}</a></td>
                  {cols.map((c) => (
                    <td key={c.key} style={c.strong ? { ...num, fontWeight: 600, color: Number(r[c.key]) < 0 ? '#b00' : '#070' } : num}>
                      {c.money ? usd(r[c.key]) : String(r[c.key] ?? '')}
                    </td>
                  ))}
                </tr>
              );
            })}
            {rows.length === 0 ? <tr><td style={cell} colSpan={cols.length + 1}>No P&amp;L rows yet.</td></tr> : null}
          </tbody>
        </table>
      ) : null}
    </main>
  );
}
