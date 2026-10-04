import type { DebtAction, DebtScope } from './optionalDebt'
import { retainRequestIdentity } from './durableRequestIdentity'
export type DebtRequestIdentity = { scope: DebtScope; action: DebtAction; key: string; draftId?: number; cardId?: number }
export const debtRecoveryKey = 'optional-debt-request-identity-v1'
const scopeKeys = ['user_id', 'household_id', 'cohort_id', 'enrollment_id'] as const
const scopeKey = (scope: DebtScope) => scopeKeys.map(key => scope[key]).join(':')
function clean(value: unknown): DebtRequestIdentity | null {
  if (!value || typeof value !== 'object') return null
  const row = value as DebtRequestIdentity
  if (!row.scope || scopeKeys.some(key => !Number.isSafeInteger(row.scope[key]) || row.scope[key] < 1) || typeof row.key !== 'string' || !row.key || row.key.length > 200 || !['stage', 'approve'].includes(row.action) || row.action === 'approve' && (!Number.isSafeInteger(row.draftId) || row.draftId! < 1) || row.cardId !== undefined && (!Number.isSafeInteger(row.cardId) || row.cardId < 1)) return null
  return { scope: { user_id: row.scope.user_id, household_id: row.scope.household_id, cohort_id: row.scope.cohort_id, enrollment_id: row.scope.enrollment_id }, action: row.action, key: row.key, ...(row.action === 'approve' ? { draftId: row.draftId } : row.cardId ? { cardId: row.cardId } : {}) }
}
function identities(): Record<string, DebtRequestIdentity> {
  const value: unknown = JSON.parse(sessionStorage.getItem(debtRecoveryKey) ?? '{}')
  const legacy = clean(value)
  if (legacy) return { [scopeKey(legacy.scope)]: legacy }
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {}
  const records: Record<string, DebtRequestIdentity> = {}
  for (const [key, raw] of Object.entries(value)) {
    const record = clean(raw)
    if (record && scopeKey(record.scope) === key) records[key] = record
  }
  return records
}
export function readDebtIdentity(scope: DebtScope): DebtRequestIdentity | null {
  try { return identities()[scopeKey(scope)] ?? null } catch { return null }
}
export function saveDebtIdentity(value: DebtRequestIdentity): boolean {
  try {
    const record = clean(value)
    if (!record) return false
    const records = identities(), key = scopeKey(record.scope)
    if (records[key] && records[key].key !== record.key) return false
    records[key] = record
    return retainRequestIdentity(debtRecoveryKey, JSON.stringify(records))
  } catch { return false }
}
export function clearDebtIdentity(identity: DebtRequestIdentity) {
  try {
    const records = identities(), key = scopeKey(identity.scope)
    if (records[key]?.key !== identity.key) return
    delete records[key]
    if (Object.keys(records).length) retainRequestIdentity(debtRecoveryKey, JSON.stringify(records))
    else sessionStorage.removeItem(debtRecoveryKey)
  } catch { /* Keep the original identity for a later status check. */ }
}
