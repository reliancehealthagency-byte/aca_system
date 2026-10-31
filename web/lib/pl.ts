// Shared helpers for the P&L pages (data loading for both database states lives in plmodel.ts).
export type Period = 'daily' | 'weekly' | 'monthly';
export const PERIODS: Period[] = ['daily', 'weekly', 'monthly'];

export const PERIOD_VIEW: Record<Period, { view: string; key: string; keyCol: string; label: string }> = {
  daily:   { view: 'pl_daily_walk',   key: 'day',         keyCol: 'line_date',   label: 'Daily' },
  weekly:  { view: 'pl_weekly_walk',  key: 'week_start',  keyCol: 'week_start',  label: 'Weekly (Sun-Sat)' },
  monthly: { view: 'pl_monthly_walk', key: 'month_start', keyCol: 'month_start', label: 'Monthly' },
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

export const cell = { padding: '4px 8px', borderBottom: '1px solid #eee' } as const;
export const head = { textAlign: 'left', padding: '4px 8px', borderBottom: '1px solid #999' } as const;
export const num = { ...cell, textAlign: 'right' } as const;

