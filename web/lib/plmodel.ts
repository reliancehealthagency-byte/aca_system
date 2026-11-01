// P&L data layer that works against BOTH database states (deploy-order safety, slice three rev 4):
//   'walk'   = slice three applied: pl_daily_walk / pl_weekly_walk / pl_monthly_walk (+ entry, rep-pay and overhead lines)
//              Kyle 10/31: daily walk 7:19 / 7:20 PM (relayed), weekly earned + overhead 7:24 PM, old views retired 7:35 PM.
//   'legacy' = before slice three (or after its rollback): slice two's pl_daily / pl_weekly / pl_monthly / pl_line_items.
// Vercel deploys main, so this code can be live before or after the SQL is applied; it probes which views exist
// and never throws on a missing relation. No Next.js imports here, so tests/plmodel.test.mjs runs it with plain node.

export type Period = 'daily' | 'weekly' | 'monthly';
export type Model = 'walk' | 'legacy' | 'none' | 'error';
export type DbError = { code?: string; message?: string } | null;
export type Result = { data: unknown; error: DbError; count?: number | null };
// The few PostgREST builder calls used here; supabase-js satisfies it, and the tests pass a fake.
export interface Query extends PromiseLike<Result> {
  select(cols?: string, opts?: { count?: 'exact'; head?: boolean }): Query;
  eq(col: string, val: string): Query;
  gte(col: string, val: string): Query;
  lte(col: string, val: string): Query;
  order(col: string, opts?: { ascending?: boolean }): Query;
  limit(n: number): Query;
}
export interface Db { from(table: string): Query }

export type Column = { key: string; label: string; money?: boolean; strong?: boolean };
export type Row = Record<string, string | number | null>;
export type LineRow = { date: string; label: string; description: string; source: string; amount: string | number | null };
export type Section = { title: string; sign: string; rows: LineRow[] };

const PERIOD_KEY: Record<Period, string> = { daily: 'day', weekly: 'week_start', monthly: 'month_start' };
export const WALK_VIEW: Record<Period, string> = { daily: 'pl_daily_walk', weekly: 'pl_weekly_walk', monthly: 'pl_monthly_walk' };
export const LEGACY_VIEW: Record<Period, string> = { daily: 'pl_daily', weekly: 'pl_weekly', monthly: 'pl_monthly' };
export const periodKey = (p: Period) => PERIOD_KEY[p];

const m = (key: string, label: string, strong = false): Column => ({ key, label, money: true, strong });
const DAILY_COLS: Column[] = [
  m('credits', 'Credits'), m('debits', 'Debits'), m('credit_revenue', 'Credit revenue'),
  m('transfers_ringba', 'Transfers: Ringba'), m('transfers_acme', 'Transfers: Acme'), m('total_spend', 'Lead spend'),
  m('deal_commission', 'Deal commission'), m('spiffs', 'Spiffs'), m('abs_pay', 'ABS pay'),
  m('projected_commission', 'Projected rep pay'), m('net', 'Net', true),
];
const WEEK_COLS: Column[] = [
  m('credit_revenue', 'Credit revenue'), m('transfer_revenue', 'Transfers'), m('total_spend', 'Lead spend'),
  m('projected_commission', 'Projected rep pay'), m('daily_net', 'Daily nets'),
  m('allstate_earned', 'Allstate Earned'), m('premier_book', 'Premier Book'), m('neo_book', 'Neo Book'), m('oneil_aca', "O'Neil ACA"),
  m('overhead', 'Overhead'), m('net', 'Net', true),
];
export const WALK_COLUMNS: Record<Period, Column[]> = { daily: DAILY_COLS, weekly: WEEK_COLS, monthly: WEEK_COLS };
const LEGACY_COLS: Column[] = [
  { key: 'sales_count', label: 'Sales' }, { key: 'line_count', label: 'Lines' }, m('revenue', 'Revenue'),
  m('commission', 'Commission'), m('expenses', 'Expenses'), m('net', 'Net', true),
];
export const LEGACY_COLUMNS: Record<Period, Column[]> = { daily: LEGACY_COLS, weekly: LEGACY_COLS, monthly: LEGACY_COLS };
export const columnsFor = (model: Model, p: Period) => (model === 'walk' ? WALK_COLUMNS[p] : LEGACY_COLUMNS[p]);

