import { describe, expect, it } from 'vitest'
import { changedInterestRateInput } from './documentItemUpdate'

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
