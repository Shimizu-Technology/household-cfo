import type { SavingsCalendar, SavingsProjection } from './savingsChallenge'
import type { BaselineScope } from './financialBaseline'
export type DailyScope = BaselineScope & { enrollment_id: number; cohort_id?: number }
export type DailyCategory = { id: number; name: string; stack_key: string }
export type DailySplit = { budget_category_id: number; amount_cents: number }
export type DailyDay = { local_on: string; scope: 'participant_daily_reports'; spending_state: 'spending' | 'no_spend' | 'unknown'; check_in_id: number | null; check_in_version_id: number | null; check_in_lock_version: number; completed_at: string | null; approved_purchase_count: number; reported_spend_cents: number | null; canonical_links_changed: boolean; no_spend_discrepancy: boolean; all_account_completeness: 'unknown' }
export type DailyEnvelope = { actor_scope: BaselineScope; enrollment_id?: number | null; cohort_id?: number | null }
export type DailyContext = DailyEnvelope & { enrollment_id: number; calendar: SavingsCalendar; day: DailyDay | null; categories: DailyCategory[]; category_options: { stack_key: string; label: string }[] }
export type DailyVersion = { id: number; version_number: number; previous_version_id: number | null; approved_at: string; reason: string | null }
export type PurchaseFacts = { posted_on?: string | null; amount_cents: number; merchant: string; purchased_on: string; splits: DailySplit[]; disposition: 'purchase' | 'void'; link_kind: 'manual_new' | 'existing_transaction'; linked_transaction_id: number | null }
export type DailyPurchaseVersion = DailyVersion & PurchaseFacts & { savings_daily_purchase_id: number; household_transaction_id: number; daily_sequence: number }
export type DailyHead<T> = { id: number; current_version_id: number | null; lock_version: number; current_version: T | null }
export type DailyPurchase = DailyHead<DailyPurchaseVersion>
export type DailyDraft = { id: number; lock_version: number; base_version_id: number | null; base_head_lock_version: number; status: 'pending' | 'approved'; approved_version_id: number | null; reason: string | null }
export type DailyPurchaseDraft = DailyDraft & PurchaseFacts & { savings_daily_purchase_id: number }
export type DailyReflectionVersion = DailyVersion & { savings_daily_purchase_id: number; savings_daily_reflection_id: number; feeling_then: string | null; feeling_now: string | null; erased_at: string | null }
export type DailyReflection = DailyHead<DailyReflectionVersion> & { savings_daily_purchase_id: number }
export type DailyCheckInVersion = DailyVersion & { savings_daily_check_in_id: number; local_on: string; spending_state: DailyDay['spending_state']; daily_sequence: number }
export type DailyCheckIn = DailyHead<DailyCheckInVersion> & { local_on: string }
export type CheckpointSnapshot = { calculation_version: 'savings_checkpoint_v1'; milestone_day: 30 | 60 | 90; cutoff_on: string; captured_at: string; time_zone: string; plan_selection: 'approved_by_cutoff' | 'retained_original' | 'explicit_correction'; savings: SavingsProjection; baseline: { version_id: number | null; coverage_status: string; source_evidence_status: string; window_start_on?: string; window_end_on?: string; supported_complete_calendar_month_count?: number; observed_spending_known?: boolean }; daily: { scope: 'participant_daily_reports'; approved_purchase_count: number; reported_spend_cents: number | null; completed_check_in_days: number; no_spend_days: number; unknown_reported_days: number; unknown_unreported_days: number; all_account_completeness: 'unknown'; no_spend_discrepancy_days: number }; final_confirmation_status: 'not_applicable' | 'pending' | 'confirmed' }
export type DailyCheckpointVersion = DailyVersion & { savings_checkpoint_id: number; snapshot: CheckpointSnapshot }
export type DailyCheckpoint = DailyHead<DailyCheckpointVersion> & { milestone_day: 30 | 60 | 90 }
export type DailyCheckpointDraft = DailyDraft & { savings_checkpoint_id: number; snapshot: CheckpointSnapshot }
export type DailyCandidate = { id: number; merchant: string; amount_cents: number; posted_on: string; purchased_on_candidates: string[]; splits: DailySplit[]; digest: string; source_owned: boolean }
export type DailyCollection = 'purchases' | 'purchase_drafts' | 'purchase_versions' | 'reflections' | 'reflection_versions' | 'check_ins' | 'check_in_versions' | 'checkpoints' | 'checkpoint_drafts' | 'checkpoint_versions'
export type DailyPage<T> = DailyEnvelope & { records: T[]; next_cursor: number | null }
export type DailyAction = 'purchase_stage' | 'purchase_approve' | 'reflection_save' | 'check_in_save' | 'checkpoint_stage' | 'checkpoint_approve' | 'category_create' | 'reflection_erase'
export type DailyInput = Record<string, unknown>
export type DailyResult<T = unknown> = DailyEnvelope & { record: T; replayed: boolean }
export type DailyEraseResult = { erased: true; reflection_id: number; version_id: number; replayed: boolean }
export type DailyStatus = ({ state: 'committed'; record: unknown; replayed: true } | { state: 'unknown'; can_retry: true } | { state: 'in_flight' }) & DailyEnvelope
export type DailyApproval = { draft_id: number; accepted: true; expected_draft_lock_version: number; expected_version_id: number | null; expected_head_lock_version: number }
export function dailyApproval(draft: DailyDraft): DailyApproval { return { draft_id: draft.id, accepted: true, expected_draft_lock_version: draft.lock_version, expected_version_id: draft.base_version_id, expected_head_lock_version: draft.base_head_lock_version } }
export const dailyScopeMatches = (left: DailyScope | null, right: DailyScope | null) => Boolean(left && right && left.user_id === right.user_id && left.household_id === right.household_id && left.enrollment_id === right.enrollment_id && left.cohort_id === right.cohort_id)
export type DailyEraseStatus = ({ state: 'committed' } & DailyEraseResult) | { state: 'unknown'; can_retry: true } | { state: 'in_flight' }

// Legacy cohortless callers can use old envelopes. Selected-program callers
// require both server IDs; a supplied enrollment ID is checked for legacy callers.
export function dailyResponseMatches(response: DailyEnvelope, scope: DailyScope): boolean {
  return response.actor_scope.user_id === scope.user_id && response.actor_scope.household_id === scope.household_id
    && (response.enrollment_id === undefined ? scope.cohort_id === undefined : response.enrollment_id === scope.enrollment_id)
    && (scope.cohort_id === undefined ? true : response.cohort_id === scope.cohort_id)
}
export function dailyContextMatches(context: DailyContext, scope: BaselineScope, cohortId?: number, enrollmentId?: number): boolean {
  return context.actor_scope.user_id === scope.user_id && context.actor_scope.household_id === scope.household_id
    && Number.isSafeInteger(context.enrollment_id) && context.enrollment_id > 0
    && (cohortId === undefined || context.cohort_id === cohortId)
    && (enrollmentId === undefined || context.enrollment_id === enrollmentId)
}
