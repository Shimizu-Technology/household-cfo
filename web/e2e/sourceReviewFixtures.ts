import type { SourceEvent, SourceReview, SourceReviewFilter } from '../src/lib/sourceReview'

// Fictional accounting only; no real statement content or imported private data.
export function sourceReviewFixture(page = 1, filter: SourceReviewFilter = 'all'): SourceReview {
  const events: SourceEvent[] = Array.from({ length: 137 }, (_, index) => ({
    id: 4000 + index, financial_source_account_id: 501, financial_extraction_revision_id: 88, position: index, row_identity: `synthetic-row-${index}`,
    row_kind: index < 125 ? 'posted' : index < 130 ? 'informational' : 'unresolved',
    event_type: index === 0 ? 'refund' : index === 1 ? 'transfer' : index === 2 ? 'debt_payment' : index === 3 ? 'fee' : index < 125 ? 'purchase' : 'unknown',
    signed_amount_cents: index >= 125 ? null : index === 0 ? 3000 : -1000, expense_amount_cents: index >= 3 && index < 125 ? 1000 : null,
    posted_on: index >= 130 ? null : '2026-09-15', authorized_on: null, locator: { page: Math.floor(index / 20) + 1, row: index + 1 },
    funding_components: [], limitations: index >= 130 ? ['amount_unknown', 'date_unknown'] : [], review_state: 'unreviewed', expense_projection_eligible: index >= 3 && index < 125,
    evidence_available: index !== 4, evidence: index === 4 ? null : { merchant: `Fictional entry ${index + 1}`, raw_description: `Synthetic source description ${index + 1}`, ...(index >= 125 && index < 130 ? { displayed_amount_cents: 5000 } : {}) }, transaction_draft: null,
  }))
  const filtered = filter === 'all' ? events : events.filter((event) => event.row_kind === filter)
  const account = { id: 501, source_key: 'synthetic-account', account_basis: 'asset' as const, period_start_on: '2026-09-01', period_end_on: '2026-09-30', opening_balance_cents: 500000, closing_balance_cents: 379000, printed_debit_cents: 124000, printed_credit_cents: 3000, printed_row_count: 137, limitations: [], evidence_available: true, evidence: { label: 'Fictional checking', masked_identifier: '••1234' } }
  return {
    schema_version: 1, document_import_id: 1203,
    revision: { id: 88, contract_version: 'source_accounting_v1', revision_number: 1, payload_digest: 'fictional-digest', source_document_identity: 'fictional-identity', financial_document_import_id: 1203, created_at: '2026-10-01T01:00:00Z', source_available: true, review_state: 'unreviewed', participant_approved: false, accounts: [account],
      coverage: { expected_page_count: 8, processed_pages: [1,2,3,4,5,6,7], reported_row_count: 137, represented_row_count: 137 },
      reconciliation: { status: 'unreviewed', participant_approved: false, row_census: { represented: 137, reported: 137, matches_reported: true, by_kind: { posted: 125, informational: 5, unresolved: 7 } }, page_coverage: { expected: 8, processed: [1,2,3,4,5,6,7], all_processed: false }, sheet_coverage: { expected: null, processed: [] }, accounts: [{ source_key: 'synthetic-account', represented_rows: 137, posted_rows: 125, unresolved_rows: 7, row_count_matches: true, debit_residual_cents: 0, credit_residual_cents: 0, balance_residual_cents: 0, arithmetic_balanced: false, limitations: ['unresolved_rows'] }], limitations: ['page_coverage_incomplete', 'coverage_and_classifications_require_participant_review'] },
    }, accounts: [account], counts: { all: 137, posted: 125, informational: 5, unresolved: 7, pending_transaction_drafts: 122, resolved_transaction_drafts: 0 }, review_pending: true,
    pagination: { page, per_page: 50, total_count: filtered.length, total_pages: Math.max(1, Math.ceil(filtered.length / 50)), has_previous: page > 1, has_next: page < Math.ceil(filtered.length / 50) }, events: filtered.slice((page - 1) * 50, page * 50),
  }
}
