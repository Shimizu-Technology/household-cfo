import { retainRequestIdentity } from './durableRequestIdentity'
import { dailyScopeMatches, type DailyScope, type DailyAction, type DailyInput } from './dailyChallenge'

export type DailyRecovery = { scope: DailyScope; action: DailyAction; key: string; input?: DailyInput; reflectionId?: number; working: boolean; error: string | null }
const storageKey = 'daily-request-identities-v1'
let actor: DailyScope | null = null
let expectedUser: number | null = null
let pending: DailyRecovery | null = null
const listeners = new Set<() => void>()
const changed = () => listeners.forEach((listener) => listener())
const same = dailyScopeMatches

const scopeKey = (scope: DailyScope) => `${scope.user_id}:${scope.household_id}:${scope.enrollment_id}`
function storedIdentities(): Record<string, DailyRecovery> {
  const value: unknown = JSON.parse(sessionStorage.getItem(storageKey) ?? '{}')
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, DailyRecovery> : {}
}
function remember(): boolean {
  try {
    const identities = storedIdentities()
    if (pending) identities[scopeKey(pending.scope)] = { scope: { user_id: pending.scope.user_id, household_id: pending.scope.household_id, enrollment_id: pending.scope.enrollment_id, ...(pending.scope.cohort_id === undefined ? {} : { cohort_id: pending.scope.cohort_id }) }, action: pending.action, key: pending.key, reflectionId: pending.reflectionId } as DailyRecovery
    else if (actor) delete identities[scopeKey(actor)]
    if (Object.keys(identities).length) return retainRequestIdentity(storageKey, JSON.stringify(identities))
    sessionStorage.removeItem(storageKey)
    return sessionStorage.getItem(storageKey) === null
  } catch { return false }
}
export function setDailyExpectedUser(userId: number | null) {
  if (expectedUser === userId) return
  expectedUser = userId
  if (actor && actor.user_id !== userId) { actor = null; pending = null; changed() }
}
export function bindDailyActor(scope: DailyScope): boolean {
  if (scope.user_id !== expectedUser) return false
  if (!same(actor, scope)) {
    actor = scope; pending = null
    try {
      const saved = storedIdentities()[scopeKey(scope)]
      if (saved && same(saved.scope, scope) && typeof saved.key === 'string' && ['purchase_stage','purchase_approve','reflection_save','check_in_save','checkpoint_stage','checkpoint_approve','category_create','reflection_erase'].includes(saved.action)) pending = { scope, action: saved.action, key: saved.key, reflectionId: saved.reflectionId, working: false, error: 'An earlier daily request needs its result checked before further changes.' }
      else remember()
    } catch { remember() }
    changed()
  }
  return true
}
export function readDailyRecovery(scope?: DailyScope) { return scope && same(actor, scope) ? pending : null }
export function saveDailyRecovery(value: DailyRecovery) {
  if (!same(actor, value.scope)) return false
  const previous = pending
  pending = value
  const retained = remember()
  // An already retained key remains recoverable if a later storage write fails.
  if (!retained && previous?.key !== value.key) pending = previous
  changed()
  return retained
}
export function clearDailyRecovery(key: string) { if (pending?.key === key) { pending = null; remember(); changed() } }
export function subscribeDailyRecovery(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener) } }
export function isDailyActor(scope: DailyScope) { return same(actor, scope) && expectedUser === scope.user_id }
