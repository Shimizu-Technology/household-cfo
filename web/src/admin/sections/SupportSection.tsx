import { useCallback, useEffect, useMemo, useState } from 'react'
import { fetchAdminPilotFeedback, fetchAdminPilotFeedbackReport, fetchAdminPilotFeedbackScreenshotUrl, updateAdminPilotFeedbackStatus } from '../../api'
import type { AdminPilotFeedbackDetail, AdminPilotFeedbackScreenshotUrl, AdminPilotFeedbackSummary, CurrentUser, PilotFeedbackStatus } from '../../api'
import { Button } from '../../components/Button'
import { SetupSupportInbox } from '../../components/SetupSupportInbox'
import { useAuthContext } from '../../contexts/authContextValue'
import { fetchSetupSupportRequests } from '../../setupHelpApi'
import type { SetupSupportRequest } from '../../lib/setupHelp'
import { AdminDialog } from '../AdminDialog'
import { lastActiveWords } from '../adminWords'
import './sections.css'

type Item = { key: string; kind: 'setup' | 'problem'; title: string; summary: string; at: string; open: boolean; statusWords: string; setup?: SetupSupportRequest; problem?: AdminPilotFeedbackSummary }
type Show = 'open' | 'done' | 'all'

const setupStatus: Record<SetupSupportRequest['status'], string> = { requested: 'Waiting for you', in_review: 'You’re looking at it', ready: 'Waiting for them', applied: 'Done', canceled: 'Canceled', declined: 'Corrections suggested' }
const problemStatus: Record<PilotFeedbackStatus, string> = { submitted: 'New', reviewed: 'Looked at', resolved: 'Done' }
const setupReason: Record<string, string> = { practice_numbers: 'entered practice numbers', wrong_setup: 'setup needs correcting', upload_problem: 'needs help with an upload', other: 'needs help starting again' }
const area: Record<string, string> = { sign_in: 'Signing in', home: 'Home', setup: 'Setup', ask_mia: 'Ask Mia', voice: 'Voice', budget: 'Budget', transaction_review: 'Reviewing purchases', receipt_upload: 'A receipt', statement_upload: 'A statement', document_upload: 'A document', private_document: 'A private document', admin: 'The coach side', other: 'Something else' }

