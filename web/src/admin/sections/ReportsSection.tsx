import { AdminScope } from '../AdminScope'
import { useEffect, useRef, useState } from 'react'
import { ApiRequestError } from '../../api'
import type { CurrentUser } from '../../api'
import { Button } from '../../components/Button'
import { useHoldWorkspaceLock } from '../../components/coachWorkspaceMutationLifecycle'
import { coachChallengeApi, type SponsorIndex, type SponsorReport } from '../../lib/coachChallengeApi'
import { formatDay } from '../../lib/plainDates'
import { AdminDialog } from '../AdminDialog'
import { useAdminRoster, type RosterGroup } from '../useAdminRoster'
import './sections.css'

type Row = { day: number; cutoff: string | null; sealable: boolean; savedId: number | null }
type Opened = { report: SponsorReport; exportId: number }
const message = (caught: unknown, fallback: string) => caught instanceof Error ? caught.message : fallback
// Saved reports come a page at a time; a group has few, so the screen follows the pages itself up to here.
const PAGES_AT_ONCE = 5

// Day 30, 60 and 90 for each savings group: one plain row each, one action each.
export function ReportsSection({ currentUser }: { currentUser: CurrentUser }) {
  const { groups, loading, error } = useAdminRoster(currentUser)
  const savingsGroups = groups.filter(group => group.savingsChallenge && group.status !== 'archived')
  return <section className="admin-section" aria-busy={loading}>
    <header className="admin-section-head"><div><h2 data-page-heading tabIndex={-1}>Reports</h2><AdminScope currentUser={currentUser} /><p>How each group is doing at Day 30, 60 and 90.</p></div></header>
    <p className="admin-privacy-note">Reports show broad ranges only, never names or personal amounts. A group of fewer than five people is hidden so no one can be picked out, and only people who agreed to share are counted.</p>
    {error && <p className="admin-alert error" role="alert">{error}</p>}
    {loading ? <p role="status" className="admin-muted">Opening your reports…</p>
      : savingsGroups.length === 0 ? <div className="admin-empty"><p>Reports appear here for groups that run the 90-day savings challenge.</p></div>
      : savingsGroups.map(group => <GroupReports key={group.id} group={group} />)}
  </section>
}

function GroupReports({ group }: { group: RosterGroup }) {
  const [index, setIndex] = useState<SponsorIndex | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notYours, setNotYours] = useState(false)
  const [report, setReport] = useState<Opened | null>(null)
  const [saving, setSaving] = useState<Row | null>(null)
  const [busy, setBusy] = useState(false)
  const [more, setMore] = useState(false)
  const controller = useRef<AbortController | null>(null)
  useHoldWorkspaceLock(busy || more)

  const load = async () => {
    controller.current?.abort()
    const owned = new AbortController(); controller.current = owned
    try {
      let next = await coachChallengeApi.exports(group.id, null, owned.signal)
      for (let page = 1; page < PAGES_AT_ONCE && next.next_cursor !== null && !owned.signal.aborted; page += 1) {
        const following = await coachChallengeApi.exports(group.id, next.next_cursor, owned.signal)
        next = { ...following, records: [...next.records, ...following.records], scheduled_checkpoints: next.scheduled_checkpoints }
      }
      if (!owned.signal.aborted) { setIndex(next); setError(null); setNotYours(false) }
    } catch (caught) {
      if (owned.signal.aborted) return
      // Reports are read by the people on a group's team; anyone else simply has none to see here.
      if (caught instanceof ApiRequestError && (caught.status === 403 || caught.status === 404)) { setNotYours(true); setError(null) }
      else setError(message(caught, 'These reports couldn’t be opened.'))
    }
  }
  useEffect(() => { queueMicrotask(() => void load()); return () => controller.current?.abort() }, [group.id]) // eslint-disable-line react-hooks/exhaustive-deps

  async function showEarlier() {
    if (!index || index.next_cursor === null || more) return
    setMore(true); setError(null)
    try {
      const following = await coachChallengeApi.exports(group.id, index.next_cursor, new AbortController().signal)
      setIndex(current => current && { ...following, records: [...current.records, ...following.records.filter(item => !current.records.some(known => known.id === item.id))], scheduled_checkpoints: current.scheduled_checkpoints })
    } catch (caught) { setError(message(caught, 'Earlier reports couldn’t be opened.')) }
    finally { setMore(false) }
  }

  const rows: Row[] = (index?.scheduled_checkpoints ?? []).map(item => ({ day: item.day, cutoff: item.cutoff_on, sealable: item.sealable ?? false, savedId: index!.records.find(record => record.checkpoint_day === item.day)?.id ?? null }))
  const canSave = index?.can_seal !== false

  // The newest copy of each day is on its row; every other saved copy that was loaded is listed so it can be opened too.
  const shownIds = new Set(rows.map(row => row.savedId))
  const earlierCopies = (index?.records ?? []).filter(record => !shownIds.has(record.id))

  async function view(exportId: number) {
    if (busy) return
    setBusy(true); setError(null)
    try { const result = await coachChallengeApi.report(group.id, exportId, new AbortController().signal); setReport({ report: result.report, exportId: result.export_id }) }
    catch (caught) { setError(message(caught, 'That report couldn’t be opened.')) }
    finally { setBusy(false) }
  }

  return <article className="admin-report-group">
    <h3>{group.name}</h3>
    {error && <p className="admin-alert error" role="alert">{error} <Button variant="secondary" size="compact" onClick={() => void load()}>Try again</Button></p>}
    {notYours ? <p className="admin-muted">Reports for this group are kept by the people who coach it, so there is nothing for you to open here.</p>
      : !index && !error ? <p role="status" className="admin-muted">Opening…</p> : index && <ul className="ui-card ui-rows admin-list">
      {rows.map(row => <li key={row.day} className="admin-report-row">
        <div><strong>Day {row.day}</strong><span>{row.cutoff ? formatDay(row.cutoff, { year: true }) : 'Needs a start date first'} · {row.savedId !== null ? 'Report saved' : !row.cutoff ? 'Not ready' : row.sealable ? 'Ready to save' : 'Not ready yet'}</span>
          {row.savedId === null && row.sealable && !canSave && <span>Only the coaches of this group can save it: a program owner or reviewer on its team.</span>}</div>
        {row.savedId !== null ? <Button variant="secondary" disabled={busy} onClick={() => void view(row.savedId!)}>View report</Button>
          : row.sealable && canSave ? <Button disabled={busy} onClick={() => setSaving(row)}>Save the report</Button> : null}
      </li>)}
    </ul>}
    {earlierCopies.length > 0 && <div className="admin-report-earlier">
      <h4>Earlier saved reports</h4>
      <ul className="ui-card ui-rows admin-list">{earlierCopies.map(record => <li key={record.id} className="admin-report-row">
        <div><strong>Day {record.checkpoint_day}</strong><span>As of {formatDay(record.resolved_cutoff_on, { year: true })}</span></div>
        <Button variant="secondary" disabled={busy} onClick={() => void view(record.id)}>View report</Button>
      </li>)}</ul>
    </div>}
    {index && index.next_cursor !== null && <Button variant="secondary" disabled={more} onClick={() => void showEarlier()}>{more ? 'Loading…' : 'Show earlier saved reports'}</Button>}
    {saving && <SaveReport groupId={group.id} row={saving} onClose={() => setSaving(null)} onSaved={async next => { setSaving(null); setReport(next); await load() }} />}
    {report && <ReportView data={report} group={group} onClose={() => setReport(null)} />}
  </article>
}