// "relation does not exist" as PostgREST reports it (schema cache miss PGRST205 / PGRST200, or Postgres 42P01).
export function isMissingRelation(err: DbError): boolean {
  if (!err) return false;
  if (err.code === 'PGRST205' || err.code === 'PGRST200' || err.code === '42P01') return true;
  return /does not exist|schema cache|could not find the table/i.test(err.message ?? '');
}

export async function detectModel(db: Db): Promise<Model> {
  const walk = await db.from('pl_weekly_walk').select('week_start').limit(1);
  if (!walk.error) return 'walk';
  if (!isMissingRelation(walk.error)) return 'error';
  const legacy = await db.from('pl_weekly').select('week_start').limit(1);
  if (!legacy.error) return 'legacy';
  return isMissingRelation(legacy.error) ? 'none' : 'error';
}

const rowsOf = (r: Result) => (Array.isArray(r.data) ? (r.data as Row[]) : []);

export async function loadIndex(db: Db, period: Period) {
  const model = await detectModel(db);
  if (model !== 'walk' && model !== 'legacy') return { model, rows: [] as Row[], error: model === 'error', unpriced: null as number | null };
  const view = model === 'walk' ? WALK_VIEW[period] : LEGACY_VIEW[period];
  const res = await db.from(view).select('*').order(PERIOD_KEY[period], { ascending: false }).limit(period === 'daily' ? 62 : 60);
  let unpriced: number | null = null;
  if (model === 'legacy') {
    const u = await db.from('pl_unpriced_sales').select('sale_id', { count: 'exact', head: true });
    unpriced = u.error ? null : (u.count ?? 0);
  }
  return { model, rows: rowsOf(res), error: !!res.error, unpriced };
}

