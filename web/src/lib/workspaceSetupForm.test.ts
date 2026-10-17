import { describe, expect, it } from 'vitest'
import { changedWorkspaceSetupValues, moneyInputProblem } from './workspaceSetupForm'

describe('changedWorkspaceSetupValues', () => {
  const baseline = {
    household_name: 'Cruz Household', primary_goal: 'Build runway', fixed_expenses: 2_400, flexible_spend: 1_020,
    expected_sinking_fund: 0, unexpected_sinking_fund: 0, emergency_fund: null, other_assets: 500, target_runway_months: 6,
  }

  it('sends only the goal when only the goal changed, never the untouched group totals', () => {
    expect(changedWorkspaceSetupValues({ ...baseline, primary_goal: 'Pay down the card' }, baseline)).toEqual({ primary_goal: 'Pay down the card' })
  })

  it('treats equal amounts and whitespace-only differences as unchanged', () => {
    expect(changedWorkspaceSetupValues({ ...baseline, flexible_spend: 1020.0, household_name: ' Cruz  Household ' }, baseline)).toEqual({})
  })

  it('keeps a sub-cent entry against a zero baseline so it can be validated, not dropped', () => {
    const changed = changedWorkspaceSetupValues({ ...baseline, expected_sinking_fund: 0.001 }, baseline)
    expect(changed).toEqual({ expected_sinking_fund: 0.001 })
    expect(moneyInputProblem('Expected sinking fund', '0.001')).toBe('Expected sinking fund: use no more than two decimal places (cents), like 1250.50.')
  })

  it('keeps a cleared optional balance and a changed amount', () => {
    expect(changedWorkspaceSetupValues({ ...baseline, other_assets: null, fixed_expenses: 2_450.5 }, baseline)).toEqual({ other_assets: null, fixed_expenses: 2_450.5 })
  })
})

describe('moneyInputProblem', () => {
  it('accepts blank, whole dollars, and cents', () => {
    expect(moneyInputProblem('Fixed essentials', '')).toBeNull()
    expect(moneyInputProblem('Fixed essentials', '1234')).toBeNull()
    expect(moneyInputProblem('Fixed essentials', '1234.56')).toBeNull()
    expect(moneyInputProblem('Fixed essentials', '9999999.99')).toBeNull()
  })

  it('explains extra decimals, non-numbers, and too-large amounts in plain words', () => {
    expect(moneyInputProblem('Fixed essentials', '12.345')).toBe('Fixed essentials: use no more than two decimal places (cents), like 1250.50.')
    expect(moneyInputProblem('Fixed essentials', '1e5')).toBe('Fixed essentials: enter a dollar amount using numbers only, like 1250 or 1250.50.')
    expect(moneyInputProblem('Fixed essentials', '999999999999999')).toBe('Fixed essentials must be $9,999,999.99 or less.')
  })
})
