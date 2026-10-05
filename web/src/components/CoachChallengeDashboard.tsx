import { useEffect, useRef, useState } from 'react'
import { ApiRequestError, fetchSharedChallengeSource } from '../api'
import {
  coachChallengeApi,
  type CoachChallengeScope,
  type CoachParticipant,
  type SharedScopes,
  type SponsorIndex,
  type SponsorReport,
  type SharedRecordRef,
} from '../lib/coachChallengeApi'
import { savingsDollars } from '../lib/savingsChallenge'
import './CoachChallengeDashboard.css'

type Props = { userId: number; workspaceId: number; cohorts: Array<{ id: number; name: string }>; selectedCohortId?: number | null }
export function CoachChallengeDashboard(props: Props) {
  return <Dashboard key={`${props.userId}:${props.workspaceId}`} {...props} />
}
function Dashboard({ userId, workspaceId, cohorts, selectedCohortId }: Props) {
  const [localCohortId, setCohortId] = useState<number | null>(null)
  const cohortId = selectedCohortId === undefined ? localCohortId : selectedCohortId
  return (
    <section className="coach-challenge">
      <h2>Challenge check-ins & help</h2>
      <p>
        Participation and completed daily reports are visible here. Money and exact private records require the
        participant’s separate sharing permission.
      </p>
      {selectedCohortId === undefined && <label>
        Challenge group
        <select
          value={cohortId ?? ''}
          onChange={(event) => setCohortId(event.target.value ? Number(event.target.value) : null)}
        >
          <option value="">Choose a group</option>
          {cohorts.map((row) => (
            <option key={row.id} value={row.id}>
              {row.name}
            </option>
          ))}
        </select>
      </label>}
      {selectedCohortId !== undefined && <p className="coach-current-group">{cohorts.find((row) => row.id === cohortId)?.name ?? 'Choose a group below to see check-ins and help.'}</p>}
      {cohortId && (
        <Group key={cohortId} scope={{ user_id: userId, coach_workspace_id: workspaceId }} cohortId={cohortId} />
      )}
    </section>
  )
}
function Group({ scope, cohortId }: { scope: CoachChallengeScope; cohortId: number }) {
  const [rows, setRows] = useState<CoachParticipant[]>([]),
    [cursor, setCursor] = useState<number | null>(null),
    [next, setNext] = useState<number | null>(null),
    [pages, setPages] = useState<Array<number | null>>([]),
    [selected, setSelected] = useState<CoachParticipant | null>(null),
    [revision, setRevision] = useState(0),
    [busy, setBusy] = useState(true),
    [error, setError] = useState<string | null>(null),
    [search, setSearch] = useState(''),
    [rowPage, setRowPage] = useState(0)
  useEffect(() => {
    let live = true
    const controller = new AbortController()
    coachChallengeApi
      .participants(cohortId, cursor, controller.signal)
      .then((result) => {
        if (
          result.actor_scope.user_id !== scope.user_id ||
          result.actor_scope.coach_workspace_id !== scope.coach_workspace_id ||
          result.cohort_id !== cohortId
        )
          throw new Error('The program changed. Reopen its challenge view.')
        if (live) {
          setRows(result.records)
          setNext(result.next_cursor)
          setBusy(false)
        }
      })
      .catch((failure) => {
        if (live) {
          setRows([])
          setSelected(null)
          setBusy(false)
          setError(message(failure))
        }
      })
    return () => {
      live = false
      controller.abort()
    }
  }, [scope.user_id, scope.coach_workspace_id, cohortId, cursor, revision])
  function reload() {
    setRows([])
    setSelected(null)
    setBusy(true)
    setError(null)
    setRowPage(0)
    setRevision((value) => value + 1)
  }
  const matchingRows = rows.filter((row) => row.participant.name.toLowerCase().includes(search.trim().toLowerCase()))
  const rowPages = Math.ceil(matchingRows.length / 10)
  const visibleRows = matchingRows.slice(rowPage * 10, (rowPage + 1) * 10)
  return (
    <>
      <button type="button" onClick={reload} disabled={busy}>
        Refresh current permissions
      </button>
      {error && <p role="alert">{error}</p>}
      {busy && <p role="status">Loading permitted participation metadata…</p>}
      {!busy && rows.length > 0 && <>
        <p className="coach-page-scope">Current page only. Search filters these enrolled participants; use More participants when available.</p><div className="coach-challenge-summary"><span><strong>{rows.filter((row) => row.check_in.completed === true).length}</strong> daily reports complete</span><span><strong>{rows.filter((row) => row.check_in.completed === false).length}</strong> reports not completed</span><span><strong>{rows.filter((row) => row.help_requests.some((request) => request.status !== 'resolved')).length}</strong> participants with visible open help</span></div>
        <label>Find an enrolled participant<input type="search" value={search} onChange={(event) => { setSearch(event.target.value); setRowPage(0); setSelected(null) }} /></label>
      </>}
      {!busy && !error && rows.length === 0 && <p>No enrolled participants on this page. Invitations and group access are listed below.</p>}
      {!busy && rows.length > 0 && visibleRows.length === 0 && <p>No enrolled participants on this page match your search.</p>}
      <ul className="coach-challenge-roster">
        {visibleRows.map((row) => (
          <li key={row.enrollment_id}>
            <strong>{row.participant.name}</strong>
            <p>
              {row.participation_status} · {row.setup_status === 'plan_reviewed' ? 'Plan reviewed' : 'Plan pending'}
            </p>
            <p>
              {row.check_in.local_on}:{' '}
              {row.check_in.completed === null
                ? 'Check-in unavailable'
                : row.check_in.completed
                  ? 'Daily report completed'
                  : 'No completed daily report yet'}
              .
            </p>
            <button type="button" onClick={() => setSelected(row)}>
              Open permitted help & sharing
            </button>
          </li>
        ))}
      </ul>
      {rowPages > 1 && <div className="coach-challenge-actions" aria-label="Check-in pages"><button disabled={rowPage === 0} onClick={() => { setRowPage(rowPage - 1); setSelected(null) }}>Previous check-ins</button><span>Page {rowPage + 1} of {rowPages} · {matchingRows.length} enrolled participants loaded</span><button disabled={rowPage + 1 >= rowPages} onClick={() => { setRowPage(rowPage + 1); setSelected(null) }}>Next check-ins</button></div>}
      {(pages.length > 0 || next !== null) && <div className="coach-challenge-actions">
        <button
          disabled={busy || !pages.length}
          onClick={() => {
            setSelected(null)
            setRowPage(0)
            setRows([])
            setBusy(true)
            setCursor(pages.at(-1)!)
            setPages(pages.slice(0, -1))
          }}
        >
          Previous participants
        </button>
        <button
          disabled={busy || next === null}
          onClick={() => {
            setSelected(null)
            setRowPage(0)
            setRows([])
            setBusy(true)
            setPages([...pages, cursor])
            setCursor(next)
          }}
        >
          More participants
        </button>
      </div>}
      {selected && (
        <Participant key={`participant:${selected.enrollment_id}:${revision}`} row={selected} onClose={() => setSelected(null)} />
      )}
      <details className="coach-report-disclosure"><summary>Checkpoint reports</summary><SponsorReports key={`sponsor:${cohortId}:${revision}`} scope={scope} cohortId={cohortId} /></details>
    </>
  )
}
function Participant({ row, onClose }: { row: CoachParticipant; onClose: () => void }) {
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
      <header>
        <h3>{row.participant.name}</h3>
        <button onClick={onClose}>Close participant</button>
      </header>
      <p>Opening an exact record rechecks current consent. Refresh or close this panel after use.</p>
      {error && <p role="alert">{error}</p>}
      {busy && <p role="status">Checking current permission…</p>}
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
        Check current sharing permissions
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
              Open consented savings summary
            </button>
          )}
          <ul>
            {scopes.selected_records.map((ref) => (
              <li key={`${ref.record_type}:${ref.record_id}`}>
                <button disabled={busy} onClick={() => selected(ref)}>
                  Open selected {recordLabel(ref.record_type)} #{ref.record_id}
                </button>
              </li>
            ))}
          </ul>
          {scopes.support_access.map((access) => (
            <section key={access.id}>
              <p>Time-bound support permission ends {access.expires_at}.</p>
              {access.selected_records.map((ref) => (
                <button
                  key={`${ref.record_type}:${ref.record_id}`}
                  disabled={busy}
                  onClick={() => selected(ref, access.id)}
                >
                  Open selected support {recordLabel(ref.record_type)} #{ref.record_id}
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
            {savingsDollars(summary.projection.evidence_supported_cents)} evidence-supported subset.
          </p>
          <p>
            Accepted target {savingsDollars(summary.accepted_target_cents)}. The supported subset is part of the
            reported amount.
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
          {help.issue_kind.replaceAll('_', ' ')} · {help.status} · Open request #{help.id}
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
            Request #{ticket.id} · {ticket.status}
          </h4>
          <p className="coach-private-message">{ticket.message}</p>
          <p>
            Selected references do not grant access automatically. Check the participant’s current sharing permission
            above.
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
                Mark {status}
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
  return (
    <section className="coach-challenge-card">
      <h3>Fixed cohort checkpoint reports</h3>
      <p>
        Reports use active sponsor consent and coarse ranges. Small cells, complements and revealing changes are
        suppressed. No personal money, names or dynamic subgroup filters are included.
      </p>
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
            Sealed reports are fixed. Later consent changes can make an earlier report unavailable; they do not rebuild
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
                  Day {row.day} · {row.cutoff_on ?? 'Start not configured'}
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
            Seal the scheduled checkpoint after reviewing the consent and suppression policy. This does not send it to
            BOG.
          </label>
          <button
            disabled={busy || !accepted}
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
            Seal reviewed Day {day} report
          </button>
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
              Read sealed Day {row.checkpoint_day} · {row.resolved_cutoff_on}
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
              More sealed reports
            </button>
          )}
        </>
      )}
      {report && (
        <section aria-label="Coarse cohort report">
          <h4>
            Day {report.checkpoint_day} · {report.cutoff_on}
          </h4>
          <p>Active consent denominator: {report.active_consent_count_range}.</p>
          {report.suppressed ? (
            <p>Progress bands suppressed by the reporting policy.</p>
          ) : (
            <ul>
              {report.bands.map((row) => (
                <li key={row.band}>
                  {row.band.replaceAll('_', ' ')}: {row.count_range} people
                </li>
              ))}
            </ul>
          )}
          <p>{report.qualification}</p>
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
            Download this coarse report
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