// Setup requests and problem reports in one list, newest first.
export function SupportSection({ currentUser }: { currentUser: CurrentUser }) {
  const { activeCoachWorkspaceId } = useAuthContext()
  const [setups, setSetups] = useState<SetupSupportRequest[] | null>(null)
  const [problems, setProblems] = useState<AdminPilotFeedbackSummary[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [show, setShow] = useState<Show>('open')
  const [openKey, setOpenKey] = useState<string | null>(null)
  const canLoadSetup = activeCoachWorkspaceId !== null || currentUser.is_admin

  const load = useCallback(async () => {
    setError(null)
    const [setup, problem] = await Promise.allSettled([
      canLoadSetup ? fetchSetupSupportRequests(null, null) : Promise.resolve({ records: [] as SetupSupportRequest[], next_cursor: null }),
      currentUser.is_admin ? fetchAdminPilotFeedback('all') : Promise.resolve({ feedback_reports: [] as AdminPilotFeedbackSummary[] }),
    ])
    setSetups(setup.status === 'fulfilled' ? setup.value.records : [])
    setProblems(problem.status === 'fulfilled' ? problem.value.feedback_reports : [])
    if (setup.status === 'rejected' || problem.status === 'rejected') setError('Some requests couldn’t be loaded. Try again in a moment.')
  }, [canLoadSetup, currentUser.is_admin])
  useEffect(() => { queueMicrotask(() => void load()) }, [load])

  const items: Item[] = useMemo(() => [
    ...(setups ?? []).map((request): Item => ({ key: `setup:${request.id}`, kind: 'setup', title: request.participant_name || 'Someone', summary: `Setup help: ${setupReason[request.reason] ?? 'needs a hand'}`, at: request.created_at, open: ['requested', 'in_review', 'ready'].includes(request.status), statusWords: setupStatus[request.status], setup: request })),
    ...(problems ?? []).map((report): Item => ({ key: `problem:${report.id}`, kind: 'problem', title: report.reporter.full_name || report.reporter.email, summary: `Reported a problem: ${area[report.workflow] ?? 'Something else'}`, at: report.created_at, open: report.status !== 'resolved', statusWords: problemStatus[report.status], problem: report })),
  ].sort((a, b) => new Date(b.at).getTime() - new Date(a.at).getTime()), [problems, setups])
  const counts = { open: items.filter(item => item.open).length, done: items.filter(item => !item.open).length, all: items.length }
  const shown = items.filter(item => show === 'all' || (show === 'open') === item.open)
  const opened = items.find(item => item.key === openKey) ?? null
  const loading = setups === null || problems === null

  return <section className="admin-section" aria-busy={loading}>
    <header className="admin-section-head"><div><h2 data-page-heading tabIndex={-1}>Support</h2><p>Help people have asked for, newest first.</p></div></header>
    {error && <p className="admin-alert error" role="alert">{error} <Button variant="secondary" size="compact" onClick={() => void load()}>Try again</Button></p>}
    <div className="admin-chips" role="group" aria-label="Show requests that are">
      {([['open', 'Needs a look'], ['done', 'Done'], ['all', 'Everything']] as const).map(([value, label]) => <button key={value} type="button" aria-pressed={show === value} onClick={() => setShow(value)}><strong>{counts[value]}</strong> {label}</button>)}
    </div>
    {currentUser.is_admin && activeCoachWorkspaceId === null && <p className="admin-muted">Choose a program at the top to see its setup requests.</p>}
    {loading ? <p role="status" className="admin-muted">Opening your requests…</p>
      : shown.length === 0 ? <div className="admin-empty"><p>{show === 'open' ? 'Nothing needs a look right now.' : 'Nothing here yet.'}</p></div>
      : <ul className="admin-list">{shown.map(item => <li key={item.key}><button type="button" className="admin-list-row" onClick={() => setOpenKey(item.key)}>
        <strong>{item.title}</strong><span className="admin-need">{item.summary}</span>
        <span className="admin-list-meta"><span className={`admin-pill ${item.open ? 'is-invited' : 'is-joined'}`}>{item.statusWords}</span> · {lastActiveWords(item.at)}</span>
      </button></li>)}</ul>}
    {opened?.setup && <AdminDialog title={opened.title} labelId="admin-support-title" onClose={() => { setOpenKey(null); void load() }}>
      <SetupSupportInbox actorId={currentUser.id} workspaceId={activeCoachWorkspaceId} cohortId={opened.setup.cohort_id} participantId={opened.setup.user_id} isAdmin={currentUser.is_admin} />
    </AdminDialog>}
    {opened?.problem && <ProblemDetail summary={opened.problem} onClose={() => setOpenKey(null)} onChanged={load} />}
  </section>
}

function ProblemDetail({ summary, onClose, onChanged }: { summary: AdminPilotFeedbackSummary; onClose: () => void; onChanged: () => Promise<void> }) {
  const [detail, setDetail] = useState<AdminPilotFeedbackDetail | null>(null)
  const [link, setLink] = useState<AdminPilotFeedbackScreenshotUrl | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => { let live = true; fetchAdminPilotFeedbackReport(summary.id).then(next => { if (live) setDetail(next) }).catch(() => { if (live) setError('The details couldn’t be opened.') }); return () => { live = false } }, [summary.id])
  async function setStatus(status: PilotFeedbackStatus) {
    if (busy || !detail) return
    setBusy(true); setError(null)
    try { setDetail(await updateAdminPilotFeedbackStatus(detail.id, status)); await onChanged() }
    catch (caught) { setError(caught instanceof Error ? caught.message : 'That didn’t save.') }
    finally { setBusy(false) }
  }
  async function prepare() {
    if (busy || !detail?.screenshot) return
    setBusy(true); setError(null)
    try { setLink(await fetchAdminPilotFeedbackScreenshotUrl(detail.id)) } catch (caught) { setError(caught instanceof Error ? caught.message : 'The screenshot link couldn’t be made.') } finally { setBusy(false) }
  }
  return <AdminDialog title={summary.reporter.full_name || summary.reporter.email} labelId="admin-problem-title" onClose={onClose}>
    {error && <p className="admin-alert error" role="alert">{error}</p>}
    {!detail ? <p role="status" className="admin-muted">Opening…</p> : <>
      <p className="admin-muted"><a href={`mailto:${detail.reporter.email}`}>{detail.reporter.email}</a> · {area[detail.workflow] ?? 'Something else'} · {problemStatus[detail.status]}</p>
      <dl className="admin-facts">
        <div><dt>What they tried</dt><dd>{detail.attempted}</dd></div>
        <div><dt>What they expected</dt><dd>{detail.expected}</dd></div>
        <div><dt>What happened</dt><dd>{detail.actual}</dd></div>
      </dl>
      {detail.screenshot && (link ? <p><a href={link.url} target="_blank" rel="noreferrer">Open the screenshot</a> · <a href={link.download_url}>Download</a> <small className="admin-muted">(link works for {Math.round(link.expires_in / 60)} minutes)</small></p> : <Button variant="secondary" disabled={busy} onClick={() => void prepare()}>Show the screenshot</Button>)}
      <div className="admin-actions">
        {detail.status !== 'reviewed' && detail.status !== 'resolved' && <Button variant="secondary" disabled={busy} onClick={() => void setStatus('reviewed')}>I’ve looked at it</Button>}
        {detail.status !== 'resolved' && <Button disabled={busy} onClick={() => void setStatus('resolved')}>Mark as done</Button>}
        {detail.status === 'resolved' && <Button variant="secondary" disabled={busy} onClick={() => void setStatus('submitted')}>Reopen</Button>}
      </div>
    </>}
  </AdminDialog>
}
