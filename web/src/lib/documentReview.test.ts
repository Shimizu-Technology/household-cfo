import { describe, expect, it } from 'vitest'
import type { FinancialDocumentImport } from '../api'
import { documentNeedsReview, latestAppliedImport, transactionReviewCoverage } from './documentReview'

function statement(status: FinancialDocumentImport['status'], statuses: string[]): FinancialDocumentImport {
  return { status, transaction_drafts: statuses.map((status, id) => ({ id, status })) } as FinancialDocumentImport
}

describe('partial import review', () => {
  it('keeps unresolved work visible after one row was matched', () => {
    const source = statement('partially_applied', ['matched', 'pending', 'pending'])
    expect(documentNeedsReview(source)).toBe(true)
    expect(transactionReviewCoverage(source)).toEqual({ total: 3, pending: 2, resolved: 1 })
  })

  it('keeps full source accounting pending even when every expense has a decision', () => {
    const source = statement('applied', ['confirmed', 'ignored'])
    source.metadata = { source_accounting_review_pending: true }
    expect(documentNeedsReview(source)).toBe(true)
  })

  it('distinguishes complete decisions from a partially applied source', () => {
    expect(documentNeedsReview(statement('applied', ['confirmed', 'ignored', 'matched']))).toBe(false)
    expect(documentNeedsReview(statement('needs_review', []))).toBe(true)
    expect(documentNeedsReview(statement('partially_applied', []))).toBe(true)
    expect(documentNeedsReview(statement('applied', ['pending']))).toBe(true)
  })
})

describe('retained document history after restarting', () => {
  it('does not count paused old snapshots as current pending review', () => {
    const source = statement('partially_applied', ['confirmed', 'pending'])
    source.context_paused_by_restart = true
    source.metadata = { source_accounting_review_pending: true }
    expect(documentNeedsReview(source)).toBe(false)
  })
  it('current approved context ignores a newer paused snapshot, while retaining history in the input', () => {
    const current = { ...statement('applied', ['confirmed']), id: 1, items: [], processed_at: '2026-10-01T00:00:00Z' }
    const paused = { ...statement('applied', ['confirmed']), id: 2, items: [], processed_at: '2026-10-06T00:00:00Z', context_paused_by_restart: true }
    const all = [current, paused]
    expect(latestAppliedImport(all)?.id).toBe(1)
    expect(latestAppliedImport([paused])).toBeNull()
    expect(all).toHaveLength(2)
  })
})