function weekEnd(iso: string) {
  const d = new Date(`${iso}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + 6); return d.toISOString().slice(0, 10);
}
function monthEnd(iso: string) {
  const d = new Date(`${iso}T12:00:00Z`); d.setUTCMonth(d.getUTCMonth() + 1, 0); return d.toISOString().slice(0, 10);
}

export async function loadPeriod(db: Db, period: Period, key: string) {
  const model = await detectModel(db);
  const sections: Section[] = [];
  if (model !== 'walk' && model !== 'legacy') return { model, summary: null as Row | null, sections, error: model === 'error' };
  let error = false;
  if (model === 'walk') {
    const sum = await db.from(WALK_VIEW[period]).select('*').eq(PERIOD_KEY[period], key).limit(1);
    const lineCol = period === 'daily' ? 'line_date' : PERIOD_KEY[period];
    const lines = await db.from('pl_manual_entry_lines').select('*').eq(lineCol, key).order('line_date');
    const end = period === 'daily' ? key : period === 'weekly' ? weekEnd(key) : monthEnd(key);
    const rep = await db.from('pl_projected_rep_pay_daily').select('*').gte('day', key).lte('day', end).order('day');
    error = !!(sum.error || lines.error || rep.error);
    const all = rowsOf(lines);
    const pick = (cats: string[], weeklyOnly = false) => all
      .filter((l) => cats.includes(String(l.category)) && (!weeklyOnly || period !== 'daily'))
      .map((l) => ({ date: String(l.line_date), label: String(l.category_label), description: String(l.description ?? ''),
                     source: String(l.entered_by ?? ''), amount: l.amount }));
    sections.push({ title: 'Credit revenue (credits − debits)', sign: '+', rows: pick(['credits', 'debits']) });
    sections.push({ title: 'Transfers', sign: '+', rows: pick(['transfers_ringba', 'transfers_acme']) });
    sections.push({ title: 'Lead spend', sign: '−', rows: pick(['lead_spend']) });
    sections.push({ title: 'Projected rep pay (deal commission + spiffs + ABS)', sign: '−', rows: rowsOf(rep).flatMap((r) => [
      { date: String(r.day), label: 'Deal commission', description: `${r.line_count} line(s)`, source: 'recon', amount: r.deal_commission },
      { date: String(r.day), label: 'Spiffs', description: '', source: 'recon', amount: r.spiffs },
      { date: String(r.day), label: 'ABS pay', description: '', source: 'recon', amount: r.abs_pay },
    ]) });
    if (period !== 'daily') {
      sections.push({ title: 'Weekly earned sources', sign: '+',
        rows: pick(['allstate_earned', 'deposit_premier_book', 'deposit_neo_book', 'deposit_oneil_aca'], true) });
      const oh = period === 'weekly'
        ? await db.from('pl_overhead_weekly').select('*').eq('week_start', key).order('source_name')
        : await db.from('pl_overhead_monthly').select('*').eq('month_start', key).order('source_name');
      error = error || !!oh.error;
      sections.push({ title: 'Overhead', sign: '−', rows: rowsOf(oh).map((o) => ({
        date: String(o.month_start), label: String(o.source_name),
        description: period === 'weekly' ? `${o.days_in_month}/${o.days_of_month} days of the month (prorated)` : 'full month',
        source: 'overhead', amount: o.amount })) });
    }
    sections.push({ title: 'Entered for reference (not in net)', sign: '', rows: pick(['premier_premium_entered', 'policy_count']) });
    return { model, summary: rowsOf(sum)[0] ?? null, sections: sections.filter((s) => s.rows.length > 0), error };
  }
  const keyCol = period === 'daily' ? 'line_date' : PERIOD_KEY[period];
  const sum = await db.from(LEGACY_VIEW[period]).select('*').eq(PERIOD_KEY[period], key).limit(1);
  const lines = await db.from('pl_line_items').select('*').eq(keyCol, key).order('line_date');
  error = !!(sum.error || lines.error);
  for (const [type, title, sign] of [['revenue', 'Revenue', '+'], ['commission', 'Agent commission', '−'], ['expense', 'Expenses', '−']]) {
    sections.push({ title, sign, rows: rowsOf(lines).filter((l) => l.line_type === type).map((l) => ({
      date: String(l.line_date), label: String(l.category_label), description: String(l.description ?? ''),
      source: String(l.source ?? ''), amount: l.amount })) });
  }
  return { model, summary: rowsOf(sum)[0] ?? null, sections: sections.filter((s) => s.rows.length > 0), error };
}

// Dashboard cards: today + this week, from whichever P&L exists.
export async function loadDashboard(db: Db, today: string, weekStart: string) {
  const model = await detectModel(db);
  if (model === 'walk') {
    const [d, w] = [await db.from('pl_daily_walk').select('*').eq('day', today).limit(1),
                    await db.from('pl_weekly_walk').select('*').eq('week_start', weekStart).limit(1)];
    return { model, daily: rowsOf(d)[0] ?? null, weekly: rowsOf(w)[0] ?? null,
             dailyCols: WALK_COLUMNS.daily, weeklyCols: WALK_COLUMNS.weekly, error: !!(d.error || w.error) };
  }
  if (model === 'legacy') {
    const [d, w] = [await db.from('pl_daily').select('*').eq('day', today).limit(1),
                    await db.from('pl_weekly').select('*').eq('week_start', weekStart).limit(1)];
    return { model, daily: rowsOf(d)[0] ?? null, weekly: rowsOf(w)[0] ?? null,
             dailyCols: LEGACY_COLS, weeklyCols: LEGACY_COLS, error: !!(d.error || w.error) };
  }
  return { model, daily: null, weekly: null, dailyCols: [] as Column[], weeklyCols: [] as Column[], error: model === 'error' };
}
