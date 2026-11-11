import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { ApiRequestError, fetchSharedChallengeSource } from '../api'
import {
  coachChallengeApi,
  type CoachParticipant,
  formatCoachTime,
  type SharedScopes,
  type SharedRecordRef,
} from '../lib/coachChallengeApi'
import { holdWorkspaceLock } from './coachWorkspaceMutationLifecycle'
import { savingsDollars } from '../lib/savingsChallenge'
import { formatDay } from '../lib/plainDates'
import './ParticipantHelp.css'

// Shared across panel mounts: a later status write waits for the earlier server response.
const statusWrites = new Map<string, Promise<unknown>>()

export function ParticipantHelp({ row, onTicketChanged }: { row: CoachParticipant; onTicketChanged?: () => void }) {
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
    controller = useRef<AbortController | null>(null),
    changed = useRef(onTicketChanged)
  useLayoutEffect(() => { changed.current = onTicketChanged }, [onTicketChanged])
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
  // A status change is a write: it keeps the program from being switched until it settles, and it is not cancelled if
  // this panel closes first, so the answer is never left unknown. The screen behind is told when it lands.
  async function changeStatus(help: NonNullable<typeof ticket>, status: 'triaged' | 'resolved') {
    const release = holdWorkspaceLock()
    try {
      await request(async (signal) => {
        const key = `${row.enrollment_id}:${help.id}`
        const previous = statusWrites.get(key) ?? Promise.resolve()
        const write = previous.catch(() => undefined).then(() =>
          coachChallengeApi.ticketStatus(row.enrollment_id, help.id, status, new AbortController().signal))
        statusWrites.set(key, write)
        let result
        try { result = await write }
        finally { if (statusWrites.get(key) === write) statusWrites.delete(key) }
        changed.current?.()
        if (current(signal)) {
          setTicket({ ...help, status: result.status })
          setTickets((items) => items.map((item) => (item.id === help.id ? { ...item, status: result.status } : item)))
        }
      })
    } finally {
      release()
    }
  }
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
                // Each page is added to the ones already shown; a request that appears twice is shown once.
                setTickets((items) => [...items, ...result.records.filter((record) => !items.some((item) => item.id === record.id))])
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
                onClick={() => void changeStatus(ticket, status)}
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
function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename.replace(/[\\/]/g, '_')
  anchor.click()
  URL.revokeObjectURL(url)
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
