import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import {
  ApiRequestError,
  createAdminContentSourceUrlIntake,
  createAdminContentSourceUrlRequestId,
  deleteAdminContentSourceUrlIntake,
  fetchAdminContentSourceUrlIntake,
  fetchAdminContentSourceUrlIntakes,
  retryAdminContentSourceUrlIntakeCleanup,
} from '../api'
import type {
  AdminContentScope,
  AdminContentSourceUrlIntake,
  AdminContentSourceUrlIntakeCapability,
} from '../api'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle, CoachWorkspaceMutationTicket } from './coachWorkspaceMutationLifecycle'

const activeStatuses = new Set<AdminContentSourceUrlIntake['status']>([
  'queued', 'fetching', 'staged', 'registering', 'cleanup_pending',
])
const maximumPollFailures = 4

type RetrySecret = { url: string; requestId: string; scope: AdminContentScope }
type ReconciliationResult =
  | { kind: 'found'; intake: AdminContentSourceUrlIntake }
  | { kind: 'deleted' }
  | { kind: 'inaccessible' }
  | { kind: 'unavailable' }

export function CoachUrlSourceIntake({
  scope,
  canCreate,
  permissionEnabled,
  disabled,
  mutationLifecycle,
  onDirtyChange,
  onBusyChange,
  onSourceReady,
}: {
  scope: AdminContentScope
  canCreate: boolean
  permissionEnabled?: boolean
  disabled: boolean
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  onDirtyChange: (dirty: boolean) => void
  onBusyChange: (busy: boolean) => void
  onSourceReady: (sourceId: number) => void
}) {
  const [url, setUrl] = useState('')
  const [requestId, setRequestId] = useState<string | null>(null)
  const [intakes, setIntakes] = useState<AdminContentSourceUrlIntake[]>([])
  const [capability, setCapability] = useState<AdminContentSourceUrlIntakeCapability | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadFailed, setLoadFailed] = useState(false)
  const [pollFailed, setPollFailed] = useState(false)
  const [action, setAction] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [confirmRedactionId, setConfirmRedactionId] = useState<number | null>(null)
  const mounted = useRef(true)
  const requestSequence = useRef(0)
  const actionRef = useRef<string | null>(null)
  const retrySecrets = useRef(new Map<number, RetrySecret>())
  const pollFailures = useRef(new Map<number, number>())
  const errorRef = useRef<HTMLDivElement>(null)
  const noticeRef = useRef<HTMLDivElement>(null)

  const busy = Boolean(action)
  const available = permissionEnabled !== false && capability?.enabled !== false && capability?.available !== false
  const formDirty = url.trim().length > 0

  useEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])
  useEffect(() => onDirtyChange(formDirty), [formDirty, onDirtyChange])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])
  useEffect(() => onBusyChange(busy), [busy, onBusyChange])
  useEffect(() => () => onBusyChange(false), [onBusyChange])
  useEffect(() => { if (error) queueMicrotask(() => errorRef.current?.focus()) }, [error])
  useEffect(() => { if (notice) queueMicrotask(() => noticeRef.current?.focus()) }, [notice])

  const loadIntakes = useCallback(async () => {
    const sequence = ++requestSequence.current
    setLoading(true)
    setLoadFailed(false)
    setPollFailed(false)
    setError(null)
    try {
      const result = await fetchAdminContentSourceUrlIntakes(scope)
      if (!mounted.current || sequence !== requestSequence.current) return
      setIntakes(result.intakes)
      setCapability(result.url_intake ?? null)
    } catch (caught) {
      if (!mounted.current || sequence !== requestSequence.current) return
      setLoadFailed(true)
      setError(messageFor(caught, 'Secure web source requests could not load.'))
    } finally {
      if (mounted.current && sequence === requestSequence.current) setLoading(false)
    }
  }, [scope])

  useEffect(() => { queueMicrotask(() => void loadIntakes()) }, [loadIntakes])

  useEffect(() => {
    const activeIds = intakes.filter((intake) => activeStatuses.has(intake.status)).map((intake) => intake.id)
    if (activeIds.length === 0) return

    let cancelled = false
    let timer = 0
    const poll = async () => {
      const results = await Promise.allSettled(activeIds.map((id) => fetchAdminContentSourceUrlIntake(id)))
      if (cancelled) return
      const updates = results.flatMap((result) => result.status === 'fulfilled' ? [result.value.intake] : [])
      const inaccessibleIds: number[] = []
      let retryFailures = 0
      results.forEach((result, index) => {
        const id = activeIds[index]
        if (result.status === 'fulfilled') {
          pollFailures.current.delete(id)
          return
        }
        if (result.reason instanceof ApiRequestError && [403, 404].includes(result.reason.status)) {
          inaccessibleIds.push(id)
          pollFailures.current.delete(id)
          retrySecrets.current.delete(id)
          return
        }
        const failures = (pollFailures.current.get(id) ?? 0) + 1
        pollFailures.current.set(id, failures)
        retryFailures = Math.max(retryFailures, failures)
      })
      if (inaccessibleIds.length > 0) {
        setIntakes((current) => current.filter((intake) => !inaccessibleIds.includes(intake.id)))
        setNotice('A secure import is no longer available. The list was refreshed for your current access.')
      }
      if (updates.length > 0) {
        setIntakes((current) => mergeIntakes(current, updates))
        for (const intake of updates) {
          if (intake.status === 'registered' && intake.source_id) {
            retrySecrets.current.delete(intake.id)
            onSourceReady(intake.source_id)
          }
          if (intake.status === 'failed') setNotice('The secure import needs attention. Its saved address is still private and can be removed.')
          if (intake.status === 'deleted') retrySecrets.current.delete(intake.id)
        }
      }
      const stillActive = updates.some((intake) => activeStatuses.has(intake.status))
      if (retryFailures >= maximumPollFailures) {
        setPollFailed(true)
        setError('A secure import stopped updating. Reload its current state before continuing.')
      } else if (inaccessibleIds.length === 0 && (retryFailures > 0 || stillActive)) {
        const delay = retryFailures > 0 ? Math.min(2500 * (2 ** (retryFailures - 1)), 20_000) : 2500
        timer = window.setTimeout(() => void poll(), delay)
      }
    }
    timer = window.setTimeout(() => void poll(), 1800)
    return () => { cancelled = true; window.clearTimeout(timer) }
  }, [intakes, onSourceReady])

  function changeUrl(value: string) {
    setUrl(value)
    setRequestId(null)
    if (!pollFailed) setError(null)
    setNotice(null)
  }

  async function submit(event: FormEvent) {
    event.preventDefault()
    const normalized = url.trim()
    if (!normalized || disabled || busy || !canCreate || !available) return
    if (!isHttpsUrl(normalized)) {
      setError('Enter a complete HTTPS address, such as https://example.com/guide.')
      return
    }
    const stableRequestId = requestId ?? createAdminContentSourceUrlRequestId()
    setRequestId(stableRequestId)
    await runAction('create', async (ticket) => {
      const result = await createAdminContentSourceUrlIntake({ url: normalized, requestId: stableRequestId, scope })
      if (!mutationLifecycle.isCurrent(ticket)) return
      retrySecrets.current.set(result.intake.id, { url: normalized, requestId: stableRequestId, scope })
      setIntakes((current) => mergeIntakes(current, [result.intake]))
      setCapability(result.url_intake ?? capability)
      setUrl('')
      setRequestId(null)
      setNotice('Secure import queued. The server will save a private, fixed snapshot for review.')
    }, 'The secure web source could not be queued.')
  }

  async function retry(intake: AdminContentSourceUrlIntake) {
    const secret = retrySecrets.current.get(intake.id)
    if (!secret) {
      setNotice('Remove this failed request, then enter the HTTPS address again. The address is never returned to this screen.')
      return
    }
    await runAction(`retry:${intake.id}`, async (ticket) => {
      const result = await createAdminContentSourceUrlIntake(secret)
      if (!mutationLifecycle.isCurrent(ticket)) return
      setIntakes((current) => mergeIntakes(current, [result.intake]))
      setNotice('Secure import retry queued with the original request ID.')
    }, 'The secure import could not be retried.')
  }

  async function redact(intake: AdminContentSourceUrlIntake) {
    await runAction(`redact:${intake.id}`, async (ticket) => {
      let result: Awaited<ReturnType<typeof deleteAdminContentSourceUrlIntake>>
      try {
        result = await deleteAdminContentSourceUrlIntake(intake.id)
      } catch (caught) {
        const reconciled = await reconcileIntake(intake.id, ticket)
        if (reconciled.kind === 'deleted' || (reconciled.kind === 'found' && reconciled.intake.redaction_pending)) {
          retrySecrets.current.delete(intake.id)
          setConfirmRedactionId(null)
          setNotice(reconciled.kind === 'found'
            ? 'The address was redacted. Private snapshot cleanup is in progress.'
            : 'Saved address removed. Minimal redacted audit metadata remains.')
          return
        }
        if (reconciled.kind === 'inaccessible') {
          setConfirmRedactionId(null)
          setError('This request is no longer accessible. Address removal could not be confirmed.')
          return
        }
        throw caught
      }
      if (!mutationLifecycle.isCurrent(ticket)) return
      retrySecrets.current.delete(intake.id)
      setIntakes((current) => result.intake.status === 'deleted'
        ? current.filter((value) => value.id !== intake.id)
        : mergeIntakes(current, [result.intake]))
      setConfirmRedactionId(null)
      setNotice(result.intake.status === 'deleted'
        ? 'Saved address removed. Minimal redacted audit metadata remains.'
        : 'The address was redacted. Private snapshot cleanup is in progress.')
    }, 'The saved address could not be removed.')
  }

  async function retryCleanup(intake: AdminContentSourceUrlIntake) {
    await runAction(`cleanup:${intake.id}`, async (ticket) => {
      let updated: Awaited<ReturnType<typeof retryAdminContentSourceUrlIntakeCleanup>>
      try {
        updated = await retryAdminContentSourceUrlIntakeCleanup(intake.id)
      } catch (caught) {
        const reconciled = await reconcileIntake(intake.id, ticket)
        if (reconciled.kind === 'found' || reconciled.kind === 'deleted') {
          setNotice('The latest private cleanup state was refreshed. Retry remains available if cleanup still needs attention.')
          return
        }
        if (reconciled.kind === 'inaccessible') {
          setNotice('This request is no longer accessible. Its cleanup state could not be confirmed.')
          return
        }
        throw caught
      }
      if (!mutationLifecycle.isCurrent(ticket)) return
      setIntakes((current) => mergeIntakes(current, [updated]))
      setNotice('Private snapshot cleanup was queued again.')
    }, 'Private snapshot cleanup could not be retried.')
  }

  async function reconcileIntake(id: number, ticket: CoachWorkspaceMutationTicket): Promise<ReconciliationResult> {
    try {
      const result = await fetchAdminContentSourceUrlIntake(id)
      if (!mutationLifecycle.isCurrent(ticket)) return { kind: 'unavailable' }
      if (result.intake.status === 'deleted') {
        setIntakes((current) => current.filter((intake) => intake.id !== id))
        return { kind: 'deleted' }
      }
      setIntakes((current) => mergeIntakes(current, [result.intake]))
      return { kind: 'found', intake: result.intake }
    } catch (caught) {
      if (caught instanceof ApiRequestError && caught.status === 404) {
        if (mutationLifecycle.isCurrent(ticket)) {
          retrySecrets.current.delete(id)
          setIntakes((current) => current.filter((intake) => intake.id !== id))
        }
        return { kind: 'inaccessible' }
      }
      return { kind: 'unavailable' }
    }
  }

  async function runAction(
    name: string,
    callback: (ticket: CoachWorkspaceMutationTicket) => Promise<void>,
    fallback: string,
  ) {
    if (actionRef.current) return false
    const ticket = mutationLifecycle.begin()
    actionRef.current = name
    setAction(name)
    setError(null)
    setNotice(null)
    try {
      await callback(ticket)
      return mutationLifecycle.isCurrent(ticket)
    } catch (caught) {
      if (mutationLifecycle.isCurrent(ticket)) setError(messageFor(caught, fallback))
      return false
    } finally {
      if (mutationLifecycle.isCurrent(ticket) && actionRef.current === name) {
        actionRef.current = null
        setAction(null)
      }
      mutationLifecycle.finish(ticket)
    }
  }

  return <section className="coach-url-intake" aria-labelledby="coach-url-intake-title">
    <div className="coach-source-create-heading">
      <div><h4 id="coach-url-intake-title">Add a secure web source</h4><p>The server visits the address once and stores a private, fixed snapshot. Mia never browses the live site or sees the address.</p></div>
      <span className="coach-source-private-label">Private snapshot</span>
    </div>

    {canCreate && available ? <form className="coach-url-intake-form" onSubmit={(event) => void submit(event)}>
      <label htmlFor="coach-source-url"><span>HTTPS address</span><input id="coach-source-url" name="source-url" type="url" inputMode="url" autoCapitalize="none" autoCorrect="off" spellCheck={false} placeholder="https://example.com/guide" value={url} onChange={(event) => changeUrl(event.target.value)} aria-describedby="coach-source-url-help" disabled={disabled || busy || loading} /></label>
      <Button type="submit" disabled={!url.trim() || disabled || busy || loading}>{action === 'create' ? 'Queuing securely…' : 'Import private snapshot'}</Button>
      <p id="coach-source-url-help">HTTPS only. Redirects and public network addresses are checked by the server. PDF, DOCX, plain text, and readable web pages use the same private review and approval path as file uploads.</p>
    </form> : canCreate ? <div className="coach-source-unavailable" role="status"><strong>Secure web import is unavailable.</strong><span>Upload the source as a file, or try again after secure intake is configured.</span></div> : <p className="coach-content-note">Editors can add secure web snapshots. Reviewers can inspect candidates after the snapshot is processed.</p>}

    {error && <div ref={errorRef} className="coach-source-alert is-error" role="alert" tabIndex={-1}><span>{error}</span>{(loadFailed || pollFailed) && <button type="button" onClick={() => void loadIntakes()}>Refresh secure imports</button>}</div>}
    {notice && <div ref={noticeRef} className="coach-source-alert is-success" role="status" tabIndex={-1}>{notice}</div>}

    {(loading || intakes.length > 0) && <div className="coach-url-intake-requests" aria-label="Secure web source requests">
      <header><h5>Recent secure imports</h5><small>Addresses stay hidden after submission</small></header>
      {loading && intakes.length === 0 && <p role="status">Loading secure imports…</p>}
      {intakes.filter((intake) => intake.status !== 'deleted').map((intake) => {
        const canRedact = intake.redaction_allowed === true || (
          canCreate && intake.redaction_allowed === undefined && (intake.status === 'failed' || intake.status === 'cleanup_failed')
        )
        return <article className="coach-url-intake-request" key={intake.id}>
          <div className="coach-url-intake-summary">
            <div><strong>Secure web snapshot</strong><small>Started {formatDate(intake.created_at)} · address hidden</small></div>
            <span className={`coach-source-status is-${intake.status}`}>{intakeStatusLabel(intake)}</span>
          </div>
          {intake.error && <p className="coach-source-intake-error">{intake.error}</p>}
          {intake.status === 'registered' && <p>Snapshot saved. Open its private source record to review candidates or re-read this same snapshot.</p>}
          {intake.redaction_pending && <p>The address is already redacted. Private object cleanup is still running.</p>}
          <div className="coach-url-intake-actions">
            {intake.status === 'registered' && intake.source_id && <Button size="compact" variant="secondary" disabled={disabled || busy} onClick={() => onSourceReady(intake.source_id!)}>Open source</Button>}
            {canCreate && intake.status === 'failed' && <Button size="compact" variant="secondary" disabled={disabled || busy} onClick={() => void retry(intake)}>Retry secure import</Button>}
            {intake.cleanup_retryable && <Button size="compact" variant="secondary" disabled={disabled || busy} onClick={() => void retryCleanup(intake)}>Retry private cleanup</Button>}
            {canRedact && confirmRedactionId !== intake.id && <Button size="compact" variant="ghost" disabled={disabled || busy} onClick={() => setConfirmRedactionId(intake.id)}>Remove saved address</Button>}
          </div>
          {confirmRedactionId === intake.id && <div className="coach-source-confirm" role="alert"><p>Remove the encrypted address and any unfinished private snapshot? Minimal audit metadata remains.</p><div><Button size="compact" variant="danger" disabled={disabled || busy} onClick={() => void redact(intake)}>Remove address</Button><Button size="compact" variant="ghost" disabled={disabled || busy} onClick={() => setConfirmRedactionId(null)}>Keep it</Button></div></div>}
        </article>
      })}
    </div>}
  </section>
}

