import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';

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

type PL = { sales_count: number; premium_total: string; agent_commission: string; expenses: string; net_placeholder: string };
type SaleRow = {
  id: string; sale_date: string; agent_name: string | null; carrier: string | null; board_premium: string | null;
  premier_premium: string | null; premium_source: string | null; commission_rate: string; commission: string | null;
  commission_estimate: string | null; commission_pay_friday: string;
};

function PLCard({ title, pl, admin }: { title: string; pl: PL | null; admin: boolean }) {
  return (
    <section style={{ border: '1px solid #ccc', borderRadius: 8, padding: 16, minWidth: 260 }}>
      <h2 style={{ marginTop: 0, fontSize: 18 }}>{title}</h2>
      {!admin ? (
        <p>P&amp;L is admin-only.</p>
      ) : (
        <dl style={{ display: 'grid', gridTemplateColumns: 'auto auto', gap: '4px 16px', margin: 0 }}>
          <dt>Sales</dt><dd style={{ margin: 0 }}>{pl?.sales_count ?? 0}</dd>
          <dt>Premium</dt><dd style={{ margin: 0 }}>{usd(pl?.premium_total ?? 0)}</dd>
          <dt>Agent commission</dt><dd style={{ margin: 0 }}>{usd(pl?.agent_commission ?? 0)}</dd>
          <dt>Expenses</dt><dd style={{ margin: 0 }}>{usd(pl?.expenses ?? 0)}</dd>
          <dt><strong>Net (placeholder)</strong></dt><dd style={{ margin: 0 }}><strong>{usd(pl?.net_placeholder ?? 0)}</strong></dd>
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

  const [{ data: isAdmin }, daily, weekly, sales] = await Promise.all([
    supabase.rpc('is_admin'),
    supabase.from('daily_pl').select('*').eq('day', today).maybeSingle<PL>(),
    supabase.from('weekly_pl').select('*').eq('week_start', weekStart).maybeSingle<PL>(),
    supabase
      .from('sales_commission')
      .select('id, sale_date, agent_name, carrier, board_premium, premier_premium, premium_source, commission_rate, commission, commission_estimate, commission_pay_friday')
      .order('sale_date', { ascending: false })
      .order('created_at', { ascending: false })
      .limit(10)
      .returns<SaleRow[]>(),
  ]);
  const admin = isAdmin === true;

  return (
    <main>
      <header style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <h1 style={{ margin: 0 }}>Reliance backend: slice one (seed data)</h1>
        <form action="/auth/signout" method="post">
          <span style={{ marginRight: 12 }}>{auth.user.email}{admin ? ' (admin)' : ''}</span>
          <a href="/account" style={{ marginRight: 12 }}>Change password</a>
          <button type="submit">Sign out</button>
        </form>
      </header>
      <p style={{ color: '#555' }}>
        Today {today} (ET). Week starts Sunday {weekStart}. Net is a placeholder: premium minus agent commission minus
        expenses, pending the 42% vs 38%/43% revenue question.
      </p>

      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
        <PLCard title={`Today's P&L (${today})`} pl={daily.data ?? null} admin={admin} />
        <PLCard title={`This week (from ${weekStart})`} pl={weekly.data ?? null} admin={admin} />
      </div>

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
