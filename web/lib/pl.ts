// Shared helpers for the line-item P&L pages.
export type Period = 'daily' | 'weekly' | 'monthly';
export const PERIODS: Period[] = ['daily', 'weekly', 'monthly'];

export const PERIOD_VIEW: Record<Period, { view: string; key: string; keyCol: string; label: string }> = {
  daily:   { view: 'pl_daily',   key: 'day',         keyCol: 'line_date',   label: 'Daily' },
  weekly:  { view: 'pl_weekly',  key: 'week_start',  keyCol: 'week_start',  label: 'Weekly (Sun-Sat)' },
  monthly: { view: 'pl_monthly', key: 'month_start', keyCol: 'month_start', label: 'Monthly' },
};

export const isPeriod = (p: string | undefined): p is Period => !!p && (PERIODS as string[]).includes(p);
export const isIsoDate = (s: string) => /^\d{4}-\d{2}-\d{2}$/.test(s) && !Number.isNaN(Date.parse(`${s}T00:00:00Z`));

export const usd = (n: number | string | null | undefined) =>
  n == null ? '—' : Number(n).toLocaleString('en-US', { style: 'currency', currency: 'USD' });

export function addDays(iso: string, days: number): string {
  const d = new Date(`${iso}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export function periodTitle(period: Period, key: string): string {
  if (period === 'daily') return key;
  if (period === 'weekly') return `Week of Sun ${key} to Sat ${addDays(key, 6)}`;
  const d = new Date(`${key}T12:00:00Z`);
  return d.toLocaleString('en-US', { month: 'long', year: 'numeric', timeZone: 'UTC' });
}

export type Summary = {
  sales_count: number; line_count: number; revenue: string; commission: string; expenses: string; net: string;
  day?: string; week_start?: string; month_start?: string;
};
export type Line = {
  line_date: string; line_type: 'revenue' | 'commission' | 'expense'; category: string; category_label: string;
  description: string | null; source: string; amount: string; signed_amount: string;
  ref_table: string; ref_id: string; agent_name: string | null;
};

export const cell = { padding: '4px 8px', borderBottom: '1px solid #eee' } as const;
export const head = { textAlign: 'left', padding: '4px 8px', borderBottom: '1px solid #999' } as const;
export const num = { ...cell, textAlign: 'right' } as const;
