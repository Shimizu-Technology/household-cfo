import { describe, expect, it } from 'vitest'
import {
  bulkConfirmPhraseMismatchMessage,
  transactionCategoryWarningCopy,
  transactionDraftFromLedgerRow,
  transactionItemName,
  transactionReopenConfirmMessage,
  transactionReviewStackTitle,
} from './transactionReview'

describe('transaction review copy', () => {
  it('names a transaction with merchant and exact amount', () => {
    expect(transactionItemName({ merchant: "McDonald's", amount: 25, amount_cents: 2500 })).toBe("McDonald's $25")
    expect(transactionItemName({ merchant: 'Pay-Less', amount: 10.5 })).toBe('Pay-Less $10.50')
  })

  it('explains that reopening a confirmed transaction removes it from that month’s actuals', () => {
    const message = transactionReopenConfirmMessage({ merchant: "McDonald's", amount: 25, status: 'confirmed', occurred_on: '2026-10-04' })
    expect(message).toContain("Reopen McDonald's ($25)?")
    expect(message).toContain("removes it from October's actuals and puts it back in review")
  })

  it('explains that restoring an ignored draft does not change actuals', () => {
    const message = transactionReopenConfirmMessage({ merchant: 'Shell', amount: 40, status: 'ignored', occurred_on: '2026-10-04' })
    expect(message).toMatch(/^Restore Shell \(\$40\) to review\?/)
    expect(message).toContain('Your actuals do not change until you confirm it.')
  })

  it('reports a wrong bulk-confirm phrase instead of failing silently', () => {
    expect(bulkConfirmPhraseMismatchMessage(5, 'confirm 5')).toBe('Nothing was confirmed. Type CONFIRM 5 exactly to confirm all 5.')
    expect(bulkConfirmPhraseMismatchMessage(5, '')).toBe('Nothing was confirmed. Type CONFIRM 5 exactly to confirm all 5.')
    expect(bulkConfirmPhraseMismatchMessage(5, ' CONFIRM 5 ')).toBeNull()
    expect(bulkConfirmPhraseMismatchMessage(5, null)).toBeNull()
  })

  it('keeps the purchase review heading short and source-neutral', () => {
    expect(transactionReviewStackTitle()).toBe('Purchases to review')
  })

  it('keeps the uncategorized warning source-neutral for manual and bank rows', () => {
    expect(transactionCategoryWarningCopy({ source_type: 'manual_ui' }, 'Mia')).toMatch(/^Needs a category\./)
    expect(transactionCategoryWarningCopy({ source_type: 'plaid' }, 'Mia')).not.toContain('Mia')
    expect(transactionCategoryWarningCopy({ source_type: 'manual_chat' }, 'Mia')).toContain('Mia could not confidently match')
    for (const source of [{ source_type: 'manual_ui' }, { source_type: 'plaid' }, { source_type: 'manual_chat' }, { source_type: 'receipt', financial_document_import_id: 5 }]) {
      expect(transactionCategoryWarningCopy(source, 'Mia')).toContain('before it counts as spent')
    }
  })

  it('only offers reopen for ledger rows confirmed through a review', () => {
    const row = { id: 9, occurred_on: '2026-10-04', merchant: 'Shell', amount: 40, source_type: 'manual_ui', categories: ['Gas'] }
    expect(transactionDraftFromLedgerRow(row)).toBeNull()
    expect(transactionDraftFromLedgerRow({ ...row, transaction_draft_id: 220 })).toMatchObject({ id: 220, status: 'confirmed', merchant: 'Shell' })
  })
})
