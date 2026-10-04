import type { SavingsChallenge, SavingsEntryDraft, SavingsEntryVersion, SavingsPlanDraft, SavingsPlanVersion } from '../lib/savingsChallenge'
export function savingsFixture(enrolled = true): SavingsChallenge {
  return enrolled ? {
    enrollment: { accepted_cohort_release_id: 12, id: 1, cohort_id: 42, starts_on: '2026-10-01', ends_on: '2026-12-29', time_zone: 'Pacific/Guam', status: 'active', policy_version: 'dev-notice-v1', late_start_accepted: false, current_accepted_plan_version_id: null, approval_sequence: 0, lock_version: 0 },
    accepted_plan: null,
    calendar: { local_today: '2026-10-04', time_zone: 'Pacific/Guam', starts_on: '2026-10-01', ends_on: '2026-12-29', phase: 'active', day: 4, checkpoints: { '30': '2026-10-30', '60': '2026-11-29', '90': '2026-12-29' } },
    projection: { calculation_version: 1, cutoff_on: '2026-10-04', reporting_known: false, zero_attested: false, reported_cents: null, evidence_supported_cents: null, target_cents: null, achieved: null, progress_basis_points: null, contribution_cents: null, withdrawal_cents: null, included_entry_count: 0, excluded_entry_count: 0, pending_entry_count: 0, included_version_ids: [], approval_sequence: 0, accepted_plan_version_id: null, zero_attestation_id: null },
    pending_entry_count: 0, pending_plan_count: 0,
  } : {
    enrollment: null, accepted_plan: null, projection: null, suggested_target_cents: 50000,
    offer: { cohort_release_id: 12, acceptance_digest: 'a'.repeat(64), policy_version: 'dev-notice-v1', time_zone: 'Pacific/Guam', cohort_label: 'Fictional 30-person cohort', local_today: '2026-10-04', configured_starts_on: '2026-10-01', configured_ends_on: '2026-12-29', personal_starts_on: '2026-10-04', personal_ends_on: '2027-01-01', late_start_acceptance_required: true, accepting_enrollments: true },
  }
}
export function savingsPlanDraft(target = 50000): SavingsPlanDraft { return { id: 11, target_cents: target, base_plan_version_id: null, approved_plan_version_id: null, status: 'pending', reason: '', lock_version: 0 } }
export function savingsPlanVersion(target = 50000): SavingsPlanVersion { return { id: 21, target_cents: target, previous_version_id: null, version_number: 1, approval_sequence: 1, reason: '', approved_at: '2026-10-04T00:00:00Z' } }
export function savingsEntryDraft(amount = 2550): SavingsEntryDraft { return { id: 31, savings_entry_id: 41, base_version_id: null, base_entry_lock_version: 0, approved_version_id: null, signed_cents: amount, effective_on: '2026-10-04', funding_source: 'new_money_reserved', reason: '', status: 'pending', lock_version: 0 } }
export function savingsEntryVersion(amount = 2550): SavingsEntryVersion { return { id: 51, savings_entry_id: 41, previous_version_id: null, version_number: 1, approval_sequence: 2, signed_cents: amount, effective_on: '2026-10-04', currency: 'USD', funding_source: 'new_money_reserved', evidence_supported_cents: 0, evidence_status: 'not_linked', reason: '', approved_at: '2026-10-04T00:00:00Z' } }
