import { savingsDollars, savingsFundingLabel, type SavingsFundingSource } from './savingsChallenge'
export type PrivateChallengeRecord = {
  schema_version: number
  captured_at?: string
  actor_scope: { user_id: number; household_id: number }
  optional_reflections_included: boolean
  enrollment: { cohort_id: number; starts_on?: string; ends_on?: string; time_zone?: string; current_accepted_plan_version_id?: number | null }
  projection?: { reporting_known: boolean; reported_cents: number | null; evidence_supported_cents: number | null }
  current_entries?: Array<{ id: number; current_approved_version_id: number }>
  current_daily_records?: { checkpoints?: Array<{ id: number; current_version_id: number }> }
  savings?: { entry_versions?: Array<Record<string, unknown>>; plan_versions?: Array<Record<string, unknown>> }
  daily?: { checkpoint_versions?: Array<Record<string, unknown>>; reflection_versions?: Array<Record<string, unknown>> }
}
const escape = (value: unknown) => String(value ?? 'Not recorded').replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character]!))
function money(value: unknown) { return typeof value === 'number' && Number.isSafeInteger(value) ? savingsDollars(value) : 'Not recorded' }
function table(headers: string[], rows: unknown[][]) {
  return rows.length ? `<table><thead><tr>${headers.map(header => `<th scope="col">${escape(header)}</th>`).join('')}</tr></thead><tbody>${rows.map(row => `<tr>${row.map(value => `<td>${escape(value)}</td>`).join('')}</tr>`).join('')}</tbody></table>` : '<p>No approved records.</p>'
}
// A standalone local document: no scripts, remote assets or hidden financial payload.
export function printableChallengeRecord(record: PrivateChallengeRecord): string {
  const currentEntries = new Set(record.current_entries?.map(row => row.current_approved_version_id) ?? [])
  const entries = record.savings?.entry_versions ?? []
  const currentCheckpoints = new Set(record.current_daily_records?.checkpoints?.map(row => row.current_version_id) ?? [])
  const plans = record.savings?.plan_versions ?? []
  const target = plans.find(plan => plan.id === record.enrollment.current_accepted_plan_version_id)
  const known = record.projection?.reporting_known === true
  const entryRows = (rows: Array<Record<string, unknown>>) => rows.map(row => [row.effective_on, money(row.signed_cents), savingsFundingLabel(row.funding_source as SavingsFundingSource), row.reason || '—'])
  const reflections = record.optional_reflections_included ? `<h2>Optional feeling history</h2>${table(['Version', 'Then', 'Now', 'Erased'], (record.daily?.reflection_versions ?? []).map(row => [row.version_number, row.feeling_then, row.feeling_now, row.erased_at || '—']))}` : '<p>Optional feelings are excluded.</p>'
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"><title>My private 90-day challenge record</title><style>body{font:16px/1.6 system-ui,sans-serif;color:#222;background:white;max-width:900px;margin:40px auto;padding:0 24px}h1,h2{line-height:1.25}h2{margin-top:32px}table{width:100%;border-collapse:collapse;font-size:14px}th,td{text-align:left;vertical-align:top;border-bottom:1px solid #ccc;padding:10px;overflow-wrap:anywhere}th{background:#f5f5f5}dl{display:grid;grid-template-columns:1fr 1fr;gap:8px}dt,dd{margin:0}dt{font-weight:600}@media print{body{margin:0;max-width:none}thead{display:table-header-group}tr{break-inside:avoid}.print-instruction{display:none}}</style></head><body>
  <h1>My private 90-day challenge record</h1><p class="print-instruction">Open your browser’s Print command to print or save as PDF. Keep this private file somewhere you trust.</p>
  <p>Personal window: ${escape(record.enrollment.starts_on)} – ${escape(record.enrollment.ends_on)} · ${escape(record.enrollment.time_zone)}</p><p>Captured: ${escape(record.captured_at)}</p>
  <dl><dt>Approved participant-reported reserve</dt><dd>${escape(known ? money(record.projection?.reported_cents) : 'Not yet reported')}</dd><dt>Evidence-supported subset</dt><dd>${escape(known ? money(record.projection?.evidence_supported_cents) : 'Not yet reported')}</dd><dt>Accepted target</dt><dd>${escape(target ? target.target_cents === null ? 'Choosing later' : money(target.target_cents) : 'Not yet approved')}</dd></dl>
  <p>Self-reports are not bank verification. Supported savings are part of the reported reserve, not additional savings. Plans and pending proposals do not count as savings.</p>
  <h2>Current approved savings records</h2>${table(['Date', 'Amount', 'Money source', 'Reason'], entryRows(entries.filter(row => currentEntries.has(Number(row.id)))))}
  <h2>Approved target history</h2>${table(['Revision', 'Target', 'Approved', 'Reason'], plans.map(row => [row.version_number, row.target_cents === null ? 'Choosing later' : money(row.target_cents), row.approved_at, row.reason || '—']))}
  <h2>Current approved checkpoints</h2>${table(['Checkpoint', 'Revision', 'Approved'], (record.daily?.checkpoint_versions ?? []).filter(row => currentCheckpoints.has(Number(row.id))).map(row => [`Day ${row.milestone_day}`, row.version_number, row.approved_at]))}
  <h2>Savings revision history</h2><p>Earlier versions are retained for corrections and are not additional savings.</p>${table(['Date', 'Amount', 'Money source', 'Reason'], entryRows(entries))}
  ${reflections}<p>Original statements, chat, pending proposals and other participants are excluded. This readable record summarizes the approved history; choose the structured JSON export for the complete detailed record. Removing information from the app cannot recall downloaded copies.</p>
  </body></html>`
}
