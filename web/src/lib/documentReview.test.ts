import { describe, expect, it } from 'vitest'
import type { FinancialDocumentImport } from '../api'
import { documentNeedsReview, transactionReviewCoverage } from './documentReview'

function statement(status: FinancialDocumentImport['status'], statuses: string[]): FinancialDocumentImport {
  return { status, transaction_drafts: statuses.map((status, id) => ({ id, status })) } as FinancialDocumentImport
}

describe('partial import review', () => {
  it('keeps unresolved work visible after one row was matched', () => {
    const source = statement('partially_applied', ['matched', 'pending', 'pending'])
    expect(documentNeedsReview(source)).toBe(true)
    expect(transactionReviewCoverage(source)).toEqual({ total: 3, pending: 2, resolved: 1 })
  })

  it('distinguishes complete decisions from a partially applied source', () => {
    expect(documentNeedsReview(statement('applied', ['confirmed', 'ignored', 'matched']))).toBe(false)
    expect(documentNeedsReview(statement('needs_review', []))).toBe(true)
    expect(documentNeedsReview(statement('partially_applied', []))).toBe(true)
    expect(documentNeedsReview(statement('applied', ['pending']))).toBe(true)
  })
})
