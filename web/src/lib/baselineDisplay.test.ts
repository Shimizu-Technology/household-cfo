import { describe, expect, it } from 'vitest'
import { uniqueBaselineAccountLabels } from './baselineDisplay'

describe('baseline statement account labels', () => {
  it('deduplicates only identical fragments while retaining account and period distinctions', () => {
    const account = { tracked_account_id: 1, label: 'Card ending 1234', period_start_on: '2026-08-01', period_end_on: '2026-08-31' }
    const secondAccount = { ...account, tracked_account_id: 2 }
    const secondPeriod = { ...account, period_start_on: '2026-09-01', period_end_on: '2026-09-30' }
    const correctedLabel = { ...account, label: 'Renamed card' }
    const original = [account, { ...account }, secondAccount, secondPeriod, correctedLabel]
    expect(uniqueBaselineAccountLabels(original)).toEqual([account, secondAccount, secondPeriod, correctedLabel])
    expect(original).toHaveLength(5)
  })
})
