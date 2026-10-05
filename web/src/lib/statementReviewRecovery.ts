import { retainRequestIdentity } from './durableRequestIdentity'
import type { SourceReviewAction, StatementReviewActorScope } from './participantSourceReview'

export type ReviewRecovery = { scope: StatementReviewActorScope; importId: number; revisionId: number; action: SourceReviewAction; key: string; input?: object; working: boolean; error: string | null }
const storageKey = 'statement-review-request-identities-v1'
let actor: StatementReviewActorScope | null = null
let expectedUser: number | null = null
let pending: ReviewRecovery | null = null
const listeners = new Set<() => void>()
const changed = () => listeners.forEach((listener) => listener())
const same = (left: StatementReviewActorScope | null, right: StatementReviewActorScope | null) => Boolean(left && right && left.user_id === right.user_id && left.household_id === right.household_id)

const scopeKey = (scope: StatementReviewActorScope) => `${scope.user_id}:${scope.household_id}`
function storedIdentities(): Record<string, ReviewRecovery> {
  const value: unknown = JSON.parse(sessionStorage.getItem(storageKey) ?? '{}')
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, ReviewRecovery> : {}
}
function remember(): boolean {
  try {
    const identities = storedIdentities()
    if (pending) identities[scopeKey(pending.scope)] = { scope: { user_id: pending.scope.user_id, household_id: pending.scope.household_id }, importId: pending.importId, revisionId: pending.revisionId, action: pending.action, key: pending.key } as ReviewRecovery
    else if (actor) delete identities[scopeKey(actor)]
    if (Object.keys(identities).length) return retainRequestIdentity(storageKey, JSON.stringify(identities))
    sessionStorage.removeItem(storageKey)
    return sessionStorage.getItem(storageKey) === null
  } catch { return false }
}
export function setStatementReviewExpectedUser(userId: number | null) {
  if (expectedUser === userId) return
  expectedUser = userId
  if (actor && actor.user_id !== userId) { actor = null; pending = null; changed() }
}
export function bindStatementReviewActor(scope: StatementReviewActorScope): boolean {
  if (scope.user_id !== expectedUser) return false
  if (!same(actor, scope)) {
    actor = scope; pending = null
    try {
      const saved = storedIdentities()[scopeKey(scope)]
      if (saved && same(saved.scope, scope) && Number.isSafeInteger(saved.importId) && Number.isSafeInteger(saved.revisionId) && typeof saved.key === 'string' && ['account_link','stage','approve','cancel','coverage','economic_link','project'].includes(saved.action)) pending = { scope, importId: saved.importId, revisionId: saved.revisionId, action: saved.action, key: saved.key, working: false, error: 'An earlier statement request needs its result checked before further changes.' }
      else remember()
    } catch { remember() }
    changed()
  }
  return true
}
export function readStatementReviewRecovery(scope?: StatementReviewActorScope) { return scope && same(actor, scope) ? pending : null }
export function saveStatementReviewRecovery(value: ReviewRecovery) {
  if (!same(actor, value.scope)) return false
  const previous = pending
  pending = value
  const retained = remember()
  // An already retained key remains recoverable if a later storage write fails.
  if (!retained && previous?.key !== value.key) pending = previous
  changed()
  return retained
}
export function clearStatementReviewRecovery(key: string) { if (pending?.key === key) { pending = null; remember(); changed() } }
export function subscribeStatementReviewRecovery(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener) } }
export function isStatementReviewActor(scope: StatementReviewActorScope) { return same(actor, scope) && expectedUser === scope.user_id }
