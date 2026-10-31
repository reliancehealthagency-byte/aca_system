import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import { loadDashboard, type Db, type Row, type Column } from '@/lib/plmodel';

export const dynamic = 'force-dynamic';

const TZ = 'America/New_York';
const usd = (n: number | string | null | undefined) =>
  n == null ? '—' : Number(n).toLocaleString('en-US', { style: 'currency', currency: 'USD' });

function todayET(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
}
function weekStartSunday(isoDay: string): string {
  const d = new Date(`${isoDay}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() - d.getUTCDay());
  return d.toISOString().slice(0, 10);
}

type SaleRow = {
  id: string; sale_date: string; agent_name: string | null; carrier: string | null; board_premium: string | null;
  premier_premium: string | null; premium_source: string | null; commission_rate: string; commission: string | null;
  commission_estimate: string | null; commission_pay_friday: string;
};

function PLCard({ title, row, cols, admin }: { title: string; row: Row | null; cols: Column[]; admin: boolean }) {
  return (
    <section style={{ border: '1px solid #ccc', borderRadius: 8, padding: 16, minWidth: 260 }}>
      <h2 style={{ marginTop: 0, fontSize: 18 }}>{title}</h2>
      {!admin ? (
        <p>P&amp;L is admin-only.</p>
      ) : cols.length === 0 ? (
        <p>No P&amp;L installed yet.</p>
      ) : (
        <dl style={{ display: 'grid', gridTemplateColumns: 'auto auto', gap: '4px 16px', margin: 0 }}>
          {cols.map((c) => (
            <div key={c.key} style={{ display: 'contents' }}>
              <dt>{c.strong ? <strong>{c.label}</strong> : c.label}</dt>
              <dd style={{ margin: 0 }}>{c.money ? usd(row?.[c.key] ?? 0) : String(row?.[c.key] ?? 0)}</dd>
            </div>
          ))}
        </dl>
      )}
    </section>
  );
}

export default async function Dashboard() {
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) redirect('/login');

  const today = todayET();
  const weekStart = weekStartSunday(today);

  const [{ data: isAdmin }, sales] = await Promise.all([
    supabase.rpc('is_admin'),
    supabase
      .from('sales_commission')
      .select('id, sale_date, agent_name, carrier, board_premium, premier_premium, premium_source, commission_rate, commission, commission_estimate, commission_pay_friday')
      .order('sale_date', { ascending: false })
      .order('created_at', { ascending: false })
      .limit(10)
      .returns<SaleRow[]>(),
  ]);
  const pl = isAdmin === true ? await loadDashboard(supabase as unknown as Db, today, weekStart) : null;
  const admin = isAdmin === true;

  return (
    <main>
      <header style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <h1 style={{ margin: 0 }}>Reliance backend (seed data)</h1>
        <form action="/auth/signout" method="post">
          <span style={{ marginRight: 12 }}>{auth.user.email}{admin ? ' (admin)' : ''}</span>
          {admin ? <a href="/pl" style={{ marginRight: 12 }}>P&amp;L drill-down</a> : null}
          <a href="/account" style={{ marginRight: 12 }}>Change password</a>
          <button type="submit">Sign out</button>
        </form>
      </header>
      <p style={{ color: '#555' }}>
        Today {today} (ET). Week starts Sunday {weekStart}.{' '}
        {pl?.model === 'walk' ? 'Daily net = (credits − debits) + transfers − lead spend − projected rep pay; the week adds the four earned sources and subtracts overhead.' : null}
        {pl?.model === 'legacy' ? 'Older P&L (premium as revenue) until the new P&L is installed.' : null}
      </p>

      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
        <PLCard title={`Today's P&L (${today})`} row={pl?.daily ?? null} cols={pl?.dailyCols ?? []} admin={admin} />
        <PLCard title={`This week (from ${weekStart})`} row={pl?.weekly ?? null} cols={pl?.weeklyCols ?? []} admin={admin} />
      </div>
      {admin ? (
        <p>
          Lines: <a href={`/pl/daily/${today}`}>today</a> · <a href={`/pl/weekly/${weekStart}`}>this week</a> ·{' '}
          <a href={`/pl/monthly/${today.slice(0, 8)}01`}>this month</a> · <a href="/pl">all periods</a>
        </p>
      ) : null}

      <h2>Recent sales</h2>
      {sales.error ? <p style={{ color: '#b00' }}>Could not load sales.</p> : null}
      <table style={{ borderCollapse: 'collapse', width: '100%' }}>
        <thead>
          <tr>
            {['Date booked', 'Agent of record', 'Carrier', 'Board (claim)', 'Premier (truth)', 'Rate', 'Commission', 'Pays Friday'].map((h) => (
              <th key={h} style={{ textAlign: 'left', borderBottom: '1px solid #999', padding: 4 }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {(sales.data ?? []).map((s) => (
            <tr key={s.id}>
              <td style={{ padding: 4 }}>{s.sale_date}</td>
              <td style={{ padding: 4 }}>{s.agent_name}</td>
              <td style={{ padding: 4 }}>{s.carrier}</td>
              <td style={{ padding: 4 }}>{usd(s.board_premium)}</td>
              <td style={{ padding: 4 }}>{s.premier_premium == null ? 'pending' : usd(s.premier_premium)}</td>
              <td style={{ padding: 4 }}>{(Number(s.commission_rate) * 100).toFixed(0)}%</td>
              <td style={{ padding: 4 }}>
                {s.commission != null ? usd(s.commission) : `${usd(s.commission_estimate)} (est.)`}
              </td>
              <td style={{ padding: 4 }}>{s.commission_pay_friday}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </main>
  );
}
