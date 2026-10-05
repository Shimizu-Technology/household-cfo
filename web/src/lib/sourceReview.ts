import type { ParticipantSourceReview } from './participantSourceReview'
import type { FinancialDocumentImport, TransactionDraft } from '../api'

export type SourceReviewFilter = 'all' | 'posted' | 'unresolved' | 'informational'
export type SourceAccount = {
  id: number; source_key: string; account_basis: 'asset' | 'liability' | 'unknown'
  period_start_on: string | null; period_end_on: string | null
  opening_balance_cents: number | null; closing_balance_cents: number | null
  printed_debit_cents: number | null; printed_credit_cents: number | null; printed_row_count: number | null
  limitations: string[]; evidence_available: boolean
  evidence?: { label?: string; masked_identifier?: string; header_evidence?: string } | null
}
export type SourceAccountReconciliation = {
  source_key: string; represented_rows: number; posted_rows: number; unresolved_rows: number
  row_count_matches: boolean | null; debit_residual_cents: number | null; credit_residual_cents: number | null
  balance_residual_cents: number | null; arithmetic_balanced: boolean; limitations: string[]
}
export type SourceEvent = {
  id: number; financial_source_account_id: number; financial_extraction_revision_id: number; position: number; row_identity: string
  row_kind: 'posted' | 'informational' | 'unresolved'
  event_type: 'purchase' | 'fee' | 'refund' | 'income' | 'transfer' | 'debt_payment' | 'cash_withdrawal' | 'interest' | 'adjustment' | 'unknown'
  signed_amount_cents: number | null; expense_amount_cents: number | null; posted_on: string | null; authorized_on: string | null
  locator: { page?: number; sheet_index?: number; row?: number; extraction_index?: number }
  funding_components: Array<{ source_key: string; amount_cents: number }>; limitations: string[]
  review_state: string; expense_projection_eligible: boolean; evidence_available: boolean
  evidence?: { merchant?: string; raw_description?: string; evidence?: string; source_amount_text?: string; displayed_amount_cents?: number; category_name?: string } | null
  transaction_draft?: TransactionDraft | null
}
export type SourceReview = {
  participant_review?: ParticipantSourceReview
  schema_version: 1; document_import_id: number
  revision: {
    id: number; contract_version: string; revision_number: number; payload_digest: string; created_at: string
    source_document_identity: string; financial_document_import_id: number; source_available: boolean; review_state: string; participant_approved: boolean; accounts: SourceAccount[]
    coverage: { expected_page_count?: number | null; processed_pages?: number[]; expected_sheet_count?: number | null; processed_sheets?: number[]; reported_row_count?: number | null; represented_row_count?: number }
    reconciliation: {
      status: string; participant_approved: boolean
      row_census: { represented: number; reported: number | null; matches_reported: boolean | null; by_kind: Partial<Record<SourceEvent['row_kind'], number>> }
      page_coverage: { expected: number | null; processed: number[] | null; all_processed: boolean | null }
      sheet_coverage?: { expected: number | null; processed: number[] | null }
      accounts: SourceAccountReconciliation[]; limitations: string[]
    }
  }
  accounts: SourceAccount[]
  counts: { all: number; posted: number; unresolved: number; informational: number; pending_transaction_drafts: number; resolved_transaction_drafts: number }
  review_pending: boolean
  pagination: { page: number; per_page: number; total_count: number; total_pages: number; has_previous: boolean; has_next: boolean }
  events: SourceEvent[]
}

export function sourceReviewMode(document: FinancialDocumentImport): 'typed' | 'legacy' | 'unsupported' {
  const version = document.metadata.source_accounting_contract_version
  if (version == null || version === 'legacy_expense_only_v1') return 'legacy'
  if (version === 'source_accounting_v1' && Number.isSafeInteger(document.metadata.source_accounting_revision_id)) return 'typed'
  return 'unsupported'
}

export function sourceAccountLabel(account: SourceAccount | undefined, id: number): string {
  return [account?.evidence?.label, account?.evidence?.masked_identifier].filter(Boolean).join(' · ') || `Account ${id}`
}

export function sourceMoney(cents: number | null | undefined, signed = false): string {
  if (cents == null || !Number.isSafeInteger(cents)) return 'Unknown'
  return `${signed && cents > 0 ? '+' : ''}${new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(cents / 100)}`
}

export function sourceEventLabel(event: SourceEvent): string {
  if (event.row_kind === 'informational') return 'Informational · excluded from movements'
  if (event.row_kind === 'unresolved') return 'Unresolved · needs clarification'
  const names: Record<SourceEvent['event_type'], string> = {
    purchase: 'Purchase', fee: 'Fee', refund: 'Refund', income: 'Income', transfer: 'Transfer', debt_payment: 'Card / debt payment',
    cash_withdrawal: 'Cash withdrawal', interest: 'Interest', adjustment: 'Adjustment', unknown: 'Unknown type',
  }
  const direction = event.signed_amount_cents == null ? 'unknown amount' : event.signed_amount_cents < 0 ? 'outflow' : event.signed_amount_cents > 0 ? 'inflow' : 'zero movement'
  return `${names[event.event_type]} · ${direction}`
}

export function sourceLocator(event: SourceEvent): string {
  const parts = [event.locator.page != null ? `Page ${event.locator.page}` : '', event.locator.sheet_index != null ? `Sheet ${event.locator.sheet_index}` : '', event.locator.row != null ? `row ${event.locator.row}` : ''].filter(Boolean)
  return parts.join(' · ') || 'Source location unavailable'
}

// Fail closed instead of displaying another revision or treating missing rows as zero.
export function validateSourceReview(data: SourceReview, importId: number, revisionId: number, page: number, filter: SourceReviewFilter): void {
  const pager = data?.pagination
  if (data?.schema_version !== 1 || data.document_import_id !== importId || data.revision?.id !== revisionId || data.revision.contract_version !== 'source_accounting_v1' || data.revision.financial_document_import_id !== importId || !pager || pager.page !== page || pager.per_page !== 50 || !Array.isArray(data.events) || data.events.length > 50 || !Array.isArray(data.accounts)) throw new Error('Statement review changed or returned incomplete data. Refresh this import before continuing.')
  const count = data.counts?.[filter === 'all' ? 'all' : filter]
  if (!Number.isSafeInteger(count) || count < 0 || pager.total_count !== count || pager.total_pages !== Math.max(1, Math.ceil(count / 50)) || pager.has_previous !== (page > 1) || pager.has_next !== (page < pager.total_pages) || data.events.length !== Math.min(50, Math.max(0, count - (page - 1) * 50))) throw new Error('Statement row coverage could not be verified. Refresh this import before continuing.')
  const seen = new Set<number>()
  for (const row of data.events) {
    if (row.financial_extraction_revision_id !== revisionId || seen.has(row.id) || (filter !== 'all' && row.row_kind !== filter)) throw new Error('Statement rows do not match the requested review page.')
    seen.add(row.id)
  }
}
