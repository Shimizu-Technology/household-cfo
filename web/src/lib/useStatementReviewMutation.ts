import { requestStorageError } from './durableRequestIdentity'
import { useEffect, useRef, useState } from 'react'
import { ApiRequestError, fetchStatementReviewRequestStatus, mutateStatementReview } from '../api'
import type { SourceReviewAction, StatementReviewActorScope } from './participantSourceReview'
import { bindStatementReviewActor, clearStatementReviewRecovery, isStatementReviewActor, readStatementReviewRecovery, saveStatementReviewRecovery, subscribeStatementReviewRecovery } from './statementReviewRecovery'
type Mutation = (action: SourceReviewAction, input: object) => Promise<boolean>
type Props = { importId: number; revisionId: number; scope?: StatementReviewActorScope; refresh: () => void }
export function useStatementReviewMutation({ importId, revisionId, scope, refresh }: Props) {
  const [, update] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [accessDenied, setAccessDenied] = useState(false)
  const live = useRef(true)
  useEffect(() => { live.current = true; return () => { live.current = false } }, [])
  useEffect(() => subscribeStatementReviewRecovery(() => update((value) => value + 1)), [])
  useEffect(() => { if (scope) bindStatementReviewActor(scope) }, [scope])
  const recovery = readStatementReviewRecovery(scope)
  useEffect(() => {
    if (!recovery) return
    const prevent = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
    window.addEventListener('beforeunload', prevent)
    return () => window.removeEventListener('beforeunload', prevent)
  }, [recovery])
  async function perform(action: SourceReviewAction, input: object, key: string = crypto.randomUUID(), targetImport = importId, targetRevision = revisionId): Promise<boolean> {
    if (!scope || !isStatementReviewActor(scope)) return false
    const existing = readStatementReviewRecovery(scope)
    if (existing && (existing.working || existing.key !== key)) return false
    if (!saveStatementReviewRecovery({ scope, importId: targetImport, revisionId: targetRevision, action, input, key, working: false, error: null })) { if (live.current) setError(requestStorageError); return false }
    saveStatementReviewRecovery({ scope, importId: targetImport, revisionId: targetRevision, action, input, key, working: true, error: null })
    setError(null)
    try {
      await mutateStatementReview(targetImport, targetRevision, action, input, key)
      if (!isStatementReviewActor(scope)) return false
      clearStatementReviewRecovery(key)
      if (live.current) refresh()
      return true
    } catch (failure) {
      if (!isStatementReviewActor(scope)) return false
      const message = failure instanceof Error ? failure.message : 'Could not save the statement review.'
      const deterministic = failure instanceof ApiRequestError && [400,401,403,404,409,422].includes(failure.status)
      if (deterministic) clearStatementReviewRecovery(key)
      else saveStatementReviewRecovery({ scope, importId: targetImport, revisionId: targetRevision, action, input, key, working: false, error: message })
      if (live.current) { setError(message); if (failure instanceof ApiRequestError && [401,403,404].includes(failure.status)) setAccessDenied(true) }
      return false
    }
  }
  async function checkStatus() {
    if (!scope || !recovery || recovery.working || !isStatementReviewActor(scope)) return
    saveStatementReviewRecovery({ ...recovery, working: true })
    try {
      const status = await fetchStatementReviewRequestStatus(recovery.importId, recovery.action, recovery.key)
      if (!isStatementReviewActor(scope)) return
      if (status.state === 'committed') { clearStatementReviewRecovery(recovery.key); if (live.current) { setError(null); refresh() } }
      else saveStatementReviewRecovery({ ...recovery, working: false, error: status.state === 'in_flight' ? 'The earlier request is still processing. Check its result again.' : recovery.input ? 'No committed result found. Retry the exact saved request.' : 'The result remains unknown. This page no longer holds the original request. Further changes are blocked; keep this request identifier for support.' })
    } catch (failure) {
      if (!isStatementReviewActor(scope)) return
      if (failure instanceof ApiRequestError && [401,403,404].includes(failure.status)) { clearStatementReviewRecovery(recovery.key); if (live.current) setAccessDenied(true) }
      else saveStatementReviewRecovery({ ...recovery, working: false, error: failure instanceof Error ? failure.message : 'Could not check the earlier request.' })
    }
  }
  return { accessDenied, busy: Boolean(recovery), error: recovery?.error ?? error, pendingRequest: recovery,
    mutate: ((action, input) => perform(action, input)) as Mutation,
    checkStatus: recovery ? checkStatus : null,
    retry: recovery?.input && !recovery.working ? () => perform(recovery.action, recovery.input!, recovery.key, recovery.importId, recovery.revisionId) : null }
}
