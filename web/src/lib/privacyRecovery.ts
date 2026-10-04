import type { PrivateAction, PrivacyScope, RequestIdentity } from './challengePrivacy'
import { retainRequestIdentity } from './durableRequestIdentity'

const storageKey = 'challenge-private-request-identity-v1'
const actions: PrivateAction[] = ['consent', 'support_request', 'support_grant', 'support_revoke', 'source_authorize', 'source_revoke', 'preference', 'dismiss', 'erase']
const scopeKey = (scope: PrivacyScope) => `${scope.user_id}:${scope.household_id}`
function clean(value: unknown): RequestIdentity | null {
  if (!value || typeof value !== 'object') return null
  const row = value as RequestIdentity
  if (!row.scope || !Number.isSafeInteger(row.scope.user_id) || row.scope.user_id < 1 || !Number.isSafeInteger(row.scope.household_id) || row.scope.household_id < 1 || !Number.isSafeInteger(row.enrollmentId) || row.enrollmentId <= 0 || typeof row.key !== 'string' || !row.key || row.key.length > 200 || !actions.includes(row.action) || (row.action === 'erase' && (!Number.isSafeInteger(row.reflectionId) || row.reflectionId! <= 0))) return null
  return { scope: { user_id: row.scope.user_id, household_id: row.scope.household_id }, enrollmentId: row.enrollmentId, key: row.key, action: row.action, ...(row.action === 'erase' ? { reflectionId: row.reflectionId } : {}) }
}
function identities(): Record<string, RequestIdentity> {
  const value: unknown = JSON.parse(sessionStorage.getItem(storageKey) ?? '{}')
  const legacy = clean(value)
  if (legacy) return { [scopeKey(legacy.scope)]: legacy }
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {}
  const records: Record<string, RequestIdentity> = {}
  for (const [key, raw] of Object.entries(value)) { const record = clean(raw); if (record && scopeKey(record.scope) === key) records[key] = record }
  return records
}
export function readPrivacyRecovery(scope: PrivacyScope): RequestIdentity | null {
  try { return identities()[scopeKey(scope)] ?? null } catch { return null }
}
export function savePrivacyRecovery(identity: RequestIdentity): boolean {
  // One unresolved action blocks this actor's household controls across programs.
  // Never persist financial values, support text, source IDs or selected records.
  try {
    const record = clean(identity)
    if (!record) return false
    const records = identities(), key = scopeKey(record.scope)
    if (records[key] && records[key].key !== record.key) return false
    records[key] = record
    return retainRequestIdentity(storageKey, JSON.stringify(records))
  } catch { return false }
}
export function clearPrivacyRecovery(identity: RequestIdentity) {
  try {
    const records = identities(), key = scopeKey(identity.scope)
    if (records[key]?.key !== identity.key) return
    delete records[key]
    if (Object.keys(records).length) retainRequestIdentity(storageKey, JSON.stringify(records))
    else sessionStorage.removeItem(storageKey)
  } catch { /* Retain the identity for a later status check. */ }
}