function mergeIntakes(current: AdminContentSourceUrlIntake[], updates: AdminContentSourceUrlIntake[]) {
  const byId = new Map(current.map((intake) => [intake.id, intake]))
  for (const intake of updates) byId.set(intake.id, intake)
  return Array.from(byId.values()).sort((left, right) => right.id - left.id)
}

function isHttpsUrl(value: string) {
  try {
    const parsed = new URL(value)
    return parsed.protocol === 'https:' && Boolean(parsed.hostname)
  } catch {
    return false
  }
}

function intakeStatusLabel(intake: AdminContentSourceUrlIntake) {
  if (intake.redaction_pending) return 'Address removed · cleaning up'
  return ({
    queued: 'Queued securely',
    fetching: 'Fetching privately',
    staged: 'Snapshot staged',
    registering: 'Saving snapshot',
    registered: 'Ready for source review',
    failed: 'Needs attention',
    cleanup_pending: 'Cleaning private snapshot',
    cleanup_failed: 'Cleanup needs retry',
    deleted: 'Address removed',
  } as const)[intake.status]
}

function formatDate(value: string) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return 'recently'
  return new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(date)
}

function messageFor(caught: unknown, fallback: string) {
  if (caught instanceof ApiRequestError || caught instanceof Error) return caught.message || fallback
  return fallback
}
