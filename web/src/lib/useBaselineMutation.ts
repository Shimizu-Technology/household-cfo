import { requestStorageError } from './durableRequestIdentity'
import { useEffect, useRef, useState } from 'react'
import { ApiRequestError, fetchBaselineRequestStatus, approveFinancialBaseline } from '../api'
import { sameBaselineScope, type BaselineApproval, type BaselineScope } from './financialBaseline'
type BaselineAction = 'approve' | 'revise'
import { bindBaselineActor, clearBaselineRecovery, isBaselineActor, readBaselineRecovery, saveBaselineRecovery, subscribeBaselineRecovery } from './baselineRecovery'
type Mutation = (action: BaselineAction, input: BaselineApproval) => Promise<boolean>
type Props = { scope?: BaselineScope; refresh: () => void }
export function useBaselineMutation({ scope, refresh }: Props) {
  const [, update] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [accessDenied, setAccessDenied] = useState(false)
  const live = useRef(true)
  useEffect(() => { live.current = true; return () => { live.current = false } }, [])
  useEffect(() => subscribeBaselineRecovery(() => update((value) => value + 1)), [])
  useEffect(() => { if (scope) bindBaselineActor(scope) }, [scope])
  const recovery = readBaselineRecovery(scope)
  useEffect(() => {
    if (!recovery) return
    const prevent = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
    window.addEventListener('beforeunload', prevent)
    return () => window.removeEventListener('beforeunload', prevent)
  }, [recovery])
  async function perform(action: BaselineAction, input: BaselineApproval, key: string = crypto.randomUUID()): Promise<boolean> {
    if (!scope || !isBaselineActor(scope)) return false
    const existing = readBaselineRecovery(scope)
    if (existing && (existing.working || existing.key !== key)) return false
    if (!saveBaselineRecovery({ scope, action, input, key, working: false, error: null })) { if (live.current) setError(requestStorageError); return false }
    saveBaselineRecovery({ scope, action, input, key, working: true, error: null })
    setError(null)
    try {
      const result = await approveFinancialBaseline(action, input, key)
      if (!sameBaselineScope(result.actor_scope,scope)) { if (live.current) setAccessDenied(true); throw new Error('Private workspace changed while the baseline request was processing. Check its result in the original workspace.') }
      if (!isBaselineActor(scope)) return false
      clearBaselineRecovery(key)
      if (live.current) refresh()
      return true
    } catch (failure) {
      if (!isBaselineActor(scope)) return false
      const message = failure instanceof Error ? failure.message : 'Could not save the baseline review.'
      const deterministic = failure instanceof ApiRequestError && [400,401,403,404,409,422].includes(failure.status)
      if (deterministic) clearBaselineRecovery(key)
      else saveBaselineRecovery({ scope, action, input, key, working: false, error: message })
      if (live.current) { setError(message); if (failure instanceof ApiRequestError && [401,403,404].includes(failure.status)) setAccessDenied(true) }
      return false
    }
  }
  async function checkStatus() {
    if (!scope || !recovery || recovery.working || !isBaselineActor(scope)) return
    saveBaselineRecovery({ ...recovery, working: true })
    try {
      const status = await fetchBaselineRequestStatus(recovery.action, recovery.key)
      if (!isBaselineActor(scope)) return
      if (!sameBaselineScope(status.actor_scope,scope)) { if (live.current) setAccessDenied(true); throw new Error('Private workspace changed. Reopen baseline review to check the original request.') }
      if (status.state === 'committed') { clearBaselineRecovery(recovery.key); if (live.current) { setError(null); refresh() } }
      else saveBaselineRecovery({ ...recovery, working: false, error: status.state === 'in_flight' ? 'The earlier request is still processing. Check its result again.' : recovery.input ? 'No committed result found. Retry the exact saved request.' : 'The result remains unknown. This page no longer holds the original request. Further changes are blocked; keep this request identifier for support.' })
    } catch (failure) {
      if (!isBaselineActor(scope)) return
      if (failure instanceof ApiRequestError && [401,403,404].includes(failure.status)) { clearBaselineRecovery(recovery.key); if (live.current) setAccessDenied(true) }
      else saveBaselineRecovery({ ...recovery, working: false, error: failure instanceof Error ? failure.message : 'Could not check the earlier request.' })
    }
  }
  return { accessDenied, busy: Boolean(recovery), error: recovery?.error ?? error, pendingRequest: recovery,
    mutate: ((action, input) => perform(action, input)) as Mutation,
    checkStatus: recovery ? checkStatus : null,
    retry: recovery?.input && !recovery.working ? () => perform(recovery.action, recovery.input!, recovery.key) : null }
}
