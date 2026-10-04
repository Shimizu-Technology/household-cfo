import type { FinancialDocumentImport } from '../api'

export function documentNeedsReview(documentImport: FinancialDocumentImport): boolean {
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
