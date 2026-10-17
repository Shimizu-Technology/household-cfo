import { describe, expect, it } from 'vitest'
import { firstSetupHasUnsavedChanges } from './firstSetupDraft'

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
