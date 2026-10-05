import { retainRequestIdentity } from './durableRequestIdentity'
import type { BaselineApproval, BaselineScope } from './financialBaseline'
type BaselineAction = 'approve' | 'revise'

export type BaselineRecovery = { scope: BaselineScope; action: BaselineAction; key: string; input?: BaselineApproval; working: boolean; error: string | null }
const storageKey = 'baseline-request-identities-v1'
let actor: BaselineScope | null = null
let expectedUser: number | null = null
let pending: BaselineRecovery | null = null
const listeners = new Set<() => void>()
const changed = () => listeners.forEach((listener) => listener())
const same = (left: BaselineScope | null, right: BaselineScope | null) => Boolean(left && right && left.user_id === right.user_id && left.household_id === right.household_id)

const scopeKey = (scope: BaselineScope) => `${scope.user_id}:${scope.household_id}`
function storedIdentities(): Record<string, BaselineRecovery> {
  const value: unknown = JSON.parse(sessionStorage.getItem(storageKey) ?? '{}')
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, BaselineRecovery> : {}
}
function remember(): boolean {
  try {
    const identities = storedIdentities()
    if (pending) identities[scopeKey(pending.scope)] = { scope: { user_id: pending.scope.user_id, household_id: pending.scope.household_id }, action: pending.action, key: pending.key } as BaselineRecovery
    else if (actor) delete identities[scopeKey(actor)]
    if (Object.keys(identities).length) return retainRequestIdentity(storageKey, JSON.stringify(identities))
    sessionStorage.removeItem(storageKey)
    return sessionStorage.getItem(storageKey) === null
  } catch { return false }
}
export function setBaselineExpectedUser(userId: number | null) {
  if (expectedUser === userId) return
  expectedUser = userId
  if (actor && actor.user_id !== userId) { actor = null; pending = null; changed() }
}
export function bindBaselineActor(scope: BaselineScope): boolean {
  if (scope.user_id !== expectedUser) return false
  if (!same(actor, scope)) {
    actor = scope; pending = null
    try {
      const saved = storedIdentities()[scopeKey(scope)]
      if (saved && same(saved.scope, scope) && typeof saved.key === 'string' && ['approve','revise'].includes(saved.action)) pending = { scope, action: saved.action, key: saved.key, working: false, error: 'An earlier baseline request needs its result checked before further changes.' }
      else remember()
    } catch { remember() }
    changed()
  }
  return true
}
export function readBaselineRecovery(scope?: BaselineScope) { return scope && same(actor, scope) ? pending : null }
export function saveBaselineRecovery(value: BaselineRecovery) {
  if (!same(actor, value.scope)) return false
  const previous = pending
  pending = value
  const retained = remember()
  // An already retained key remains recoverable if a later storage write fails.
  if (!retained && previous?.key !== value.key) pending = previous
  changed()
  return retained
}
export function clearBaselineRecovery(key: string) { if (pending?.key === key) { pending = null; remember(); changed() } }
export function subscribeBaselineRecovery(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener) } }
export function isBaselineActor(scope: BaselineScope) { return same(actor, scope) && expectedUser === scope.user_id }