function SaveReport({ groupId, row, onClose, onSaved }: { groupId: number; row: Row; onClose: () => void; onSaved: (next: Opened) => Promise<void> }) {
  const [accepted, setAccepted] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  useHoldWorkspaceLock(busy)
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

function ReportView({ data, group, onClose }: { data: Opened; group: RosterGroup; onClose: () => void }) {
  const { report } = data
  const [downloading, setDownloading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // The file is made from a fresh read that is checked to be this group's, this saved report and this day.
  async function download() {
    if (downloading) return
    setDownloading(true); setError(null)
    try {
      const fresh = await coachChallengeApi.report(group.id, data.exportId, new AbortController().signal)
      if (fresh.cohort_id !== group.id || fresh.export_id !== data.exportId || fresh.report.checkpoint_day !== report.checkpoint_day) throw new Error('That report no longer matches this group. Close it and open it again.')
      const url = URL.createObjectURL(new Blob([JSON.stringify(fresh.report, null, 2)], { type: 'application/json' }))
      const link = document.createElement('a'); link.href = url; link.download = `group-day-${fresh.report.checkpoint_day}.json`; link.click(); URL.revokeObjectURL(url)
    } catch (caught) { setError(message(caught, 'The report couldn’t be downloaded. Try again.')) }
    finally { setDownloading(false) }
  }
  return <AdminDialog title={`${group.name} · Day ${report.checkpoint_day}`} labelId="admin-report-title" onClose={onClose}>
    <p className="admin-muted">As of {formatDay(report.cutoff_on, { year: true })}</p>
    <p>People who agreed to share: <strong>{report.suppressed ? 'hidden to protect privacy' : report.active_consent_count_range}</strong></p>
    {report.suppressed ? <p>Fewer than five people agreed to share, so progress is hidden. This protects everyone in the group.</p>
      : <ul className="admin-band-list">{report.bands.map(row => <li key={row.band}><span>{row.band.replaceAll('_', ' ')}</span><strong>{row.count_range} people</strong></li>)}</ul>}
    <p className="admin-muted">These ranges come from what people reported. They aren’t checked against bank balances.</p>
    {error && <p className="admin-alert error" role="alert">{error}</p>}
    <div className="admin-actions"><Button variant="secondary" disabled={downloading} onClick={() => void download()}>{downloading ? 'Preparing…' : 'Download this report'}</Button></div>
  </AdminDialog>
}
