import { describe, expect, it } from 'vitest'
import { budgetMonthsFromPayload, proposedMoney, proposedText } from './miaManualPrefill'

describe('Mia manual editor prefills', () => {
  it('derives exact months from authoritative allocation changes', () => {
    expect(budgetMonthsFromPayload({
      category_id: 2,
      year: 2026,
      changes: [
        { month: 1, allocation_id: 10, after_cents: 50_000 },
        { month: 2, allocation_id: 11, after_cents: 45_000 },
      ],
    })).toEqual([1, 2])
  })

  it('preserves absent values and treats explicit null or unknown as blank', () => {
    expect(proposedText({}, 'target_on', '2028-05-01')).toBe('2028-05-01')
    expect(proposedText({ target_on: null }, 'target_on', '2028-05-01')).toBe('')
    expect(proposedMoney({}, 'balance_cents', '900', 'balance_known')).toBe('900')
    expect(proposedMoney({ balance_known: false, balance_cents: 0 }, 'balance_cents', '900', 'balance_known')).toBe('')
    expect(proposedMoney({ balance_cents: null }, 'balance_cents', '900', 'balance_known')).toBe('')
  })
})
