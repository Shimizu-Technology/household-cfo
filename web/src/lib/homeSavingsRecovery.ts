import type { SavingsChallenge, SavingsMutation } from './savingsChallenge'
export type HomeSavingsAction = 'enrollment' | 'entry_stage' | 'entry_approve' | 'zero_attest'
export type HomeSavingsScope = { user_id: number; household_id: number; cohort_id: number }
export type HomeSavingsIdentity = { scope: HomeSavingsScope; action: HomeSavingsAction; key: string; enrollmentId: number | null; draftId?: number; entryId?: number }
export type HomeSavingsStatus = ({ state: 'committed'; record: unknown; replayed: true; challenge: SavingsChallenge } | { state: 'unknown'; can_retry: true } | { state: 'in_flight' }) & { actor_scope: { user_id: number; household_id: number }; cohort_id: number }
export const homeSavingsStorage = 'savings-home-request-identities-v1'
const validId = (id: unknown): id is number => typeof id === 'number' && Number.isSafeInteger(id) && id > 0
export const homeScopeKey = (scope: HomeSavingsScope) => `${scope.user_id}:${scope.household_id}:${scope.cohort_id}`
function records(): Record<string, unknown> { const saved: unknown = JSON.parse(sessionStorage.getItem(homeSavingsStorage) ?? '{}'); if (!saved || typeof saved !== 'object' || Array.isArray(saved)) throw new Error('Invalid request storage'); return saved as Record<string, unknown> }
function clean(value: unknown): HomeSavingsIdentity | null {
  if (!value || typeof value !== 'object') return null
  const saved = value as HomeSavingsIdentity
  if (!saved.scope || ![saved.scope.user_id, saved.scope.household_id, saved.scope.cohort_id].every(validId) || !['enrollment', 'entry_stage', 'entry_approve', 'zero_attest'].includes(saved.action) || typeof saved.key !== 'string' || !saved.key.trim() || saved.key.length > 200 || !(saved.enrollmentId === null || validId(saved.enrollmentId)) || (saved.action !== 'enrollment' && saved.enrollmentId === null) || (saved.action === 'entry_approve' && !validId(saved.draftId)) || (saved.entryId !== undefined && !validId(saved.entryId))) return null
  return { scope: {user_id:saved.scope.user_id,household_id:saved.scope.household_id,cohort_id:saved.scope.cohort_id}, action: saved.action, key: saved.key, enrollmentId: saved.enrollmentId, ...(saved.action === 'entry_approve' ? { draftId: saved.draftId } : {}), ...(saved.action === 'entry_stage' && saved.entryId !== undefined ? { entryId: saved.entryId } : {}) }
}
export function readHomeSavingsIdentity(scope: HomeSavingsScope): HomeSavingsIdentity | null { try { const saved = clean(records()[homeScopeKey(scope)]); return saved && homeScopeKey(saved.scope) === homeScopeKey(scope) ? saved : null } catch { return null } }
export function saveHomeSavingsIdentity(request: HomeSavingsIdentity): boolean { try { const saved = clean(request); if (!saved) return false; sessionStorage.setItem(homeSavingsStorage, JSON.stringify({ ...records(), [homeScopeKey(request.scope)]: saved })); return true } catch { return false } }
export function clearHomeSavingsIdentity(request: HomeSavingsIdentity) { try { const saved = records(); const old = clean(saved[homeScopeKey(request.scope)]); if (old?.key === request.key) delete saved[homeScopeKey(request.scope)]; if (Object.keys(saved).length) sessionStorage.setItem(homeSavingsStorage, JSON.stringify(saved)); else sessionStorage.removeItem(homeSavingsStorage) } catch { /* Retain a safe recovery lock if the browser cannot remove storage. */ } }
export function homeChallengeMatches(challenge: SavingsChallenge, request: HomeSavingsIdentity): boolean {
  const cohort = (challenge as SavingsChallenge & { cohort_id?: number }).cohort_id ?? challenge.enrollment?.cohort_id
  return cohort === request.scope.cohort_id && (request.action === 'enrollment' || challenge.enrollment?.id === request.enrollmentId)
}
export function homeStatusMatches(result: HomeSavingsStatus, request: HomeSavingsIdentity) { return result.actor_scope?.user_id === request.scope.user_id && result.actor_scope?.household_id === request.scope.household_id && result.cohort_id === request.scope.cohort_id && (result.state !== 'committed' || homeChallengeMatches(result.challenge, request)) }
export type HomeSavingsAttempt = { action: HomeSavingsAction; enrollmentId: number | null; draftId?: number; entryId?: number; perform: (key: string, signal: AbortSignal) => Promise<SavingsMutation<unknown>>; done?: () => void }
