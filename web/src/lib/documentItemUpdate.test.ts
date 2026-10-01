import { describe, expect, it } from 'vitest'
import { changedDebtMoneyInputs, changedInterestRateInput } from './documentItemUpdate'

describe('changedInterestRateInput', () => {
  it('omits unchanged APR values so unrelated corrections cannot overwrite the saved debt APR', () => {
    expect(changedInterestRateInput(24.99, '24.99')).toEqual({})
    expect(changedInterestRateInput(null, '')).toEqual({})
  })

  it('sends explicit APR changes and clears', () => {
    expect(changedInterestRateInput(24.99, '19.75')).toEqual({ interest_rate_percent: '19.75' })
    expect(changedInterestRateInput(24.99, '')).toEqual({ interest_rate_percent: null })
    expect(changedInterestRateInput(null, '19.75')).toEqual({ interest_rate_percent: '19.75' })
  })
})

describe('changedDebtMoneyInputs', () => {
  it('keeps payment-only and balance-only corrections truthful', () => {
    expect(changedDebtMoneyInputs(null, 75, '', '75')).toEqual({ payment: '75' })
    expect(changedDebtMoneyInputs(1800, null, '1800', '')).toEqual({ balance: '1800' })
  })

  it('does not submit unknown placeholders as blank money values', () => {
    expect(changedDebtMoneyInputs(null, null, '  ', '')).toEqual({})
  })

  it('sends an explicit unknown when a known value is cleared', () => {
    expect(changedDebtMoneyInputs(1800, 75, '', '75')).toEqual({ balance: null, payment: '75' })
    expect(changedDebtMoneyInputs(1800, 75, '1800', '')).toEqual({ balance: '1800', payment: null })
  })
})
