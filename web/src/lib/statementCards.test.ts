import { describe, expect, it } from 'vitest'
import type { FinancialDocumentImport } from '../api'
import { monthsCovered, statementCardEntries } from './statementCards'

const NOW = Date.parse('2026-11-11T02:00:00Z')
const progress = (done: number, total = 27) => ({ total, done, spending: { read_count: 18, read_cents: 224965, counted_count: 0, counted_cents: 0 }, coverage: { question: null, answer: null } })
function item(id: number, over: Partial<FinancialDocumentImport> = {}): FinancialDocumentImport {
  return {
    id, household_id: 1, document_kind: 'statement', status: 'needs_review', filename: `statement-${id}.pdf`, content_type: 'application/pdf', byte_size: 10, document_date: null,
    period_start_on: '2026-09-01', period_end_on: '2026-09-30', extracted_summary: null, extraction_error: null, processed_at: '2026-11-10T20:00:00Z', applied_at: null, source_deleted_at: null,
    updated_at: '2026-11-10T20:00:00Z', source_available: true, details_included: true, uploaded_by: null, applied_by: null, source_deleted_by: null,
    metadata: { source_accounting_contract_version: 'source_accounting_v1', source_accounting_revision_id: id + 100 }, statement_review: progress(0), items: [], transaction_drafts: [], attempts: [],
    ...over,
  } as FinancialDocumentImport
}

describe('which statements get a card in the chat', () => {
  it('shows what is being read, what failed and what needs her, oldest first', () => {
    const entries = statementCardEntries([
      item(3), item(1, { status: 'processing', statement_review: null }), item(2, { status: 'failed', statement_review: null, extraction_error: 'Blurry' }),
    ], NOW)
    expect(entries.map((entry) => [entry.documentImport.id, entry.stage])).toEqual([[1, 'reading'], [2, 'failed'], [3, 'review']])
  })

  it('keeps a finished statement for two days and an open one for two weeks', () => {
    const approved = (updated: string) => item(5, { statement_review: progress(27), updated_at: updated, processed_at: updated })
    expect(statementCardEntries([approved('2026-11-10T20:00:00Z')], NOW).map((entry) => entry.stage)).toEqual(['approved'])
    expect(statementCardEntries([approved('2026-11-05T20:00:00Z')], NOW)).toEqual([])
    const open = (updated: string) => item(6, { updated_at: updated, processed_at: updated })
    expect(statementCardEntries([open('2026-10-30T20:00:00Z')], NOW).map((entry) => entry.stage)).toEqual(['review'])
    expect(statementCardEntries([open('2026-10-20T20:00:00Z')], NOW)).toEqual([])
  })

  it('leaves out other files, paused uploads and older reads that have no lines to review', () => {
    expect(statementCardEntries([
      item(1, { document_kind: 'receipt' }), item(2, { context_paused_by_restart: true }),
      item(3, { metadata: { source_accounting_contract_version: 'legacy_expense_only_v1' } as FinancialDocumentImport['metadata'], statement_review: null }),
    ], NOW)).toEqual([])
  })

  it('counts the months the statements cover, so Mia can say "your last 3 months"', () => {
    const month = (id: number, start: string, end: string) => item(id, { period_start_on: start, period_end_on: end })
    expect(monthsCovered([month(1, '2026-08-01', '2026-08-31'), month(2, '2026-09-01', '2026-09-30'), month(3, '2026-10-01', '2026-10-31')])).toBe(3)
    expect(monthsCovered([month(1, '2026-09-01', '2026-09-30'), month(2, '2026-09-01', '2026-09-30')])).toBe(1)
    expect(monthsCovered([month(1, '2026-11-20', '2027-01-05')])).toBe(3)
    expect(monthsCovered([item(1, { period_start_on: null, period_end_on: null, document_date: null })])).toBe(0)
  })
})
