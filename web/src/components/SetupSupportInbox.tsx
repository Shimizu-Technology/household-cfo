import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { fetchSetupSupportRequests, updateSetupSupportRequest } from '../setupHelpApi'
import type { SetupSupportRequest } from '../lib/setupHelp'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
import './SetupSupportInbox.css'

type Props = {
  actorId: number
  workspaceId: number | null
  cohortId: number | null
  isAdmin: boolean
  disabled?: boolean
  onPendingChange?: (pending: boolean) => void
  mutationLifecycle?: CoachWorkspaceMutationLifecycle
}
type SupportAction = 'triage' | 'prepare' | 'decline'
const statusLabels = { requested: 'Requested', in_review: 'In review', ready: 'Participant review ready', applied: 'Restart finished', canceled: 'Canceled', declined: 'Corrections recommended' }

// Remounting resets both the displayed metadata and any outstanding confirmation.
export function SetupSupportInbox(props: Props) {
  return <ScopedSetupSupportInbox key={`${props.actorId}:${props.workspaceId}:${props.cohortId}:${props.isAdmin}`} {...props} />
}

function ScopedSetupSupportInbox({ actorId, workspaceId, cohortId, isAdmin, disabled = false, onPendingChange, mutationLifecycle }: Props) {
  const canLoadScope = workspaceId !== null || isAdmin
  const [records, setRecords] = useState<SetupSupportRequest[]>([])
  const [cursor, setCursor] = useState<number | null>(null)
  const [nextCursor, setNextCursor] = useState<number | null>(null)
  const [loading, setLoading] = useState(canLoadScope)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [confirmation, setConfirmation] = useState<{ id: number; version: number } | null>(null)
  const [uncertainId, setUncertainId] = useState<number | null>(null)
  const live = useRef(true)
  const sequence = useRef(0)
  const controller = useRef<AbortController | null>(null)
  const savingRef = useRef(false)
  const callbacks = useRef({ onPendingChange, mutationLifecycle })
  useLayoutEffect(() => { callbacks.current = { onPendingChange, mutationLifecycle } }, [onPendingChange, mutationLifecycle])
  useEffect(() => {
    live.current = true
    return () => {
      live.current = false
      sequence.current += 1
      controller.current?.abort()
      callbacks.current.onPendingChange?.(false)
    }
  }, [])

  const load = useCallback(async (pageCursor: number | null, verifyId: number | null = null, actionMessage?: string) => {
    if (!canLoadScope) return
    controller.current?.abort()
    const abort = new AbortController()
    controller.current = abort
    const requestSequence = ++sequence.current
    const current = () => live.current && requestSequence === sequence.current && !abort.signal.aborted
    setLoading(true)
    setError(null)
    setNotice(null)
    setConfirmation(null)
    try {
      const page = await fetchSetupSupportRequests(cohortId, pageCursor, abort.signal)
      if (!current()) return
      setRecords(page.records)
      setCursor(pageCursor)
      setNextCursor(page.next_cursor)
      // A lost reply must be checked by exact request ID before another action.
      let verified = verifyId === null || page.records.some((record) => record.id === verifyId)
      let searchCursor: number | null = null
      let exhausted = false
      for (let pages = 0; verifyId !== null && !verified && pages < 10; pages += 1) {
        const result = await fetchSetupSupportRequests(cohortId, searchCursor, abort.signal)
        if (!current()) return
        const found = result.records.find((record) => record.id === verifyId)
        if (found) {
          setRecords((existing) => existing.some((record) => record.id === verifyId)
            ? existing.map((record) => record.id === verifyId ? found : record)
            : [found, ...existing].slice(0, 30))
          verified = true
          break
        }
        searchCursor = result.next_cursor
        if (searchCursor === null) { exhausted = true; break }
      }
      if (verifyId !== null) {
        if (verified || exhausted) {
          setUncertainId(null)
          const verification = verified ? `Request #${verifyId} has been reloaded. Check its current status before acting again.` : `Request #${verifyId} is no longer available in this scope.`
          setNotice(actionMessage ? `${actionMessage} No action was repeated. ${verification}` : verification)
        } else {
          setUncertainId(verifyId)
          setError(`${actionMessage ? `${actionMessage} ` : ''}Request #${verifyId} could not be verified. Fresh requests will check again; no action has been repeated.`)
        }
      }
    } catch (caught) {
      if (!current()) return
      setRecords([])
      setNextCursor(null)
      const verificationError = errorMessage(caught, 'Setup requests could not be loaded.')
      if (verifyId !== null) {
        setUncertainId(verifyId)
        setError(`${actionMessage ? `${actionMessage} ` : ''}Request #${verifyId} could not be verified: ${verificationError} No action was repeated. Refresh its status before acting again.`)
      } else setError(verificationError)
    } finally {
      if (current()) setLoading(false)
    }
  }, [cohortId, canLoadScope])

  useEffect(() => {
    let canceled = false
    queueMicrotask(() => { if (!canceled) void load(null) })
    return () => { canceled = true }
  }, [load, actorId])

  async function act(record: SetupSupportRequest, action: SupportAction) {
    if (savingRef.current || loading || disabled || uncertainId !== null || !canLoadScope || (action === 'prepare' && !isAdmin)) return
    if (!record.permissions?.[action]) return
    if (action === 'prepare' && (confirmation?.id !== record.id || confirmation.version !== record.lock_version)) return
    savingRef.current = true
    callbacks.current.onPendingChange?.(true)
    const lifecycle = callbacks.current.mutationLifecycle
    const ticket = lifecycle?.begin()
    const current = () => live.current && (!ticket || lifecycle!.isCurrent(ticket))
    setSaving(true)
    setError(null)
    setNotice(null)
    setConfirmation(null)
    try {
      const response = await updateSetupSupportRequest(record.id, action, record.lock_version)
      if (!current()) return
      setRecords((existing) => existing.map((item) => item.id === record.id ? response.request : item))
      setNotice(action === 'prepare' ? `Request #${record.id}: the participant can now review and confirm the restart. No financial records changed.` : `Request #${record.id}: ${statusLabels[response.request.status]}.`)
    } catch (caught) {
      if (!current()) return
      setUncertainId(record.id)
      const message = errorMessage(caught, 'The request action could not be confirmed.')
      await load(cursor, record.id, message)
    } finally {
      if (ticket) lifecycle!.finish(ticket)
      savingRef.current = false
      if (live.current) {
        setSaving(false)
        callbacks.current.onPendingChange?.(false)
      }
    }
  }

  const blocked = disabled || saving || loading || uncertainId !== null
  return (
    <article className="panel setup-support-inbox" aria-label="Setup help requests" aria-busy={loading || saving}>
      <header className="setup-support-heading">
        <div><p className="eyebrow">Participant setup help</p><h3>Setup requests</h3></div>
        <Button variant="secondary" disabled={disabled || saving || loading || !canLoadScope} onClick={() => { setNotice(null); void load(null, uncertainId) }}>Fresh requests</Button>
      </header>
      <p className="setup-support-privacy">Only request metadata is shared here. Financial details, documents and private conversations stay private. The participant must review and confirm every restart.</p>
      {!canLoadScope ? <p>Choose a workspace to view its setup requests.</p> : <>
        {workspaceId === null && <p>Platform support requests; select a program workspace for its requests.</p>}
        {error && <div className="setup-support-alert" role="alert"><p>{error}</p><Button variant="secondary" disabled={disabled || saving || loading} onClick={() => void load(cursor, uncertainId)}>Retry loading requests</Button></div>}
        {notice && <p role="status" className="setup-support-notice">{notice}</p>}
        {loading && <p role="status">Loading setup requests…</p>}
        {!loading && !error && records.length === 0 && <p>No setup requests in this scope.</p>}
        <div className="setup-support-records">
          {records.map((record) => {
            const open = ['requested', 'in_review', 'ready'].includes(record.status)
            const canPrepare = isAdmin && record.permissions?.prepare && (record.status === 'requested' || record.status === 'in_review' || (record.status === 'ready' && ['expired', 'stale'].includes(record.review_state)))
            return <section className="setup-support-record" key={record.id} aria-label={`Request #${record.id}`}>
              <header><h4>{record.participant_name || 'Participant'}</h4><span className="setup-support-status">{record.status === 'ready' && ['expired', 'stale'].includes(record.review_state) ? 'Review needs refreshing' : statusLabels[record.status]}</span></header>
              <dl>
                <div><dt>Request</dt><dd>#{record.id}</dd></div>
                <div><dt>Program</dt><dd>{record.program_name || 'No program linked'}</dd></div>
                <div><dt>Reason</dt><dd>{record.reason_label}</dd></div>
                <div><dt>Requested</dt><dd><time dateTime={record.created_at}>{formatDate(record.created_at)}</time></dd></div>
              </dl>
              {record.status === 'ready' && <p>{record.review_state === 'expired' ? 'The participant review expired.' : record.review_state === 'stale' ? 'The participant review needs refreshing because the setup changed.' : 'Waiting for the participant to review and confirm.'}</p>}
              {open && !record.permissions?.triage && !record.permissions?.decline && !(isAdmin && record.permissions?.prepare) && <p>Your current access is read-only for this request.</p>}
              {open && <div className="setup-support-actions">
                {record.status === 'requested' && record.permissions?.triage && <Button variant="secondary" disabled={blocked} onClick={() => void act(record, 'triage')}>Mark in review</Button>}
                {record.permissions?.decline && <Button variant="secondary" disabled={blocked} onClick={() => void act(record, 'decline')}>Recommend corrections</Button>}
                {canPrepare && <Button disabled={blocked} onClick={() => setConfirmation({ id: record.id, version: record.lock_version })}>Prepare participant review</Button>}
              </div>}
              {confirmation?.id === record.id && <div className="setup-support-confirmation" role="group" aria-label={`Confirm review preparation for request #${record.id}`}>
                <p>Prepare a restart review for {record.participant_name || 'this participant'}? This does not change financial records. The participant must review the exact scope and confirm before any restart happens.</p>
                <div className="setup-support-actions"><Button disabled={blocked} onClick={() => void act(record, 'prepare')}>Confirm preparation</Button><Button variant="secondary" disabled={saving} onClick={() => setConfirmation(null)}>Cancel</Button></div>
              </div>}
            </section>
          })}
        </div>
        {nextCursor !== null && <div className="setup-support-pagination"><p>Showing one page of requests. Fresh requests returns to the first page.</p><Button variant="secondary" disabled={blocked} onClick={() => { setNotice(null); void load(nextCursor) }}>Load more requests</Button></div>}
      </>}
    </article>
  )
}

function errorMessage(caught: unknown, fallback: string) {
  const status = typeof caught === 'object' && caught !== null && 'status' in caught ? caught.status : null
  if (status === 401 || status === 403) return 'Your current workspace or program permissions do not allow this action. Refresh your access before trying again.'
  if (status === 409) return 'The request or participant setup changed. The previous confirmation has been discarded.'
  return caught instanceof Error ? caught.message : fallback
}
function formatDate(value: string) {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? 'Date unavailable' : new Intl.DateTimeFormat('en-US', { dateStyle: 'medium', timeStyle: 'short' }).format(date)
}
