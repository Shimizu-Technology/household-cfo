import { describe, expect, it } from 'vitest'
import { householdPlanKnown } from './householdMoneyKnown'

const input = (confirmed: string[], planned: number[] | undefined) => ({
  workspace: { setup_status: { confirmed_fields: confirmed } },
  budget: { annual_plan: planned === undefined ? undefined : { rows: planned.map((planned_total) => ({ planned_total })) } },
})

describe('householdPlanKnown', () => {
  it('is unknown before setup confirms the plan and no category has an amount', () => {
    expect(householdPlanKnown(input([], [0, 0]))).toBe(false)
    expect(householdPlanKnown(input(['primary_income'], undefined))).toBe(false)
    expect(householdPlanKnown(input(['fixed_expenses'], []))).toBe(false)
  })

  it('is known once setup confirmed both plan amounts, even if they are zero', () => {
    expect(householdPlanKnown(input(['fixed_expenses', 'flexible_spend'], [0]))).toBe(true)
  })

  it('is known when a plan came from Mia, an upload or category edits', () => {
    expect(householdPlanKnown(input([], [0, 25000]))).toBe(true)
  })
})
