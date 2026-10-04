import { describe, expect, it } from 'vitest'
import type { FinancialDocumentImport } from '../api'
import { sourceReviewFixture } from '../../e2e/sourceReviewFixtures'
import { sourceEventLabel, sourceMoney, sourceReviewMode, validateSourceReview } from './sourceReview'

describe('statement review accounting contract', () => {
  it('requires explicit supported typed metadata; preserves expense-only imports', () => {
    const document = (metadata: FinancialDocumentImport['metadata']) => ({ metadata }) as FinancialDocumentImport
    expect(sourceReviewMode(document({}))).toBe('legacy')
    expect(sourceReviewMode(document({ source_accounting_contract_version: 'legacy_expense_only_v1' }))).toBe('legacy')
    expect(sourceReviewMode(document({ source_accounting_contract_version: 'source_accounting_v1', source_accounting_revision_id: 88 }))).toBe('typed')
    expect(sourceReviewMode(document({ source_accounting_contract_version: 'source_accounting_v2', source_accounting_revision_id: 88 }))).toBe('unsupported')
    expect(sourceReviewMode(document({ source_accounting_contract_version: 'source_accounting_v1' }))).toBe('unsupported')
  })
  it('does not turn unknown, informational or refund values into positive expense amounts', () => {
    const data = sourceReviewFixture()
    expect(sourceMoney(null)).toBe('Unknown')
    expect(sourceMoney(0)).toBe('$0.00')
    expect(sourceMoney(3000, true)).toBe('+$30.00')
    expect(sourceEventLabel(data.events[0])).toBe('Refund · inflow')
    expect(sourceEventLabel(data.events[2])).toBe('Card / debt payment · outflow')
    expect(sourceEventLabel(sourceReviewFixture(1, 'informational').events[0])).toContain('excluded')
  })
  it('verifies each immutable page and rejects wrong revisions, omissions, duplicate rows and incorrect filters', () => {
    expect(() => validateSourceReview(sourceReviewFixture(3), 1203, 88, 3, 'all')).not.toThrow()
    const wrong = sourceReviewFixture(); wrong.revision.id = 89
    expect(() => validateSourceReview(wrong, 1203, 88, 1, 'all')).toThrow('changed')
    const omitted = sourceReviewFixture(); omitted.events.pop()
    expect(() => validateSourceReview(omitted, 1203, 88, 1, 'all')).toThrow('coverage')
    const duplicate = sourceReviewFixture(); duplicate.events[1] = duplicate.events[0]
    expect(() => validateSourceReview(duplicate, 1203, 88, 1, 'all')).toThrow('requested')
    const filter = sourceReviewFixture(1, 'unresolved'); filter.events[0].row_kind = 'posted'
    expect(() => validateSourceReview(filter, 1203, 88, 1, 'unresolved')).toThrow('requested')
  })
})
