import { describe, expect, it } from 'vitest'
import { firstSetupHasUnsavedChanges, refreshSetupDraft } from './firstSetupDraft'

const saved = { household_name: 'Cruz', primary_goal: '', primary_income: '', fixed_expenses: '', flexible_spend: '' }

describe('firstSetupHasUnsavedChanges', () => {
  it('does not warn before any edit', () => {
    expect(firstSetupHasUnsavedChanges({ ...saved }, saved)).toBe(false)
  })
  it('warns after an edit', () => {
    expect(firstSetupHasUnsavedChanges({ ...saved, primary_income: '3500' }, saved)).toBe(true)
  })
  it('stops warning once the saved values match the draft', () => {
    const afterSave = { ...saved, primary_income: '3500' }
    expect(firstSetupHasUnsavedChanges({ ...afterSave }, afterSave)).toBe(false)
  })
})

it('refreshes untouched setup fields from chat approvals and preserves unsaved input', () => {
  const before = { household_name: 'Household', primary_income: '', primary_goal: '', fixed_expenses: '', flexible_spend: '' }
  const current = { ...before, primary_goal: 'My unsaved goal' }
  const approved = { ...before, primary_income: '5200', fixed_expenses: '2050', flexible_spend: '700' }
  expect(refreshSetupDraft(current, before, approved)).toEqual({ ...approved, primary_goal: 'My unsaved goal' })
  expect(refreshSetupDraft(null, before, approved)).toEqual(approved)
})
