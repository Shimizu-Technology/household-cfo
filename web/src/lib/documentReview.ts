import type { FinancialDocumentImport } from '../api'

export function documentNeedsReview(documentImport: FinancialDocumentImport): boolean {
  if (documentImport.context_paused_by_restart) return false
  return documentImport.metadata?.source_accounting_review_pending === true
    || documentImport.status === 'needs_review'
    || documentImport.status === 'partially_applied'
    || documentImport.transaction_drafts.some((draft) => draft.status === 'pending')
}

export function transactionReviewCoverage(documentImport: FinancialDocumentImport) {
  const drafts = documentImport.transaction_drafts
  return {
    total: drafts.length,
    pending: drafts.filter((draft) => draft.status === 'pending').length,
    resolved: drafts.filter((draft) => draft.status !== 'pending').length,
  }
}

/** Retained files from an earlier picture are history, not current approved context. */
export function latestAppliedImport(imports: FinancialDocumentImport[]) {
  return imports.filter(documentImport => !documentImport.context_paused_by_restart
    && (documentImport.status === 'applied' || documentImport.status === 'partially_applied')
    && (documentImport.items.some(item => Boolean(item.applied_at))
      || documentImport.transaction_drafts.some(draft => ['confirmed', 'corrected', 'matched'].includes(draft.status))))
    .sort((left, right) => timestamp(right) - timestamp(left))[0] ?? null
}
function timestamp(documentImport: FinancialDocumentImport) {
  const value = Date.parse(documentImport.applied_at ?? documentImport.processed_at ?? '')
  return Number.isNaN(value) ? 0 : value
}
