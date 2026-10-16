import type { IgnoredTransactionDraft, RecentTransaction, TransactionDraft } from '../api'

const currency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 2 })

type DraftIdentity = Pick<TransactionDraft, 'merchant' | 'amount' | 'amount_cents'>

function draftAmount(draft: DraftIdentity) {
  if (typeof draft.amount_cents === 'number') return draft.amount_cents / 100
  return Number.isFinite(draft.amount) ? draft.amount : 0
}

/** Names one transaction for screen readers, e.g. "McDonald's $25.00". */
export function transactionItemName(draft: DraftIdentity) {
  return `${draft.merchant} ${currency.format(draftAmount(draft))}`
}

export function transactionMonthName(occurredOn: string) {
  const [year, month] = occurredOn.split('-').map(Number)
  if (!year || !month) return 'this month'
  return new Intl.DateTimeFormat('en-US', { month: 'long', timeZone: 'UTC' }).format(new Date(Date.UTC(year, month - 1, 1)))
}

/** Plain-language confirmation shown before a reviewed transaction goes back to pending review. */
export function transactionReopenConfirmMessage(draft: Pick<TransactionDraft, 'merchant' | 'amount' | 'amount_cents' | 'status' | 'occurred_on'>) {
  const item = `${draft.merchant} (${currency.format(draftAmount(draft))})`
  if (draft.status === 'ignored') {
    return `Restore ${item} to review? It goes back to your pending transactions. Your actuals do not change until you confirm it.`
  }
  if (draft.status === 'matched') {
    return `Undo the match for ${item}? It goes back to your pending transactions. Your actuals do not change.`
  }
  return `Reopen ${item}? This removes it from ${transactionMonthName(draft.occurred_on)}'s actuals and puts it back in review, where you can edit, confirm, or ignore it.`
}

/** Returns the message to show when the typed bulk-confirm phrase is wrong; null when it matches or was canceled. */
export function bulkConfirmPhraseMismatchMessage(count: number, entered: string | null | undefined) {
  if (entered === null || entered === undefined) return null
  const phrase = `CONFIRM ${count}`
  if (entered.trim() === phrase) return null
  return `Nothing was confirmed. Type ${phrase} exactly to confirm all ${count}.`
}

/** "Mia drafted" only when every draft came from Mia chat; manual, bank, and import drafts get neutral copy. */
export function transactionReviewStackTitle(drafts: Array<Pick<TransactionDraft, 'source_type'>>, assistantName: string) {
  if (drafts.length > 0 && drafts.every((draft) => draft.source_type === 'manual_chat')) {
    return `${assistantName} drafted transactions for your approval`
  }
  return 'Transactions to review'
}

export function transactionCategoryWarningCopy(draft: Pick<TransactionDraft, 'source_type' | 'financial_document_import_id'>, assistantName: string) {
  if (draft.financial_document_import_id) {
    return `${assistantName} kept the receipt or document detail but did not guess. Choose where each item belongs before it changes your actuals.`
  }
  if (draft.source_type === 'manual_chat') {
    return `${assistantName} could not confidently match this purchase. Choose where it belongs before it changes your actuals.`
  }
  return 'Needs a category. Choose where it belongs before it changes your actuals.'
}

/** A confirmed ledger row can be reopened through the review that confirmed it. */
export function transactionDraftFromLedgerRow(row: RecentTransaction): TransactionDraft | null {
  if (!row.transaction_draft_id) return null
  return {
    id: row.transaction_draft_id,
    occurred_on: row.occurred_on,
    merchant: row.merchant,
    amount: row.amount,
    status: 'confirmed',
    source_type: row.source_type,
    category_id: null,
    category_name: row.categories.join(', ') || null,
  }
}

export function transactionDraftFromIgnored(row: IgnoredTransactionDraft): TransactionDraft {
  return {
    id: row.id,
    occurred_on: row.occurred_on,
    merchant: row.merchant,
    amount: row.amount,
    amount_cents: row.amount_cents,
    status: row.status || 'ignored',
    source_type: row.source_type,
    category_id: row.category_id,
    category_name: row.category_name,
  }
}
