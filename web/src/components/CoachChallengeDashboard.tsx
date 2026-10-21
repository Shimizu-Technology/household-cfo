import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { ApiRequestError, fetchSharedChallengeSource } from '../api'
import {
  coachChallengeApi,
  type CoachChallengeScope,
  type CoachParticipant,
  type CoachDailyPerson,
  type CoachDailyPage,
  type DailyFilter,
  formatCoachTime,
  openCoachInvitation,
  openCoachSetupHelp,
  type SharedScopes,
  type SponsorIndex,
  type SponsorReport,
  type SharedRecordRef,
} from '../lib/coachChallengeApi'
import { savingsDollars } from '../lib/savingsChallenge'
import { formatDay } from '../lib/plainDates'
import { SetupSupportInbox } from './SetupSupportInbox'
import { DisabledReason } from './DisabledReason'
import './CoachChallengeDashboard.css'

type Props = { userId: number; workspaceId: number; cohorts: Array<{ id: number; name: string }>; selectedCohortId?: number | null }
export function CoachChallengeDashboard(props: Props) {
  return <Dashboard key={`${props.userId}:${props.workspaceId}`} {...props} />
}
function Dashboard({ userId, workspaceId, cohorts, selectedCohortId }: Props) {
  const [localCohortId, setCohortId] = useState<number | null>(null)
  const cohortId = selectedCohortId === undefined ? localCohortId : selectedCohortId
  return (
    <section className="coach-challenge" aria-label="Daily coaching">
      {selectedCohortId === undefined && <label>Group<select value={cohortId ?? ''} onChange={(event) => setCohortId(event.target.value ? Number(event.target.value) : null)}>
        <option value="">Choose a group</option>
        {cohorts.map((row) => <option key={row.id} value={row.id}>{row.name}</option>)}
      </select></label>}
      {cohortId ? <Group key={cohortId} scope={{ user_id: userId, coach_workspace_id: workspaceId }} cohortId={cohortId} /> : <p>Choose a group to see who needs you.</p>}
    </section>
  )
}
function Group({ scope, cohortId }: { scope: CoachChallengeScope; cohortId: number }) {
  const [page, setPage] = useState<CoachDailyPage | null>(null)
  const [offset, setOffset] = useState(0)
  const [selected, setSelected] = useState<CoachDailyPerson | null>(null)
  const [revision, setRevision] = useState(0)
  const [busy, setBusy] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [filter, setFilter] = useState<DailyFilter>('all')
  const list = useRef<HTMLDivElement>(null)
  const detail = useRef<HTMLDivElement>(null)
  const returnTo = useRef<{ top: number; button: HTMLButtonElement } | null>(null)
  useEffect(() => {
    let live = true
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      coachChallengeApi.daily(cohortId, search, filter, offset, controller.signal).then((result) => {
        if (result.actor_scope.user_id !== scope.user_id || result.actor_scope.coach_workspace_id !== scope.coach_workspace_id || result.cohort_id !== cohortId)
          throw new Error('The program changed. Reopen Daily coaching.')
        if (live) { setPage(result); setError(null); setBusy(false) }
      }).catch((failure) => {
        if (live) { setPage(null); setSelected(null); setBusy(false); setError(message(failure)) }
      })
    }, search ? 200 : 0)
    return () => { live = false; controller.abort(); window.clearTimeout(timer) }
  }, [scope.user_id, scope.coach_workspace_id, cohortId, search, filter, offset, revision])
  useEffect(() => {
    function changed(event: Event) { if ((event as CustomEvent<number>).detail === cohortId) { returnTo.current = null; setSelected(null); setRevision((value) => value + 1) } }
    window.addEventListener('coach-roster-changed', changed)
    return () => window.removeEventListener('coach-roster-changed', changed)
  }, [cohortId])
  useLayoutEffect(() => {
    if (selected) {
      detail.current?.querySelector<HTMLElement>('h3')?.focus({ preventScroll: true })
      if (window.matchMedia('(max-width: 620px)').matches) detail.current?.scrollIntoView({ block: 'start' })
    } else if (returnTo.current) {
      returnTo.current.button.focus({ preventScroll: true })
      window.scrollTo({ top: returnTo.current.top, behavior: 'instant' })
      returnTo.current = null
    }
  }, [selected])
  function change(nextFilter: DailyFilter, nextSearch = search) {
    if (nextFilter === filter && nextSearch === search && offset === 0) return
    returnTo.current = null; setSelected(null); setBusy(true); setError(null); setOffset(0); setFilter(nextFilter); setSearch(nextSearch)
  }
  function refresh() { returnTo.current = null; setSelected(null); setBusy(true); setError(null); setPage(null); setRevision((value) => value + 1) }
  const savings = page?.program_type === 'savings'
  const filters: Array<[DailyFilter, string]> = savings
    ? [['all', 'Everyone'], ['needs_help', 'Need you'], ['checked_in', 'Checked in'], ['not_checked_in', 'No check-in']]
    : [['all', 'Everyone'], ['needs_help', 'Need you'], ['invited', 'Invited'], ['joined', 'Joined'], ['setup_done', 'Setup done']]
  return <>
    <header className="coach-daily-heading"><h2>Who needs me today?</h2><div>
      {page?.can_invite && <button className="coach-daily-primary" onClick={(event) => { if (!openCoachInvitation(event.currentTarget)) setError('Open Group invitations & access to invite someone.') }}>Invite someone</button>}
      <button onClick={refresh} disabled={busy}>Refresh</button>
    </div></header>
    {error && <p role="alert">{error}</p>}
    {busy && <p role="status">Loading people…</p>}
    <div className={`coach-daily-layout${selected ? ' has-detail' : ''}`}>
      <div className="coach-daily-list" ref={list}>
        {page && <>
          <div className="coach-challenge-summary" aria-label="Filter people">{filters.map(([value, label]) => <button key={value} aria-pressed={filter === value} onClick={() => change(value)}><strong>{page.counts[value]}</strong> {label}</button>)}</div>
          <label>Find someone<input type="search" value={search} onChange={(event) => change(filter, event.target.value)} /></label>
          {!busy && !page.records.length && <p>{search || filter !== 'all' ? 'No one matches. Try another name or choose Everyone.' : 'No one in this group yet. Invite someone to get started.'}</p>}
          <ul className="coach-challenge-roster">{(!busy ? page.records : []).map((row) => <li key={row.participant.id} className={selected?.participant.id === row.participant.id ? 'is-selected' : undefined}>
            <div><strong>{row.participant.name}</strong><p className={row.needs_help ? 'coach-daily-need' : undefined}>{dailyNeed(row)}</p>
              <p>{savings ? savingsStatus(row) : householdStatus(row)}</p>
            </div>
            <button aria-label={`${row.needs_help ? 'View help for' : 'View'} ${row.participant.name}`} aria-pressed={selected?.participant.id === row.participant.id} onClick={(event) => { returnTo.current = { top: window.scrollY, button: event.currentTarget }; setSelected(row) }}>{row.needs_help ? 'View help' : 'View person'}</button>
          </li>)}</ul>
          {(offset > 0 || page.next_offset !== null) && <nav className="coach-challenge-actions" aria-label="People pages">
            <button disabled={busy || offset === 0} onClick={() => { setBusy(true); setOffset(Math.max(0, offset - 20)) }}>Previous people</button>
            <button disabled={busy || page.next_offset === null} onClick={() => { setBusy(true); setOffset(page.next_offset!) }}>More people</button>
          </nav>}
        </>}
      </div>
      {selected && <div className="coach-daily-detail" ref={detail}>
        <header><h3 tabIndex={-1}>{selected.participant.name}</h3><button onClick={() => { setSelected(null); setRevision((value) => value + 1) }}>Back to people</button></header>
        <p>{dailyNeed(selected)}</p><p>{savings ? savingsStatus(selected) : householdStatus(selected)}</p>
        {selected.setup_help.length > 0 && <SetupSupportInbox actorId={scope.user_id} workspaceId={scope.coach_workspace_id} cohortId={cohortId} participantId={selected.participant.id} isAdmin={false} readOnly />}
        {selected.setup_help.length > 0 && <button onClick={(event) => { openCoachSetupHelp(event.currentTarget, selected.participant.id) }}>Review setup help</button>}
        {selected.enrollment_id !== null && <Participant key={selected.enrollment_id} row={{ ...selected, enrollment_id: selected.enrollment_id, check_in: selected.check_in! }} />}
        {selected.enrollment_id === null && !selected.setup_help.length && <p>Private financial records and conversations stay private.</p>}
      </div>}
    </div>
    {savings && !selected && <details className="coach-report-disclosure"><summary>Checkpoint reports</summary><SponsorReports key={`${cohortId}:${revision}`} scope={scope} cohortId={cohortId} /></details>}
  </>
}
function householdStatus(row: CoachDailyPerson) {
  return row.membership_status === 'invited' ? 'Invited · Hasn’t joined yet' : row.membership_status === 'revoked' ? 'Account access removed' : row.setup_status === 'complete' ? 'Joined · Setup done' : 'Joined · Setup not finished'
}
function savingsStatus(row: CoachDailyPerson) {
  if (!row.enrollment_id) return row.membership_status === 'invited' ? 'Invited · Hasn’t joined yet' : 'Joined · Hasn’t started the challenge'
  return `${row.check_in?.completed === true ? 'Checked in today' : row.check_in?.completed === false ? 'No check-in yet' : 'Check-in unavailable'} · ${row.setup_status === 'plan_reviewed' ? 'Target confirmed' : 'No target confirmed yet'}`
}
function dailyNeed(row: CoachDailyPerson) {
  const needs: string[] = []
  for (const help of row.setup_help) needs.push(({ upload_problem: 'Asked for help with an upload', practice_numbers: 'Asked for help replacing practice numbers', wrong_setup: 'Asked for help correcting setup', other: 'Asked for help starting again' } as Record<string, string>)[help.reason] ?? 'Asked for setup help')
  if (row.help_requests.length) needs.push('Asked for challenge help')
  for (const item of row.shared_items) needs.push(item === 'savings_plan_version' ? 'Shared their target plan with you' : item === 'summary' ? 'Shared their progress with you' : `Shared ${recordLabel(item)} with you`)
  return [...new Set(needs)].join(' · ') || 'No open help requests'
}
function Participant({ row }: { row: CoachParticipant }) {
  const [scopes, setScopes] = useState<SharedScopes | null>(null),
    [error, setError] = useState<string | null>(null),
    [busy, setBusy] = useState(false),
    [summary, setSummary] = useState<Awaited<ReturnType<typeof coachChallengeApi.summary>> | null>(null),
    [detail, setDetail] = useState<Awaited<ReturnType<typeof coachChallengeApi.selected>> | null>(null),
    [sourceRef, setSourceRef] = useState<{ ref: SharedRecordRef; supportId?: number } | null>(null),
    [ticket, setTicket] = useState<Awaited<ReturnType<typeof coachChallengeApi.ticket>> | null>(null),
    [tickets, setTickets] = useState(row.help_requests),
    [helpCursor, setHelpCursor] = useState<number | null>(null),
    [helpStarted, setHelpStarted] = useState(false)
  const live = useRef(true),
    controller = useRef<AbortController | null>(null)
  useEffect(() => {
    live.current = true
    const clear = () => {
      controller.current?.abort()
      setBusy(false)
      setScopes(null)
      setSummary(null)
      setDetail(null)
      setTicket(null)
      setSourceRef(null)
    }
    const hidden = () => {
      if (document.hidden) clear()
    }
    window.addEventListener('focus', clear)
    document.addEventListener('visibilitychange', hidden)
    return () => {
      live.current = false
      controller.current?.abort()
      window.removeEventListener('focus', clear)
      document.removeEventListener('visibilitychange', hidden)
    }
  }, [])
  async function request(action: (signal: AbortSignal) => Promise<void>) {
    if (busy) return
    controller.current?.abort()
    const owned = new AbortController()
    controller.current = owned
    setBusy(true)
    setError(null)
    setScopes(null)
    setSummary(null)
    setDetail(null)
    setTicket(null)
    try {
      await action(owned.signal)
    } catch (failure) {
      if (live.current && !owned.signal.aborted) {
        setError(message(failure))
        setScopes(null)
        setSummary(null)
        setDetail(null)
        setTicket(null)
        if (failure instanceof ApiRequestError && [401, 403, 404].includes(failure.status)) setTickets([])
      }
    } finally {
      if (live.current && !owned.signal.aborted) setBusy(false)
    }
  }
  useEffect(() => {
    const owned = new AbortController()
    coachChallengeApi.scopes(row.enrollment_id, owned.signal).then((result) => {
      if (live.current && !owned.signal.aborted && result.enrollment_id === row.enrollment_id) setScopes(result)
    }).catch((failure) => { if (live.current && !owned.signal.aborted) setError(message(failure)) })
    return () => owned.abort()
  }, [row.enrollment_id])
  const current = (signal: AbortSignal) => live.current && !signal.aborted
  function selected(ref: SharedRecordRef, supportId?: number) {
    void request(async (signal) => {
      const result = await coachChallengeApi.selected(row.enrollment_id, ref, supportId, signal)
      if (current(signal)) {
        setDetail(result)
        setSourceRef({ ref, supportId })
      }
    })
  }
  return (
    <section className="coach-challenge-card" aria-label="Participant permitted sharing">
      <h4>Help &amp; sharing</h4>
      <p>Only what this person shared with you is available. Permission is checked each time you open a record.</p>
      {error && <p role="alert">{error}</p>}
      {busy && <p role="status">Loading shared items…</p>}
      <button
        disabled={busy}
        onClick={() =>
          void request(async (signal) => {
            const result = await coachChallengeApi.scopes(row.enrollment_id, signal)
            if (result.enrollment_id !== row.enrollment_id) throw new Error('Participant changed.')
            if (current(signal)) setScopes(result)
          })
        }
      >
        Refresh shared items
      </button>
      {scopes && (
        <>
          <p>{scopes.summary_available ? 'Challenge summary shared' : 'Challenge money summary is private'}</p>
          {scopes.summary_available && (
            <button
              disabled={busy}
              onClick={() =>
                void request(async (signal) => {
                  const result = await coachChallengeApi.summary(row.enrollment_id, signal)
                  if (result.enrollment_id !== row.enrollment_id) throw new Error('Participant changed.')
                  if (current(signal)) setSummary(result)
                })
              }
            >
              View shared progress
            </button>
          )}
          <ul>
            {scopes.selected_records.map((ref) => (
              <li key={`${ref.record_type}:${ref.record_id}`}>
                <button disabled={busy} onClick={() => selected(ref)}>
                  View shared {recordLabel(ref.record_type)}
                </button>
              </li>
            ))}
          </ul>
          {scopes.support_access.map((access) => (
            <section key={access.id}>
              <p>Shared until {formatCoachTime(access.expires_at)} (Guam time).</p>
              {access.selected_records.map((ref) => (
                <button
                  key={`${ref.record_type}:${ref.record_id}`}
                  disabled={busy}
                  onClick={() => selected(ref, access.id)}
                >
                  View shared {recordLabel(ref.record_type)}
                </button>
              ))}
            </section>
          ))}
        </>
      )}
      {summary && (
        <section aria-label="Consented savings summary">
          <h4>Participant-reported progress</h4>
          <p>
            {savingsDollars(summary.projection.reported_cents)} reported ·{' '}
            {savingsDollars(summary.projection.evidence_supported_cents)} matched to statements.
          </p>
          <p>
            Target {savingsDollars(summary.accepted_target_cents)}. The amount matched to statements is already included in the reported amount.
          </p>
        </section>
      )}
      {detail && (
        <SelectedFacts
          detail={detail}
          busy={busy}
          onSource={
            sourceRef?.ref.record_type === 'document_source'
              ? () =>
                  void request(async (signal) => {
                    const blob = await fetchSharedChallengeSource(
                      row.enrollment_id,
                      sourceRef.ref.record_id,
                      sourceRef.supportId,
                      signal
                    )
                    if (current(signal)) downloadBlob(blob, detail.filename ?? 'shared-original')
                  })
              : undefined
          }
        />
      )}
      <h4>Requests addressed to you</h4>
      {tickets.map((help) => (
        <button
          key={help.id}
          disabled={busy}
          onClick={() =>
            void request(async (signal) => {
              const result = await coachChallengeApi.ticket(row.enrollment_id, help.id, signal)
              if (current(signal)) setTicket(result)
            })
          }
        >
          Help request {help.id} · {help.status === 'triaged' ? 'In review' : help.status === 'resolved' ? 'Resolved' : 'Waiting for you'}
        </button>
      ))}
      {((row.more_help_requests && !helpStarted) || helpCursor !== null) && (
        <button
          disabled={busy}
          onClick={() =>
            void request(async (signal) => {
              const result = await coachChallengeApi.help(row.enrollment_id, helpStarted ? helpCursor : null, signal)
              if (current(signal)) {
                setTickets(result.records)
                setHelpCursor(result.next_cursor)
                setHelpStarted(true)
              }
            })
          }
        >
          More help requests
        </button>
      )}
      {ticket && (
        <section>
          <h4>
            Help request {ticket.id} · {ticket.status === 'triaged' ? 'In review' : ticket.status === 'resolved' ? 'Resolved' : 'Waiting for you'}
          </h4>
          <p className="coach-private-message">{ticket.message}</p>
          <p>
            A help request does not share private records by itself. Use Refresh shared items to see what this person chose to share.
          </p>
          <div className="coach-challenge-actions">
            {(['triaged', 'resolved'] as const).map((status) => (
              <button
                key={status}
                disabled={busy || ticket.status === status}
                onClick={() =>
                  void request(async (signal) => {
                    const result = await coachChallengeApi.ticketStatus(row.enrollment_id, ticket.id, status, signal)
                    if (current(signal)) {
                      setTicket({ ...ticket, status: result.status })
                      setTickets((items) =>
                        items.map((item) => (item.id === ticket.id ? { ...item, status: result.status } : item))
                      )
                    }
                  })
                }
              >
                {status === 'triaged' ? 'Mark in review' : 'Mark resolved'}
              </button>
            ))}
          </div>
        </section>
      )}
    </section>
  )
}
function SelectedFacts({
  detail,
  busy,
  onSource,
}: {
  detail: Awaited<ReturnType<typeof coachChallengeApi.selected>>
  busy: boolean
  onSource?: () => void
}) {
  const labels: Record<string, string> = {
    version_number: 'Approved version',
    event_type: 'Movement',
    disposition: 'Review decision',
    signed_amount_cents: 'Source movement',
    purchase_amount_cents: 'Purchase amount',
    posted_on: 'Posted date',
    merchant: 'Where',
    signed_cents: 'Reserved money or withdrawal',
    effective_on: 'Effective date',
    funding_source: 'Funding source',
    target_cents: 'Accepted target',
    reason: 'Participant explanation',
    role: 'Message author',
    content: 'Selected message',
    created_at: 'Sent',
  }
  return (
    <section aria-label="Exact selected record">
      <h4>Selected {recordLabel(detail.record_type)}</h4>
      {detail.filename ? (
        <>
          <p>
            {detail.filename} · {detail.source_available ? 'Original available' : 'Original unavailable'}. Downloaded
            copies cannot be recalled.
          </p>
          {onSource && detail.source_available && (
            <button disabled={busy} onClick={onSource}>
              Download this selected original
            </button>
          )}
        </>
      ) : (
        <dl>
          {Object.entries(detail.record ?? {})
            .filter(([key]) => key in labels)
            .map(([key, value]) => (
              <div key={key}>
                <dt>{labels[key]}</dt>
                <dd className="coach-private-message">
                  {key.endsWith('_cents') && typeof value === 'number'
                    ? savingsDollars(value)
                    : key === 'created_at' && typeof value === 'string' ? formatCoachTime(value)
                      : key.endsWith('_on') && typeof value === 'string' ? formatDay(value)
                      : String(value ?? 'Unknown')}
                </dd>
              </div>
            ))}
        </dl>
      )}
    </section>
  )
}
function SponsorReports({ scope, cohortId }: { scope: CoachChallengeScope; cohortId: number }) {
  const [index, setIndex] = useState<SponsorIndex | null>(null),
    [report, setReport] = useState<SponsorReport | null>(null),
    [exportId, setExportId] = useState<number | null>(null),
    [accepted, setAccepted] = useState(false),
    [day, setDay] = useState(30),
    [busy, setBusy] = useState(false),
    [error, setError] = useState<string | null>(null),
    [cursor, setCursor] = useState<number | null>(null)
  const live = useRef(true),
    controller = useRef<AbortController | null>(null)
  useEffect(() => {
    live.current = true
    return () => {
      live.current = false
      controller.current?.abort()
    }
  }, [])
  function verify(result: { actor_scope: CoachChallengeScope; cohort_id: number }) {
    if (
      result.actor_scope.user_id !== scope.user_id ||
      result.actor_scope.coach_workspace_id !== scope.coach_workspace_id ||
      result.cohort_id !== cohortId
    )
      throw new Error('Report program changed. Reopen it.')
  }
  async function request(action: (signal: AbortSignal) => Promise<void>) {
    if (busy) return
    const owned = new AbortController()
    controller.current = owned
    setBusy(true)
    setError(null)
    setReport(null)
    setIndex(null)
    try {
      await action(owned.signal)
    } catch (failure) {
      if (live.current && !owned.signal.aborted) {
        setReport(null)
        setIndex(null)
        setError(message(failure))
      }
    } finally {
      if (live.current && !owned.signal.aborted) setBusy(false)
    }
  }
  const current = (signal: AbortSignal) => live.current && !signal.aborted
  const selectedCheckpoint = index?.scheduled_checkpoints.find((row) => row.day === day)
  const sealBlockedReason = sealBlocker(selectedCheckpoint, day, index?.today_on)
  const sealReason = sealBlockedReason ?? (!accepted && !busy ? 'Tick the box above to confirm you reviewed how privacy works.' : null)
  return (
    <section className="coach-challenge-card">
      <h3>Group checkpoint reports</h3>
      <p>Group progress is shown in broad ranges, with permission. Names and personal amounts stay private.</p>
      <details><summary>How privacy works</summary><p>Groups smaller than five are hidden. Results are also hidden when comparing groups or reports could identify someone. Only people who currently agree to sponsor reporting are included. Reports cannot be filtered into smaller groups.</p></details>
      <button
        disabled={busy}
        onClick={() =>
          void request(async (signal) => {
            const result = await coachChallengeApi.exports(cohortId, cursor, signal)
            verify(result)
            if (current(signal)) setIndex(result)
          })
        }
      >
        Review scheduled reports
      </button>
      {error && <p role="alert">{error}</p>}
      {index && (
        <>
          <p>
            Saved reports are fixed. Later consent changes can make an earlier report unavailable; they do not rebuild
            it.
          </p>
          <label>
            Scheduled checkpoint
            <select
              value={day}
              disabled={busy}
              onChange={(event) => {
                setDay(Number(event.target.value))
                setAccepted(false)
              }}
            >
              {index.scheduled_checkpoints.map((row) => (
                <option key={row.day} value={row.day}>
                  Day {row.day} · {row.cutoff_on ? formatDay(row.cutoff_on) : 'Start date not set'}
                </option>
              ))}
            </select>
          </label>
          <label className="coach-challenge-check">
            <input
              type="checkbox"
              checked={accepted}
              disabled={busy}
              onChange={(event) => setAccepted(event.target.checked)}
            />
            I reviewed how privacy works and want to save this checkpoint report. This does not send it to the sponsor.
          </label>
          <button
            disabled={busy || !accepted || sealBlockedReason !== null}
            aria-describedby={sealReason ? 'seal-reason' : undefined}
            onClick={() =>
              void request(async (signal) => {
                const result = await coachChallengeApi.seal(cohortId, day, signal)
                verify(result)
                if (current(signal)) {
                  setReport(result.report)
                  setExportId(result.export_id)
                  setAccepted(false)
                }
              })
            }
          >
            Save reviewed Day {day} report
          </button>
          <DisabledReason id="seal-reason">{sealReason}</DisabledReason>
          {index.records.map((row) => (
            <button
              key={row.id}
              disabled={busy}
              onClick={() =>
                void request(async (signal) => {
                  const result = await coachChallengeApi.report(cohortId, row.id, signal)
                  verify(result)
                  if (current(signal)) {
                    setReport(result.report)
                    setExportId(result.export_id)
                  }
                })
              }
            >
              Read saved Day {row.checkpoint_day} · {formatDay(row.resolved_cutoff_on)}
            </button>
          ))}
          {index.next_cursor !== null && (
            <button
              disabled={busy}
              onClick={() => {
                setCursor(index.next_cursor)
                void request(async (signal) => {
                  const result = await coachChallengeApi.exports(cohortId, index.next_cursor, signal)
                  verify(result)
                  if (current(signal)) setIndex(result)
                })
              }}
            >
              More saved reports
            </button>
          )}
        </>
      )}
      {report && (
        <section aria-label="Coarse cohort report">
          <h4>
            Day {report.checkpoint_day} · {formatDay(report.cutoff_on)}
          </h4>
          <p>People who agreed to reporting: {report.suppressed ? 'Hidden to protect privacy' : report.active_consent_count_range}.</p>
          {report.suppressed ? (
            <p>Progress is hidden to protect people’s privacy.</p>
          ) : (
            <ul>
              {report.bands.map((row) => (
                <li key={row.band}>
                  {row.band.replaceAll('_', ' ')}: {row.count_range} people
                </li>
              ))}
            </ul>
          )}
          <p>These ranges reflect participant reports, not verified account balances.</p>
          <button
            disabled={busy || exportId === null}
            onClick={() =>
              void request(async (signal) => {
                const result = await coachChallengeApi.report(cohortId, exportId!, signal)
                verify(result)
                if (current(signal)) {
                  setReport(result.report)
                  setExportId(result.export_id)
                  downloadReport(result.report)
                }
              })
            }
          >
            Download this group report
          </button>
        </section>
      )}
    </section>
  )
}
function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename.replace(/[\\/]/g, '_')
  anchor.click()
  URL.revokeObjectURL(url)
}
function downloadReport(report: SponsorReport) {
  downloadBlob(
    new Blob([JSON.stringify(report, null, 2)], { type: 'application/json' }),
    `cohort-day-${report.checkpoint_day}.json`
  )
}
const recordLabel = (type: string) =>
  ({
    document_source: 'original file',
    source_review_version: 'reviewed statement row',
    savings_entry_version: 'savings entry',
    savings_plan_version: 'target plan',
    chat_message: 'message',
  })[type] ?? 'record'
const message = (failure: unknown) =>
  failure instanceof Error ? failure.message : 'This permitted view is unavailable. Refresh your program permissions.'

// The server refuses a checkpoint whose cutoff is after today. Say so up
// front instead of leaving the seal button disabled with no explanation.
function sealBlocker(checkpoint: { cutoff_on: string | null; sealable?: boolean } | undefined, day: number, serverToday?: string) {
  if (!checkpoint) return null
  if (!checkpoint.cutoff_on) return `Day ${day} cannot be saved yet because the group's start date is not set.`
  // The API reckons dates in Guam time, so compare against Guam's today.
  // The server's own verdict wins over this browser's clock; the cutoff day itself can be sealed.
  const today = serverToday ?? new Intl.DateTimeFormat('en-CA', { timeZone: 'Pacific/Guam' }).format(new Date())
  const blocked = checkpoint.sealable === undefined ? checkpoint.cutoff_on > today : !checkpoint.sealable
  if (blocked) return `Day ${day} hasn’t ended yet. You can save this report from ${formatDay(checkpoint.cutoff_on, { year: true })}.`
  return null
}
