import { useEffect, useRef, useState } from 'react'
import { ApiRequestError } from '../api'
import { assertDebtScope, checkedDebtRecord, debtScopeMatches, type DebtAction, type DebtInput, type DebtMutation, type DebtScope, type OptionalDebtApi } from './optionalDebt'
import { clearDebtIdentity, readDebtIdentity, saveDebtIdentity, type DebtRequestIdentity } from './optionalDebtRecovery'
type Pending = DebtRequestIdentity & { input?: DebtInput; working: boolean; unknown?: boolean; fresh?: boolean; recovery?: boolean; error?: string }
export function useOptionalDebtMutation(scope: DebtScope | undefined, api: OptionalDebtApi, onDone: (result: DebtMutation) => void, onDenied: () => void, onConflict: () => void) {
  const [pending, setPending] = useState<Pending | null>(null), [error, setError] = useState<string | null>(null)
  const current = useRef<Pending | null>(null), active = useRef<string | null>(null), epoch = useRef(0), controllers = useRef(new Set<AbortController>())
  const scopeKey = scope ? `${scope.user_id}:${scope.household_id}:${scope.cohort_id}:${scope.enrollment_id}` : null
  const save = (value: Pending | null) => { current.current = value; setPending(value); if (value) saveDebtIdentity(value) }
  useEffect(() => {
    active.current = scopeKey; epoch.current++
    const identity = scope ? readDebtIdentity(scope) : null
    current.current = identity ? { ...identity, working: false, error: 'An earlier card review needs its result checked.' } : null
    queueMicrotask(() => { setPending(current.current); setError(null) })
    const owned = controllers.current
    return () => { active.current = null; owned.forEach(controller => controller.abort()); owned.clear(); current.current = null }
  }, [scopeKey, scope])
  useEffect(() => {
    if (!pending) return
    const prevent = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
    window.addEventListener('beforeunload', prevent)
    return () => window.removeEventListener('beforeunload', prevent)
  }, [pending])
  async function run(request: Pending, checking = false) {
    if (!scope || active.current !== scopeKey || current.current?.working) return
    if (!checking && !saveDebtIdentity(request)) { setError('This browser cannot retain the request identity. No card change was submitted. Allow session storage before trying again.'); return }
    const generation = epoch.current, controller = new AbortController(); controllers.current.add(controller)
    save({ ...request, working: true, unknown: false }); setError(null)
    try {
      const result = checking ? await api.status(scope, request.action, request.key, controller.signal) : await api.mutate(scope, request.action, request.input!, request.key, controller.signal)
      if (active.current !== scopeKey || generation !== epoch.current) return
      if ('state' in result && result.state === 'in_flight') {
        if (!debtScopeMatches(result, scope, true)) throw new ApiRequestError('Private request identity changed. Reopen card review.', { status: 403 })
        save({ ...request, working: false, unknown: false, error: 'Your earlier request is still processing. Check again.' }); return
      }
      assertDebtScope(result, scope)
      if ('state' in result && result.state === 'unknown') {
        if (result.can_retry !== true) throw new Error('The earlier request could not be confirmed. Check status again.')
        save({ ...request, working: false, unknown: true, error: request.input ? 'No committed result found. You may retry the exact request with its original key.' : 'No committed result found. Re-review this same action using its retained request key.' }); return
      }
      if (!('record' in result) || result.record.savings_enrollment_id !== scope.enrollment_id || request.action === 'approve' && 'base_version_id' in result.record || request.action === 'stage' && !('base_version_id' in result.record)) throw new ApiRequestError('The private review result does not match this action.', { status: 403 })
      checkedDebtRecord(result.record, scope)
      clearDebtIdentity(request); save(null); onDone(result)
    } catch (failure) {
      if (active.current !== scopeKey || generation !== epoch.current) return
      const detail = failure instanceof Error ? failure.message : 'The server did not confirm the card review.'
      if (failure instanceof ApiRequestError && failure.status === 409) onConflict()
      if (failure instanceof ApiRequestError && [401, 403, 404].includes(failure.status)) { save({ ...request, input: undefined, working: false, error: detail }); onDenied() }
      else if (!checking && !request.recovery && failure instanceof ApiRequestError && failure.status >= 400 && failure.status < 500) { clearDebtIdentity(request); save(null); setError(detail) }
      else save({ ...request, input: failure instanceof ApiRequestError && failure.status === 409 ? undefined : request.input, working: false, unknown: false, fresh: false, error: detail })
    } finally { controllers.current.delete(controller) }
  }
  return {
    pending, error,
    submit: (action: DebtAction, input: DebtInput) => {
      if (!scope) return Promise.resolve()
      const old = current.current
      if (old) { if (!old.fresh || old.action !== action || action === 'approve' && (!('draft_id' in input) || old.draftId !== input.draft_id) || action === 'stage' && (!('terms' in input) || (old.cardId ?? null) !== (input.card_id ?? null))) return Promise.resolve(); return run({ ...old, input, working: false, fresh: false, recovery: true }) }
      return run({ scope, action, input, key: crypto.randomUUID(), ...('draft_id' in input ? { draftId: input.draft_id } : input.card_id ? { cardId: input.card_id } : {}), working: false })
    },
    check: pending && !pending.working ? () => run(pending, true) : null,
    retry: pending?.unknown && pending.input && !pending.working ? () => run(pending) : null,
    reviewFresh: pending?.unknown && !pending.input && !pending.working ? () => save({ ...pending, fresh: true, unknown: false, error: 'Re-review this same action. Its original request key stays in use.' }) : null,
  }
}
