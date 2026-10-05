import { ApiRequestError } from '../api'
import type { BaselineScope } from './financialBaseline'
import { savingsInputCents, savingsInputDollars } from './savingsChallenge'

export type DebtScope = BaselineScope & { cohort_id: number; enrollment_id: number }
export type DebtAction = 'stage' | 'approve'
export type DebtRate = { label: string; balance_cents: number | null; apr_bps: number | null; promotional_expires_on: string | null; post_promo_apr_bps: number | null }
export type DebtTerms = { label: string; as_of_on: string; balance_cents: number | null; minimum_payment_cents: number | null; apr_bps: number | null; due_on: string | null; promotional_apr_bps: number | null; promotional_expires_on: string | null; post_promo_apr_bps: number | null; rate_segments: DebtRate[]; status: 'active' | 'paid_off' | 'archived' }
export type DebtMapping = { source_tracked_account_id: number; source_account_identity_version_id: number; source_revision_approval_id: number; fingerprint: string }
export type HouseholdDebtMapping = { household_debt_id: number; fingerprint: string }
export type HouseholdDebtCandidate = HouseholdDebtMapping & { label: string; snapshot: Record<string, unknown>; proposed_terms: { balance_cents: number | null; minimum_payment_cents: number | null; apr_bps: number | null }; linked_card_id: number | null; qualifications: string[] }
export type HouseholdDebtSource = { household_debt_id: number | null; household_debt_fingerprint: string | null; household_debt_snapshot: Record<string, unknown> }
export type DebtSource = HouseholdDebtSource & { source_tracked_account_id: number | null; source_account_identity_version_id: number | null; source_revision_approval_id: number | null; source_fingerprint: string | null; source_snapshot: Record<string, unknown> }
export type DebtVersion = DebtSource & { id: number; savings_debt_card_id: number; savings_enrollment_id: number; previous_version_id: number | null; version_number: number; terms: DebtTerms; reason: string; digest: string; approved_at: string }
export type DebtDraft = DebtSource & { id: number; savings_debt_card_id: number; savings_enrollment_id: number; terms: DebtTerms; base_version_id: number | null; base_head_lock_version: number; lock_version: number; status: 'pending' | 'approved'; approved_version_id: number | null; reason: string }
export type DebtCard = { id: number; savings_enrollment_id: number; lock_version: number; current_version_id: number | null; household_debt_id: number | null; source_tracked_account_id: number | null; current_version: DebtVersion | null }
export type DebtCandidate = DebtMapping & { label: string; statement_as_of_on: string; snapshot: Record<string, unknown>; proposed_terms: { balance_cents: number | null; as_of_on: string; minimum_payment_cents: null; apr_bps: null }; qualifications: string[] }
export type DebtEnvelope = { actor_scope: BaselineScope; cohort_id: number; enrollment_id: number }
export type DebtPage<T> = DebtEnvelope & { records: T[]; next_cursor: number | null }
export type DebtSummary = DebtEnvelope & { local_today: string; cards: { card_id: number; version_id: number; label: string; terms: DebtTerms; source_stale: boolean; household_debt_id: number | null; household_terms_changed: boolean; qualifications: string[]; promotional_expired: boolean | null; snowball_eligible: boolean; avalanche_eligible: boolean }[]; portfolio_complete: false; known_balance_subtotal_cents: number | null; unknown_balance_count: number; stale_card_count: number; snowball_order: number[]; avalanche_order: number[]; extra_payment_cents: null; payoff_date: null; savings_credit_cents: null; qualifications: string[] }
export type DebtInput = { terms: DebtTerms; card_id?: number; expected_version_id: number | null; expected_head_lock_version: number; source_mapping: DebtMapping | null; household_debt_mapping?: HouseholdDebtMapping | null; reason: string } | { draft_id: number; accepted: true; expected_draft_lock_version: number; expected_version_id: number | null; expected_head_lock_version: number }
export type DebtMutation = DebtEnvelope & { record: DebtDraft | DebtVersion; replayed: boolean }
export type DebtStatus = (DebtEnvelope & { state: 'committed'; record: DebtDraft | DebtVersion; replayed: true }) | (DebtEnvelope & { state: 'unknown'; can_retry: true }) | { state: 'in_flight'; actor_scope: BaselineScope; cohort_id: number; enrollment_id: number | null }
export interface OptionalDebtApi {
  summary(cohortId: number, signal?: AbortSignal): Promise<DebtSummary>
  records<T extends DebtCard | DebtDraft | DebtVersion>(scope: DebtScope, kind: 'cards' | 'drafts' | 'versions', cursor?: number | null, signal?: AbortSignal): Promise<DebtPage<T>>
  candidates(scope: DebtScope, cursor?: number | null, signal?: AbortSignal): Promise<DebtPage<DebtCandidate>>
  householdCandidates(scope: DebtScope, cursor?: number | null, signal?: AbortSignal): Promise<DebtPage<HouseholdDebtCandidate>>
  mutate(scope: DebtScope, action: DebtAction, input: DebtInput, key: string, signal?: AbortSignal): Promise<DebtMutation>
  status(scope: DebtScope, action: DebtAction, key: string, signal?: AbortSignal): Promise<DebtStatus>
}
export function debtScopeMatches(value: { actor_scope?: BaselineScope; cohort_id?: number; enrollment_id?: number | null }, scope: DebtScope, inFlight = false) {
  return value.actor_scope?.user_id === scope.user_id && value.actor_scope.household_id === scope.household_id && value.cohort_id === scope.cohort_id && (value.enrollment_id === scope.enrollment_id || inFlight && value.enrollment_id === null)
}
export function assertDebtScope(value: DebtEnvelope, scope: DebtScope) {
  if (!debtScopeMatches(value, scope)) throw new ApiRequestError('Private account or program changed. Close and reopen card review.', { status: 403 })
}
const exact = (value: number | null) => value === null || Number.isSafeInteger(value) && value >= 0
export function debtDate(value: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || value.slice(0, 4) === '0000') throw new Error('Use a valid calendar date.')
  const parsed = new Date(`${value}T00:00:00Z`)
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) throw new Error('Use a valid calendar date.')
  return value
}
export function checkedDebtTerms(terms: DebtTerms): DebtTerms {
  const apr = (value: number | null) => exact(value) && (value === null || value <= 100000)
  if (!terms || typeof terms.label !== 'string' || !terms.label.trim() || terms.label.length > 120 || !['active', 'paid_off', 'archived'].includes(terms.status) || !exact(terms.balance_cents) || !exact(terms.minimum_payment_cents) || !apr(terms.apr_bps) || !apr(terms.promotional_apr_bps) || !apr(terms.post_promo_apr_bps) || !Array.isArray(terms.rate_segments) || terms.rate_segments.length > 8 || terms.status === 'paid_off' && terms.balance_cents !== 0) throw new Error('Current card terms cannot be reviewed safely. Refresh before continuing.')
  debtDate(terms.as_of_on)
  for (const day of [terms.due_on, terms.promotional_expires_on]) if (day !== null) debtDate(day)
  for (const rate of terms.rate_segments) {
    if (typeof rate.label !== 'string' || !rate.label.trim() || rate.label.length > 120 || !exact(rate.balance_cents) || !apr(rate.apr_bps) || !apr(rate.post_promo_apr_bps)) throw new Error('Current separate-rate terms cannot be reviewed safely.')
    if (rate.promotional_expires_on !== null) debtDate(rate.promotional_expires_on)
  }
  if (terms.balance_cents !== null && terms.rate_segments.reduce((sum, row) => sum + (row.balance_cents ?? 0), 0) > terms.balance_cents) throw new Error('Separate-rate balances exceed the card balance.')
  return terms
}
export function checkedDebtRecord<T extends DebtCard | DebtDraft | DebtVersion>(record: T, scope: DebtScope): T {
  if (!Number.isSafeInteger(record.id) || record.id < 1 || record.savings_enrollment_id !== scope.enrollment_id) throw new ApiRequestError('Private record enrollment changed. Reopen card review.', { status: 403 })
  if ('current_version' in record) {
    if (!Number.isSafeInteger(record.lock_version) || record.lock_version < 0 || record.current_version_id !== (record.current_version?.id ?? null)) throw new Error('The current card head cannot be reviewed safely.')
    if (record.current_version) { checkedDebtRecord(record.current_version, scope); if (record.current_version.savings_debt_card_id !== record.id) throw new ApiRequestError('Private card identity changed.', { status: 403 }) }
  } else {
    if (!Number.isSafeInteger(record.savings_debt_card_id) || record.savings_debt_card_id < 1) throw new Error('The original card identity is incomplete.')
    checkedDebtTerms(record.terms)
    if ('base_version_id' in record && (!Number.isSafeInteger(record.lock_version) || record.lock_version < 0 || !Number.isSafeInteger(record.base_head_lock_version) || record.base_head_lock_version < 0 || !['pending', 'approved'].includes(record.status))) throw new Error('The pending card review cannot be approved safely.')
  }
  return record
}
export function checkedHouseholdDebtCandidate(record: HouseholdDebtCandidate): HouseholdDebtCandidate {
  if (!Number.isSafeInteger(record.household_debt_id) || record.household_debt_id < 1 || !/^[0-9a-f]{64}$/.test(record.fingerprint) || typeof record.label !== 'string' || !record.label.trim() || !record.proposed_terms || !exact(record.proposed_terms.balance_cents) || !exact(record.proposed_terms.minimum_payment_cents) || !exact(record.proposed_terms.apr_bps) || record.proposed_terms.apr_bps !== null && record.proposed_terms.apr_bps > 99999 || record.linked_card_id !== null && (!Number.isSafeInteger(record.linked_card_id) || record.linked_card_id < 1) || !Array.isArray(record.qualifications)) throw new Error('The saved household card cannot be reviewed safely. Refresh before continuing.')
  return record
}
export function checkedDebtCandidate(record: DebtCandidate): DebtCandidate {
  if (![record.source_tracked_account_id, record.source_account_identity_version_id, record.source_revision_approval_id].every(id => Number.isSafeInteger(id) && id > 0) || !/^[0-9a-f]{64}$/.test(record.fingerprint) || typeof record.label !== 'string' || !record.label.trim() || !record.proposed_terms || !exact(record.proposed_terms.balance_cents) || record.proposed_terms.apr_bps !== null || record.proposed_terms.minimum_payment_cents !== null || record.proposed_terms.as_of_on !== record.statement_as_of_on || !Array.isArray(record.qualifications)) throw new Error('The reviewed liability mapping is incomplete. Refresh before continuing.')
  debtDate(record.statement_as_of_on)
  return record
}
export function checkedDebtSummary(value: DebtSummary, actor: BaselineScope, cohortId: number): DebtSummary {
  if (!Number.isSafeInteger(value.enrollment_id) || value.enrollment_id < 1 || value.actor_scope?.user_id !== actor.user_id || value.actor_scope.household_id !== actor.household_id || value.cohort_id !== cohortId) throw new ApiRequestError('Private account or program changed. Close and reopen card review.', { status: 403 })
  if (!exact(value.known_balance_subtotal_cents) || value.portfolio_complete !== false || value.extra_payment_cents !== null || value.payoff_date !== null || value.savings_credit_cents !== null || !Array.isArray(value.cards) || !Number.isSafeInteger(value.unknown_balance_count) || !Number.isSafeInteger(value.stale_card_count) || !Array.isArray(value.snowball_order) || !Array.isArray(value.avalanche_order)) throw new Error('The qualified card comparison is incomplete. Refresh before continuing.')
  debtDate(value.local_today)
  value.cards.forEach(row => { checkedDebtTerms(row.terms); if (!Number.isSafeInteger(row.card_id) || row.card_id < 1 || !Number.isSafeInteger(row.version_id) || row.version_id < 1 || typeof row.source_stale !== 'boolean' || !Array.isArray(row.qualifications)) throw new Error('Current approved card identities are incomplete.') })
  const rows = new Map(value.cards.map(row => [row.card_id, row]))
  for (const [order, rate] of [[value.snowball_order, false], [value.avalanche_order, true]] as const) {
    if (new Set(order).size !== order.length || order.some(id => { const row = rows.get(id); return !row || row.source_stale || row.terms.status !== 'active' || row.terms.balance_cents === null || row.terms.balance_cents <= 0 || rate && (row.terms.apr_bps === null || row.terms.rate_segments.length > 0 || row.terms.promotional_apr_bps !== null || row.terms.promotional_expires_on !== null || row.terms.post_promo_apr_bps !== null) })) throw new Error('The qualified comparison includes an ineligible card. Refresh before continuing.')
  }
  return value
}
export const debtMoney = (value: number | null) => value === null ? 'Unknown' : `$${savingsInputDollars(value)}`
export const debtApr = (value: number | null) => value === null ? 'Unknown' : `${savingsInputDollars(value)}%`
export const debtDecimal = (value: number | null) => value === null ? '' : savingsInputDollars(value)
export function debtNullableDecimal(value: string, rate = false) {
  if (!value.trim()) return null
  const cents = savingsInputCents(value, true)
  if (rate && cents > 100000) throw new Error('Use an APR from 0% through 1000%, with at most two decimal places.')
  return cents
}
export function debtMapping(record: DebtSource): DebtMapping | null {
  return record.source_tracked_account_id && record.source_account_identity_version_id && record.source_revision_approval_id && record.source_fingerprint ? { source_tracked_account_id: record.source_tracked_account_id, source_account_identity_version_id: record.source_account_identity_version_id, source_revision_approval_id: record.source_revision_approval_id, fingerprint: record.source_fingerprint } : null
}
export function debtApproval(draft: DebtDraft): DebtInput {
  return { draft_id: draft.id, accepted: true, expected_draft_lock_version: draft.lock_version, expected_version_id: draft.base_version_id, expected_head_lock_version: draft.base_head_lock_version }
}
