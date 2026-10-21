import { savingsDollars, savingsFundingLabel, type SavingsFundingSource } from './savingsChallenge'
import { formatDay, formatRange, timeZoneLabel } from './plainDates'
type Row = Record<string, unknown>
type Current = Array<{ id: number; current_version_id: number }>
export type PrivateChallengeRecord = {
  schema_version: number
  captured_at?: string
  actor_scope: { user_id: number; household_id: number }
  optional_reflections_included: boolean
  enrollment: { cohort_id: number; starts_on?: string; ends_on?: string; time_zone?: string; current_accepted_plan_version_id?: number | null }
  projection?: { reporting_known: boolean; reported_cents: number | null; evidence_supported_cents: number | null }
  current_entries?: Array<{ id: number; current_approved_version_id: number }>
  current_daily_records?: { checkpoints?: Current; check_ins?: Current; purchases?: Current }
  savings?: { entry_versions?: Row[]; plan_versions?: Row[] }
  daily?: { checkpoint_versions?: Row[]; reflection_versions?: Row[]; check_in_versions?: Row[]; purchase_versions?: Row[] }
}
const escape = (value: unknown) => String(value ?? 'Not recorded').replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character]!))
function money(value: unknown) { return typeof value === 'number' && Number.isSafeInteger(value) ? savingsDollars(value) : 'Not recorded' }
function table(headers: string[], rows: unknown[][], empty = 'Nothing confirmed yet.') {
  return rows.length ? `<table><thead><tr>${headers.map(header => `<th scope="col">${escape(header)}</th>`).join('')}</tr></thead><tbody>${rows.map(row => `<tr>${row.map(value => `<td>${escape(value)}</td>`).join('')}</tr>`).join('')}</tbody></table>` : `<p>${escape(empty)}</p>`
}
// Calendar days stay as written; timestamps are shown in the participant's challenge time zone.
const day = (value: unknown) => typeof value === 'string' && value ? formatDay(value, { year: true }) : 'Not recorded'
function moment(value: unknown, zone: string) {
  if (typeof value !== 'string' || !value) return 'Not recorded'
  const date = new Date(value)
  if (!Number.isFinite(date.getTime())) return value
  return new Intl.DateTimeFormat('en-US', { timeZone: zone, weekday: 'short', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' }).format(date)
}
const spendingWords: Record<string, string> = { spending: 'I spent money', no_spend: 'No spending', unknown: 'Not sure yet' }
// A standalone local document: no scripts, remote assets or hidden financial payload.
export function printableChallengeRecord(record: PrivateChallengeRecord): string {
  const zone = record.enrollment.time_zone || 'Pacific/Guam'
  const currentOf = (rows: Current | undefined) => new Set(rows?.map(row => row.current_version_id) ?? [])
  const currentEntries = new Set(record.current_entries?.map(row => row.current_approved_version_id) ?? [])
  const entries = record.savings?.entry_versions ?? []
  const currentCheckpoints = currentOf(record.current_daily_records?.checkpoints)
  const checkpoints = record.daily?.checkpoint_versions ?? []
  const checkpointRows = (rows: Row[]) => rows.map(row => [`Day ${row.milestone_day} check-in`, row.version_number, moment(row.approved_at, zone)])
  const currentCheckIns = currentOf(record.current_daily_records?.check_ins)
  const checkIns = (record.daily?.check_in_versions ?? []).filter(row => currentCheckIns.has(Number(row.id)))
  const currentPurchases = currentOf(record.current_daily_records?.purchases)
  const purchases = (record.daily?.purchase_versions ?? []).filter(row => currentPurchases.has(Number(row.id)))
  const plans = record.savings?.plan_versions ?? []
  const target = plans.find(plan => plan.id === record.enrollment.current_accepted_plan_version_id)
  const known = record.projection?.reporting_known === true
  const entryRows = (rows: Row[]) => rows.map(row => [day(row.effective_on), money(row.signed_cents), savingsFundingLabel(row.funding_source as SavingsFundingSource), row.reason || '—'])
  const reflections = record.optional_reflections_included ? `<h2>Your optional feelings</h2>${table(['Version', 'How you felt then', 'How you feel now', 'Erased'], (record.daily?.reflection_versions ?? []).map(row => [row.version_number, row.feeling_then, row.feeling_now, row.erased_at ? moment(row.erased_at, zone) : '—']))}` : '<p>Your optional feelings are not included.</p>'
  const window = record.enrollment.starts_on && record.enrollment.ends_on ? formatRange(record.enrollment.starts_on, record.enrollment.ends_on) : 'Not set'
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"><title>My private 90-day challenge record</title><style>body{font:16px/1.6 system-ui,sans-serif;color:#222;background:white;max-width:900px;margin:40px auto;padding:0 24px}h1,h2{line-height:1.25}h2{margin-top:32px}table{width:100%;border-collapse:collapse;font-size:14px}th,td{text-align:left;vertical-align:top;border-bottom:1px solid #ccc;padding:10px;overflow-wrap:break-word}th{background:#f5f5f5}dl{display:grid;grid-template-columns:1fr 1fr;gap:8px}dt,dd{margin:0}dt{font-weight:600}@media print{body{margin:0;max-width:none}thead{display:table-header-group}tr{break-inside:avoid}.print-instruction{display:none}}</style></head><body>
  <h1>My private 90-day challenge record</h1><p class="print-instruction">Open your browser’s Print command to print or save as PDF. Keep this private file somewhere you trust.</p>
  <p>Your 90 days: ${escape(window)}. Dates follow ${escape(timeZoneLabel(zone))}.</p><p>Downloaded ${escape(moment(record.captured_at, zone))}.</p>
  <dl><dt>Set aside so far</dt><dd>${escape(known ? money(record.projection?.reported_cents) : 'No amounts added yet')}</dd><dt>Matched to a statement (included above, not extra)</dt><dd>${escape(known ? money(record.projection?.evidence_supported_cents) : 'No amounts added yet')}</dd><dt>Your target</dt><dd>${escape(target ? target.target_cents === null ? 'You’ll choose later' : money(target.target_cents) : 'Not chosen yet')}</dd></dl>
  <p>This is your own record. It isn’t checked with your bank. Money matched to a statement is part of what you set aside, not extra. Targets and anything you haven’t confirmed don’t count as money set aside.</p>
  <h2>Money you set aside</h2><p>The latest version of each record.</p>${table(['Date', 'Amount', 'Where it came from', 'Note'], entryRows(entries.filter(row => currentEntries.has(Number(row.id)))))}
  <h2>Your daily check-ins</h2>${table(['Day', 'What you said'], checkIns.map(row => [day(row.local_on), spendingWords[String(row.spending_state)] ?? 'Not recorded']))}
  <h2>Purchases you confirmed</h2>${table(['Date', 'Amount', 'Where'], purchases.map(row => [day(row.purchased_on), money(row.amount_cents), row.merchant || '—']))}
  <h2>Your target changes</h2>${table(['Version', 'Target', 'Confirmed', 'Note'], plans.map(row => [row.version_number, row.target_cents === null ? 'You’ll choose later' : money(row.target_cents), moment(row.approved_at, zone), row.reason || '—']))}
  <h2>Your Day 30, 60 and 90 check-ins</h2>${table(['Check-in', 'Version', 'Confirmed'], checkpointRows(checkpoints.filter(row => currentCheckpoints.has(Number(row.id)))))}
  <h2>Earlier versions of your check-ins</h2><p>Earlier versions are kept when you fix something. Only the latest version of each check-in counts; earlier ones aren’t extra progress or savings.</p>${table(['Check-in', 'Version', 'Confirmed'], checkpointRows(checkpoints))}
  <h2>Earlier versions of your money records</h2><p>Earlier versions are kept when you fix a record. They aren’t extra savings.</p>${table(['Date', 'Amount', 'Where it came from', 'Note'], entryRows(entries))}
  ${reflections}<p>Statements, chat, anything you haven’t confirmed, and other people’s records are left out. For every detail, download the data file (JSON) instead. Removing something from the app can’t recall a copy you already downloaded.</p>
  </body></html>`
}
