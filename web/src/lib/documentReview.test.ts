import { describe, expect, it } from 'vitest'
import type { FinancialDocumentImport } from '../api'
import { documentNeedsReview, importIdsForRevisions, uploadStatusLabel, latestAppliedImport, transactionReviewCoverage, withStatementProgress } from './documentReview'

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

describe('statement status follows current saved lines rather than import processing', () => {
  it.each(['needs_review', 'partially_applied'] as const)('calls all approved lines saved despite legacy %s', status => {
    const source = { ...statement(status, []), statement_review: { total: 27, done: 27, without_category: 0, coverage: { question: null, answer: null } } } as FinancialDocumentImport
    expect(uploadStatusLabel(source)).toBe('Saved')
    expect(documentNeedsReview(source)).toBe(false)
    source.statement_review!.without_category = 13
    expect(uploadStatusLabel(source)).toBe('Saved · some without a category')
    // A saved purchase with no category counts nowhere yet, so the statement still needs her.
    expect(documentNeedsReview(source)).toBe(true)
    source.statement_review!.without_category = 0
    source.statement_review!.coverage = { question: 'Is anything missing?', answer: null }
    expect(uploadStatusLabel(source)).toBe('Saved · check for missing lines')
    expect(documentNeedsReview(source)).toBe(true)
    source.statement_review!.coverage.answer = 'something_missing'
    expect(uploadStatusLabel(source)).toBe('Saved · something may be missing')
    expect(documentNeedsReview(source)).toBe(true)
    source.statement_review!.done = 26
    expect(uploadStatusLabel(source)).toBe('Some lines saved')
    expect(documentNeedsReview(source)).toBe(true)
  })
})

describe('upload status after a statement save', () => {
  const progress = (done: number) => ({ total: 4, done, without_category: 0, spending: { count: 0, cents: 0 }, coverage: { question: null, answer: null } }) as unknown as NonNullable<FinancialDocumentImport['statement_review']>
  const upload = (id: number, revision: number, done: number) => ({ id, status: 'needs_review', transaction_drafts: [], metadata: { source_accounting_revision_id: revision }, statement_review: progress(done) }) as unknown as FinancialDocumentImport

  it('moves the status of each statement read back, and leaves the others as they are', () => {
    const open = upload(1, 88, 1)
    const other = upload(2, 99, 0)
    const untouched = upload(3, 77, 0)
    const legacy = { ...upload(4, 66, 0), statement_review: null }
    expect([open, other, untouched].map(uploadStatusLabel)).toEqual(['Some lines saved', 'Ready to review', 'Ready to review'])

    const ids = importIdsForRevisions([open, other, untouched, legacy], [99, 66])
    expect(ids).toEqual([2, 4])
    const after = withStatementProgress([open, other, untouched, legacy], new Map([[2, progress(4)], [4, progress(4)]]))
    expect(after.map(uploadStatusLabel)).toEqual(['Some lines saved', 'Saved', 'Ready to review', 'Ready to review'])
    expect(documentNeedsReview(after[1])).toBe(false)
    // Only its progress changes, so nothing reloads the review she has open.
    expect(after[0]).toBe(open)
    expect(after[3]).toBe(legacy)
    expect(withStatementProgress(after, new Map())).toBe(after)
  })
})
