import type { SourceEvent } from './sourceReview'
export type ReviewedFacts = {
  source_account_identity_version_id: number; disposition: 'include' | 'match' | 'exclude' | 'informational'
  event_type: SourceEvent['event_type']; signed_amount_cents: number | null; purchase_amount_cents: number | null
  posted_on: string | null; authorized_on?: string | null; merchant: string | null; budget_category_id: number | null
  overlap_disposition: 'new' | 'distinct' | 'canonical' | 'match' | 'excluded'; matched_version_id?: number | null; external_reference?: string | null
}
export type ReviewHead = { id: number | null; approved_version_id: number | null; lock_version: number }
export type ReviewedSourceLocation = { document_import_id: number | null; filename: string | null; locator: SourceEvent['locator']; source_available: boolean }
export type ReviewedRow = { id: number; digest: string; version_number: number; facts: ReviewedFacts; reason: string; projection: { action: string }; actual: { id: number; digest: string; amount_cents: number } | null; current?: boolean; recognized_account?: ReviewedRecognizedAccount; matched_target?: ReviewedRow | null; source?: ReviewedSourceLocation }
export type PendingSourceDraft = { id: number; digest: string; lock_version: number; status: string; facts: ReviewedFacts; projection: { action: string; transaction_id?: number | null; expected_digest?: string | null }; reason: string; recognized_account?: ReviewedRecognizedAccount; matched_target?: ReviewedRow | null }
export type AccountStatementFacts = { period_start_on: string | null; period_end_on: string | null; opening_balance_cents: number | null; closing_balance_cents: number | null; printed_debit_cents: number | null; printed_credit_cents: number | null; printed_row_count: number | null; printed_row_count_basis?: 'posted' | 'all' }
export type TrackedSourceAccount = { id: number; label: string; account_basis: 'asset' | 'liability'; account_id: number | null }
export type ReviewedSourceAccount = { source_account_id: number; head: ReviewHead; approved: { id: number; digest: string; version_number: number; statement_facts: AccountStatementFacts; tracked_account: TrackedSourceAccount } | null }
export type ParticipantSourceReview = {
  schema_version: 1; actor_scope?: StatementReviewActorScope; economic_groups?: ReviewedEconomicGroup[]; rows: Record<string, { head: ReviewHead; approved: ReviewedRow | null; pending: PendingSourceDraft | null }>
  accounts: ReviewedSourceAccount[]; categories: Array<{ id: number; name: string }>
  coverage: { revision_id: number; represented_rows: number; approved_rows: number; pending_corrections: number; content_digest: string; deficiencies: string[] }
  approved_coverage: { id: number; digest: string; status: 'complete' | 'qualified'; current: boolean; deficiencies: string[] } | null
}
export type SourceReviewAction = 'account_link' | 'stage' | 'approve' | 'cancel' | 'coverage' | 'economic_link' | 'project'
export function statementCents(value: string, nullable = true): number | null {
  if (!value.trim() && nullable) return null
  if (!/^-?\d+(?:\.\d{1,2})?$/.test(value.trim())) throw new Error('Use an amount with no more than two decimal places.')
  const [whole, fraction = ''] = value.trim().replace('-', '').split('.')
  const cents = (Number(whole) * 100 + Number(fraction.padEnd(2, '0'))) * (value.trim().startsWith('-') ? -1 : 1)
  if (!Number.isSafeInteger(cents) || Math.abs(cents) > 1_000_000_000_000) throw new Error('Amount is outside the supported range.')
  return cents
}
export function statementDollars(cents: number | null | undefined): string { return cents == null ? '' : (cents / 100).toFixed(2) }

export type StatementReviewActorScope = { user_id: number; household_id: number }
export type ReviewedEconomicGroup = { id: number; head: ReviewHead; approved: { id: number; digest: string; version_number: number; kind: 'transfer' | 'purchase_funding' | 'refund'; reason: string; current: boolean; members: Array<{ role: 'movement' | 'purchase' | 'funding' | 'original_purchase' | 'refund'; allocation_cents: number; record: ReviewedRow }> } | null }
export type StatementReviewRequestStatus = { state: 'committed'; record: unknown; replayed: true } | { state: 'unknown'; can_retry: true } | { state: 'in_flight' }

export type ReviewedRecognizedAccount = { identity_version_id: number; tracked_account_id: number; label: string; account_basis: 'asset' | 'liability'; account_id: number | null; current: boolean }
