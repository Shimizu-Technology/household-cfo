import { useEffect, useRef, useState } from 'react'
import type { AdminCohort, CurrentUser } from '../../api'
import { Button } from '../../components/Button'
import { coachChallengeApi, type SponsorIndex, type SponsorReport } from '../../lib/coachChallengeApi'
import { formatDay } from '../../lib/plainDates'
import { AdminDialog } from '../AdminDialog'
import { useAdminRoster } from '../useAdminRoster'
import './sections.css'

type Row = { day: number; cutoff: string | null; sealable: boolean; savedId: number | null }
const message = (caught: unknown, fallback: string) => caught instanceof Error ? caught.message : fallback

// Day 30, 60 and 90 for each savings group: one plain row each, one action each.
export function ReportsSection({ currentUser }: { currentUser: CurrentUser }) {
  const { groups, loading, error } = useAdminRoster()
  const savingsGroups = groups.filter(group => group.savings_challenge?.enabled && group.status !== 'archived')
  return <section className="admin-section" aria-busy={loading}>
    <header className="admin-section-head"><div><h2 data-page-heading tabIndex={-1}>Reports</h2><p>How each group is doing at Day 30, 60 and 90.</p></div></header>
    <p className="admin-privacy-note">Reports show broad ranges only, never names or personal amounts. A group of fewer than five people is hidden so no one can be picked out, and only people who agreed to share are counted.</p>
    {error && <p className="admin-alert error" role="alert">{error}</p>}
    {loading ? <p role="status" className="admin-muted">Opening your reports…</p>
      : savingsGroups.length === 0 ? <div className="admin-empty"><p>Reports appear here for groups that run the 90-day savings challenge.</p></div>
      : savingsGroups.map(group => <GroupReports key={group.id} group={group} currentUser={currentUser} />)}
  </section>
}

function GroupReports({ group }: { group: AdminCohort; currentUser: CurrentUser }) {
  const [index, setIndex] = useState<SponsorIndex | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [report, setReport] = useState<{ report: SponsorReport; exportId: number } | null>(null)
  const [saving, setSaving] = useState<Row | null>(null)
  const [busy, setBusy] = useState(false)
  const controller = useRef<AbortController | null>(null)

  const load = async () => {
    controller.current?.abort()
    const owned = new AbortController(); controller.current = owned
    try { const next = await coachChallengeApi.exports(group.id, null, owned.signal); if (!owned.signal.aborted) { setIndex(next); setError(null) } }
    catch (caught) { if (!owned.signal.aborted) setError(message(caught, 'These reports couldn’t be opened.')) }
  }
  useEffect(() => { queueMicrotask(() => void load()); return () => controller.current?.abort() }, [group.id]) // eslint-disable-line react-hooks/exhaustive-deps

  const rows: Row[] = (index?.scheduled_checkpoints ?? []).map(item => ({ day: item.day, cutoff: item.cutoff_on, sealable: item.sealable ?? false, savedId: index!.records.find(record => record.checkpoint_day === item.day)?.id ?? null }))

  async function view(row: Row) {
    if (busy || row.savedId === null) return
    setBusy(true); setError(null)
    try { const result = await coachChallengeApi.report(group.id, row.savedId, new AbortController().signal); setReport({ report: result.report, exportId: result.export_id }) }
    catch (caught) { setError(message(caught, 'That report couldn’t be opened.')) }
    finally { setBusy(false) }
  }

  return <article className="admin-report-group">
    <h3>{group.name}</h3>
    {error && <p className="admin-alert error" role="alert">{error}</p>}
    {!index && !error ? <p role="status" className="admin-muted">Opening…</p> : <ul className="admin-list">
      {rows.map(row => <li key={row.day} className="admin-report-row">
        <div><strong>Day {row.day}</strong><span>{row.cutoff ? formatDay(row.cutoff, { year: true }) : 'Needs a start date first'} · {row.savedId !== null ? 'Report saved' : !row.cutoff ? 'Not ready' : row.sealable ? 'Ready to save' : 'Not ready yet'}</span></div>
        {row.savedId !== null ? <Button variant="secondary" disabled={busy} onClick={() => void view(row)}>View report</Button>
          : row.sealable && index?.can_seal !== false ? <Button disabled={busy} onClick={() => setSaving(row)}>Save the report</Button> : null}
      </li>)}
    </ul>}
    {saving && <SaveReport groupId={group.id} row={saving} onClose={() => setSaving(null)} onSaved={async next => { setSaving(null); setReport(next); await load() }} />}
    {report && <ReportView data={report} group={group} onClose={() => setReport(null)} />}
  </article>
}

function SaveReport({ groupId, row, onClose, onSaved }: { groupId: number; row: Row; onClose: () => void; onSaved: (next: { report: SponsorReport; exportId: number }) => Promise<void> }) {
  const [accepted, setAccepted] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  async function save() {
    if (busy || !accepted) return
    setBusy(true); setError(null)
    try { const result = await coachChallengeApi.seal(groupId, row.day, new AbortController().signal); await onSaved({ report: result.report, exportId: result.export_id }) }
    catch (caught) { setError(message(caught, 'The report couldn’t be saved.')); setBusy(false) }
  }
  return <AdminDialog title={`Save the Day ${row.day} report`} labelId="admin-save-report-title" onClose={onClose}>
    <p>This saves a fixed copy of where the group stands on {row.cutoff ? formatDay(row.cutoff, { year: true }) : `Day ${row.day}`}. It doesn’t send anything to the sponsor.</p>
    <label className="admin-inline-check"><input type="checkbox" checked={accepted} onChange={event => setAccepted(event.target.checked)} /><span>I understand it shows broad ranges only and hides small groups.</span></label>
    {error && <p className="admin-alert error" role="alert">{error}</p>}
    <div className="admin-actions"><Button disabled={!accepted || busy} onClick={() => void save()}>{busy ? 'Saving…' : 'Save the report'}</Button></div>
  </AdminDialog>
}

function ReportView({ data, group, onClose }: { data: { report: SponsorReport; exportId: number }; group: AdminCohort; onClose: () => void }) {
  const { report } = data
  const download = () => {
    const url = URL.createObjectURL(new Blob([JSON.stringify(report, null, 2)], { type: 'application/json' }))
    const link = document.createElement('a'); link.href = url; link.download = `group-day-${report.checkpoint_day}.json`; link.click(); URL.revokeObjectURL(url)
  }
  return <AdminDialog title={`${group.name} · Day ${report.checkpoint_day}`} labelId="admin-report-title" onClose={onClose}>
    <p className="admin-muted">As of {formatDay(report.cutoff_on, { year: true })}</p>
    <p>People who agreed to share: <strong>{report.suppressed ? 'hidden to protect privacy' : report.active_consent_count_range}</strong></p>
    {report.suppressed ? <p>Fewer than five people agreed to share, so progress is hidden. This protects everyone in the group.</p>
      : <ul className="admin-band-list">{report.bands.map(row => <li key={row.band}><span>{row.band.replaceAll('_', ' ')}</span><strong>{row.count_range} people</strong></li>)}</ul>}
    <p className="admin-muted">These ranges come from what people reported. They aren’t checked against bank balances.</p>
    <div className="admin-actions"><Button variant="secondary" onClick={download}>Download this report</Button></div>
  </AdminDialog>
}
