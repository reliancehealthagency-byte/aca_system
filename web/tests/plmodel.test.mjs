// node tests/plmodel.test.mjs  (Node >= 22.18 strips the TypeScript types of ../lib/plmodel.ts)
// Runs the /pl data layer against a fake PostgREST client in all database states: new P&L only (slice three applied),
// old P&L only (before slice three / after its rollback), both, neither, and an unrelated error. Must never throw.
import assert from 'node:assert/strict';
import { detectModel, loadIndex, loadPeriod, loadDashboard } from '../lib/plmodel.ts';

const WALK = ['pl_daily_walk', 'pl_weekly_walk', 'pl_monthly_walk', 'pl_manual_entry_lines', 'pl_projected_rep_pay_daily',
  'pl_overhead_weekly', 'pl_overhead_monthly'];
const LEGACY = ['pl_daily', 'pl_weekly', 'pl_monthly', 'pl_line_items', 'pl_unpriced_sales'];
const sample = {
  pl_weekly_walk: [{ week_start: '2026-10-25', net: -100, overhead: 770.02, allstate_earned: 1000 }],
  pl_daily_walk: [{ day: '2026-10-30', net: -615, deal_commission: 1120, spiffs: 95, abs_pay: 120 }],
  pl_monthly_walk: [{ month_start: '2026-10-01', net: -5750.84 }],
  pl_manual_entry_lines: [{ line_date: '2026-10-30', week_start: '2026-10-25', category: 'credits', category_label: 'Credits', amount: 500 },
                          { line_date: '2026-10-25', week_start: '2026-10-25', category: 'allstate_earned', category_label: 'Allstate Earned', amount: 1000 }],
  pl_projected_rep_pay_daily: [{ day: '2026-10-30', deal_commission: 1120, spiffs: 95, abs_pay: 120, line_count: 11 }],
  pl_overhead_weekly: [{ week_start: '2026-10-25', month_start: '2026-10-01', source_name: 'Rent', amount: 700, days_in_month: 7, days_of_month: 31 }],
  pl_overhead_monthly: [{ month_start: '2026-10-01', source_name: 'Rent', amount: 3100 }],
  pl_weekly: [{ week_start: '2026-10-25', revenue: 560, commission: 218.8, expenses: 574, net: -232.8 }],
  pl_daily: [{ day: '2026-10-31', revenue: 110, net: -130.8 }],
  pl_monthly: [{ month_start: '2026-10-01', net: -4617.66 }],
  pl_line_items: [{ line_date: '2026-10-27', week_start: '2026-10-25', line_type: 'revenue', category_label: 'Premium', amount: 240 }],
  pl_unpriced_sales: [],
};
function fakeDb(present, failWith = null) {
  const calls = [];
  return { calls, from(table) {
    calls.push(table);
    const res = () => {
      if (failWith) return { data: null, error: failWith };
      if (!present.includes(table)) return { data: null, error: { code: 'PGRST205', message: `Could not find the table 'public.${table}' in the schema cache` } };
      return { data: sample[table] ?? [], error: null, count: (sample[table] ?? []).length };
    };
    const q = { select: () => q, eq: () => q, gte: () => q, lte: () => q, order: () => q, limit: () => q,
                then: (ok, bad) => Promise.resolve(res()).then(ok, bad) };
    return q;
  } };
}
const periods = ['daily', 'weekly', 'monthly'];
let n = 0;
for (const [name, present, expect] of [['new only', WALK, 'walk'], ['old only', LEGACY, 'legacy'], ['both', [...WALK, ...LEGACY], 'walk'], ['neither', [], 'none']]) {
  const db = fakeDb(present);
  assert.equal(await detectModel(db), expect, name); n++;
  for (const p of periods) {
    const i = await loadIndex(db, p); assert.equal(i.model, expect); assert.equal(i.error, false, `${name} ${p} index error`); n++;
    const d = await loadPeriod(db, p, p === 'daily' ? '2026-10-30' : p === 'weekly' ? '2026-10-25' : '2026-10-01');
    assert.equal(d.error, false, `${name} ${p} period error`); n++;
    if (expect === 'walk') {
      // never touches a retired view when the new P&L exists
      assert.ok(!db.calls.some((t) => LEGACY.includes(t)), `${name}: read a retired view`); n++;
      if (p === 'daily') assert.ok(!d.sections.some((s) => /earned|Overhead/.test(s.title)), 'earned / overhead must not be daily');
      if (p === 'weekly') assert.ok(d.sections.some((s) => s.title === 'Overhead') && d.sections.some((s) => /earned/.test(s.title))); n++;
    }
  }
  const h = await loadDashboard(db, '2026-10-30', '2026-10-25'); assert.equal(h.model, expect); assert.equal(h.error, false); n++;
}
const broken = fakeDb(WALK, { code: '08006', message: 'connection failure' });
assert.equal(await detectModel(broken), 'error'); assert.equal((await loadIndex(broken, 'weekly')).error, true); n++;
console.log(`plmodel tests: ${n} assertions groups passed (new-only, old-only, both, neither, connection error)`);
