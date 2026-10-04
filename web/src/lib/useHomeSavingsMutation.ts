import { useEffect, useRef, useState } from 'react'
import { ApiRequestError, fetchHomeSavingsRequestStatus } from '../api'
import { clearHomeSavingsIdentity, homeChallengeMatches, homeScopeKey, homeStatusMatches, readHomeSavingsIdentity, saveHomeSavingsIdentity, type HomeSavingsAttempt, type HomeSavingsIdentity, type HomeSavingsScope, type HomeSavingsStatus, type HomeSavingsAction } from './homeSavingsRecovery'
import type { SavingsMutation } from './savingsChallenge'
type Pending = HomeSavingsIdentity & { attempt?: HomeSavingsAttempt; working: boolean; unknown?: boolean; fresh?: boolean; recovery?: boolean; error?: string }
export function useHomeSavingsMutation(scope: HomeSavingsScope | undefined, onDone: (result: SavingsMutation<unknown>, action: HomeSavingsAction) => void, onDenied: () => void, blocked: () => boolean, onConflict?: (message: string) => void) {
  const [pending, setPending] = useState<Pending | null>(null)
  const [error, setError] = useState<string | null>(null)
  const current = useRef<Pending | null>(null), active = useRef<string | null>(null), generation = useRef(0), controllers = useRef(new Set<AbortController>())
  const callbacks = useRef({ onDone, onDenied, blocked, onConflict }); useEffect(()=>{callbacks.current={onDone,onDenied,blocked,onConflict}},[onDone,onDenied,blocked,onConflict])
  const key = scope ? homeScopeKey(scope) : null
  const save = (request: Pending | null) => { current.current = request; setPending(request) }
  useEffect(() => {
    active.current = key; const epoch = ++generation.current
    const saved = scope ? readHomeSavingsIdentity(scope) : null
    current.current = saved ? { ...saved, working: false, error: 'An earlier savings request needs its result checked.' } : null
    queueMicrotask(() => { if (active.current === key) { setPending(current.current); setError(null) } })
    const owned = controllers.current
    return () => { active.current = null; generation.current=epoch+1; for (const controller of owned) controller.abort(); owned.clear(); current.current = null }
  }, [key, scope])
  useEffect(() => { if (!pending) return; const guard = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }; window.addEventListener('beforeunload', guard); return () => window.removeEventListener('beforeunload', guard) }, [pending])
  async function run(request: Pending, check = false) {
    if (!scope || active.current !== key || current.current?.working || (!check && callbacks.current.blocked())) return
    if (!check && !saveHomeSavingsIdentity(request)) { setError('The request identity could not be retained in this browser. No change was submitted. Enable session storage before trying again.'); return }
    const epoch = generation.current, controller = new AbortController(); controllers.current.add(controller)
    save({ ...request, working: true, unknown: false }); setError(null)
    try {
      const result = check ? await fetchHomeSavingsRequestStatus(request.action, request.key, controller.signal) : await request.attempt!.perform(request.key, controller.signal)
      if (active.current !== key || epoch !== generation.current) return
      if (check) {
        const status = result as HomeSavingsStatus
        if (!homeStatusMatches(status, request)) throw new ApiRequestError('The private challenge scope changed. Reopen Home for the current participant.', { status: 403 })
        if (status.state !== 'committed') { save({ ...request, working: false, fresh: false, unknown: status.state === 'unknown', error: status.state === 'in_flight' ? 'The earlier request is still processing. Check again before making changes.' : request.attempt ? 'No committed result found. Retry the exact request with its original key.' : 'No committed result found. Re-review this same action with its original request key.' }); return }
      } else if (!homeChallengeMatches((result as SavingsMutation<unknown>).challenge, request)) throw new ApiRequestError('The private challenge scope changed. Reopen Home for the current participant.', { status: 403 })
      clearHomeSavingsIdentity(request); save(null); callbacks.current.onDone(result as SavingsMutation<unknown>, request.action); request.attempt?.done?.()
    } catch (failure) {
      if (active.current !== key || epoch !== generation.current) return
      const message = failure instanceof Error ? failure.message : 'This savings request is unavailable.'
      if (failure instanceof ApiRequestError && [401, 403, 404].includes(failure.status)) { save({ ...request, attempt: undefined, working: false, fresh: false, error: message }); callbacks.current.onDenied() }
      else if (failure instanceof ApiRequestError && failure.status >= 400 && failure.status < 500 && !check && !request.recovery) { clearHomeSavingsIdentity(request); save(null); if (failure.status === 409 && callbacks.current.onConflict) { setError(null); callbacks.current.onConflict(message) } else setError(message) }
      else save({ ...request, attempt: request.recovery && failure instanceof ApiRequestError && failure.status === 409 ? undefined : request.attempt, working: false, fresh: false, unknown: false, error: message })
    } finally { controllers.current.delete(controller) }
  }
  return { pending, error, isPending: () => Boolean(current.current), submit: (attempt: HomeSavingsAttempt) => {
    if (!scope) return Promise.resolve()
    const old = current.current
    if (old) { if (!old.fresh || old.action !== attempt.action || old.draftId !== attempt.draftId || old.entryId !== attempt.entryId || old.enrollmentId !== attempt.enrollmentId) return Promise.resolve(); return run({ ...old, attempt, working: false, fresh: false, recovery: true }) }
    return run({ scope, action: attempt.action, key: crypto.randomUUID(), enrollmentId: attempt.enrollmentId, draftId: attempt.draftId, entryId: attempt.entryId, attempt, working: false })
  }, check: pending && !pending.working ? () => run(pending, true) : null, retry: pending?.attempt && !pending.working ? () => run(pending) : null,
  reviewFresh: pending?.unknown && !pending.attempt && !pending.working ? () => save({ ...pending, fresh: true, unknown: false, error: 'Only this same action is available for fresh review. The original request key is retained.' }) : null }
}
