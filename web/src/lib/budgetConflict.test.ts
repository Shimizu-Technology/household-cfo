import { describe, expect, it } from 'vitest'
import { changedElsewhereMessage, latestAllocation } from './budgetConflict'
import type { AnnualBudgetPlan } from '../api'

describe('budget conflict helpers', () => {
  it('keeps the typed value and names the latest one', () => {
    expect(changedElsewhereMessage({ rowName: 'Dining out', latest: '$180', mine: '$190', savedCount: 0 }))
      .toBe('Dining out changed in another tab — the latest is $180; your value $190 is kept, save again to apply.')
  })

  it('says how many earlier rows were saved', () => {
    expect(changedElsewhereMessage({ rowName: 'Dining out', latest: '$180', mine: '$190', savedCount: 2 })).toContain('2 earlier changes were saved')
  })

  it('finds the latest planned amount for an allocation', () => {
    const plan = { rows: [{ id: 1, name: 'Dining out', months: [{ allocation_id: 7, planned: 180 }] }] } as unknown as AnnualBudgetPlan
    expect(latestAllocation(plan, 7)).toEqual({ rowName: 'Dining out', planned: 180 })
    expect(latestAllocation(plan, 8)).toBeNull()
  })
})
