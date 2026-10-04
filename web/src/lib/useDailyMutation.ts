import { requestStorageError } from './durableRequestIdentity'
import { useEffect, useRef, useState } from 'react'
import { ApiRequestError, eraseDailyReflection, fetchDailyEraseStatus, fetchDailyRequestStatus, mutateDaily } from '../api'
import { dailyResponseMatches } from './dailyChallenge'
import type { DailyAction, DailyInput, DailyScope } from './dailyChallenge'
import { bindDailyActor, clearDailyRecovery, isDailyActor, readDailyRecovery, saveDailyRecovery, subscribeDailyRecovery } from './dailyRecovery'
export type DailyMutate = (action: DailyAction, input: DailyInput, reflectionId?: number) => Promise<unknown | null>
export function useDailyMutation(scope: DailyScope | undefined, refresh: () => void) {
  const [, update] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [denied, setDenied] = useState(false)
  const live = useRef(true)
  useEffect(() => { live.current = true; return () => { live.current = false } }, [])
  useEffect(() => subscribeDailyRecovery(() => update(value => value + 1)), [])
  useEffect(() => { if (scope) bindDailyActor(scope) }, [scope])
  const pending = readDailyRecovery(scope)
  useEffect(() => {
    if (!pending) return
    const prevent = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
    window.addEventListener('beforeunload', prevent)
    return () => window.removeEventListener('beforeunload', prevent)
  }, [pending])
  async function perform<T>(action: DailyAction, input: DailyInput, reflectionId?: number, key: string = crypto.randomUUID()): Promise<T | null> {
    if (!scope || !isDailyActor(scope)) return null
    const old = readDailyRecovery(scope)
    if (old && (old.working || old.key !== key)) return null
    const request = { scope, action, input, reflectionId, key, working: true, error: null }
    if (!saveDailyRecovery({ ...request, working: false })) { if (live.current) setError(requestStorageError); return null }
    saveDailyRecovery(request)
    setError(null)
    try {
      const result = action === 'reflection_erase'
        ? await eraseDailyReflection(reflectionId!, input, key)
        : await mutateDaily<T>(action, input, key)
      if (action !== 'reflection_erase' && (!('actor_scope' in result) || !dailyResponseMatches(result, scope))) {
        if (live.current) setDenied(true)
        throw new Error('Private workspace changed. Check this request in its original workspace.')
      }
      if (action === 'reflection_erase' && (!('erased' in result) || !result.erased || result.reflection_id !== reflectionId)) throw new Error('The erasure result could not be confirmed. Check the same request.')
      if (!isDailyActor(scope)) return null
      clearDailyRecovery(key)
      if (live.current) refresh()
      return ('record' in result ? result.record : result) as T
    } catch (failure) {
      if (!isDailyActor(scope)) return null
      const message = failure instanceof Error ? failure.message : 'Could not save this daily review.'
      if (failure instanceof ApiRequestError && [400,401,403,404,409,422].includes(failure.status)) clearDailyRecovery(key)
      else saveDailyRecovery({ ...request, working: false, error: message })
      if (live.current) {
        setError(message)
        if (failure instanceof ApiRequestError && [401,403,404].includes(failure.status)) setDenied(true)
      }
      return null
    }
  }
  async function checkStatus() {
    if (!scope || !pending || pending.working || !isDailyActor(scope)) return
    saveDailyRecovery({ ...pending, working: true })
    try {
      const response = pending.action === 'reflection_erase'
        ? { kind: 'erase' as const, status: await fetchDailyEraseStatus(pending.reflectionId!, pending.key) }
        : { kind: 'ordinary' as const, status: await fetchDailyRequestStatus(pending.action, pending.key) }
      const status = response.status
      if (!isDailyActor(scope)) return
      if (response.kind === 'ordinary') {
        const ordinaryStatus = response.status
        const unresolvedMetadata = ordinaryStatus.state === 'in_flight' && ordinaryStatus.enrollment_id === null && (ordinaryStatus.cohort_id === null || ordinaryStatus.cohort_id === scope.cohort_id) && ordinaryStatus.actor_scope.user_id === scope.user_id && ordinaryStatus.actor_scope.household_id === scope.household_id
        if (!unresolvedMetadata && !dailyResponseMatches(ordinaryStatus, scope)) { if (live.current) setDenied(true); throw new Error('Private workspace changed. Reopen Today in the original workspace.') }
      }
      if (status.state === 'committed' && pending.action === 'reflection_erase' && (!('erased' in status) || !status.erased || status.reflection_id !== pending.reflectionId)) throw new Error('The erasure result could not be confirmed.')
      if (status.state === 'committed') { clearDailyRecovery(pending.key); if (live.current) { setError(null); refresh() } }
      else saveDailyRecovery({ ...pending, working: false, error: status.state === 'in_flight' ? 'This request is still processing. Check again.' : pending.input ? 'No committed result found. Retry the same saved request.' : 'The result is unknown and this page no longer holds its original inputs. Further changes remain blocked; keep the request identifier for support.' })
    } catch (failure) {
      if (!isDailyActor(scope)) return
      if (failure instanceof ApiRequestError && [401,403,404].includes(failure.status)) { clearDailyRecovery(pending.key); if (live.current) setDenied(true) }
      else saveDailyRecovery({ ...pending, working: false, error: failure instanceof Error ? failure.message : 'The request result is unavailable.' })
    }
  }
  return { denied, busy: Boolean(pending), error: pending?.error ?? error, pending, mutate: perform as DailyMutate,
    checkStatus: pending ? checkStatus : null,
    retry: pending?.input && !pending.working ? () => perform(pending.action, pending.input!, pending.reflectionId, pending.key) : null }
}
