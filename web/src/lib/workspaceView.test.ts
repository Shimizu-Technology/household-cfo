import { describe, expect, it } from 'vitest'
import type { AppData, MiaActionDraft } from '../api'
import { miaDraftChangesSharedFinancialRecords, sameOptionalMoneyValue, workspaceViewReducer } from './workspaceView'

function workspace(year: number, householdId = 1, actual = 25): AppData {
  return {
    workspace: { household_id: householdId, mode: 'real' },
    dashboard: { action_center: { current_year: 2026 } },
    budget: { annual_plan: { year, rows: [{ months: [{ actual }] }] } },
  } as unknown as AppData
}

describe('current Home snapshot', () => {
  it('keeps current actuals while browsing earlier and later budgets', () => {
    const current = workspace(2026)
    const initial = workspaceViewReducer({ data: null, homeBudget: null, budgets: {} }, current)
    const future = workspaceViewReducer(initial, (data) => ({ ...data!, budget: workspace(2027, 1, 0).budget }))
    expect(future.data?.budget.annual_plan?.year).toBe(2027)
    expect(future.homeBudget).toBe(current.budget)
    const past = workspaceViewReducer(future, (data) => ({ ...data!, budget: workspace(2025, 1, 0).budget }))
    expect(past.homeBudget?.annual_plan?.rows[0].months[0].actual).toBe(25)
  })

  it('replaces the snapshot after confirmation or correction', () => {
    const initial = workspaceViewReducer({ data: null, homeBudget: null, budgets: {} }, workspace(2026))
    const corrected = workspaceViewReducer(initial, workspace(2026, 1, 90))
    expect(corrected.homeBudget?.annual_plan?.rows[0].months[0].actual).toBe(90)
    const future = workspaceViewReducer(corrected, workspace(2027, 1, 10))
    const refresh = workspaceViewReducer(future, workspace(2026, 1, 95))
    expect(refresh.budgets[2027].annual_plan?.rows[0].months[0].actual).toBe(10)
    expect(refresh.homeBudget?.annual_plan?.rows[0].months[0].actual).toBe(95)
  })

  it('does not retain another household or an obsolete calendar year', () => {
    const initial = workspaceViewReducer({ data: null, homeBudget: null, budgets: {} }, workspace(2026))
    expect(workspaceViewReducer(initial, workspace(2027, 2)).homeBudget).toBeNull()
    const nextYear = workspace(2025)
    nextYear.dashboard.action_center.current_year = 2027
    expect(workspaceViewReducer(initial, nextYear).homeBudget).toBeNull()
    expect(workspaceViewReducer(initial, null)).toEqual({ data: null, homeBudget: null, budgets: {} })
  })
})


describe('shared financial mutation cache', () => {
  it('invalidates other cached plans while preserving Home until its canonical refresh arrives', () => {
    const current = workspace(2026)
    let state = workspaceViewReducer({ data: null, homeBudget: null, budgets: {} }, current)
    state = workspaceViewReducer(state, workspace(2027, 1, 0))
    state = workspaceViewReducer(state, workspace(2025, 1, 0))
    const updatedSelected = workspace(2027, 1, 40)
    state = workspaceViewReducer(state, { type: 'shared_financial_mutation', update: updatedSelected })
    expect(Object.keys(state.budgets)).toEqual(['2027'])
    expect(state.homeBudget).toBe(current.budget)
    const refreshedCurrent = workspace(2026, 1, 95)
    state = workspaceViewReducer(state, refreshedCurrent)
    expect(state.homeBudget).toBe(refreshedCurrent.budget)
    expect(state.budgets[2027]).toBe(updatedSelected.budget)
    expect(state.budgets[2025]).toBeUndefined()
  })

  it('does not reuse another program’s cached review queues for the same household', () => {
    const first = workspace(2026)
    first.workspace.cohort = { id: 41 } as NonNullable<AppData['workspace']['cohort']>
    let state = workspaceViewReducer({ data: null, homeBudget: null, budgets: {} }, first)
    state = workspaceViewReducer(state, { ...first, budget: workspace(2027).budget })
    const second = { ...first, workspace: { ...first.workspace, cohort: { ...first.workspace.cohort!, id: 42 } } }
    state = workspaceViewReducer(state, second)
    expect(state.budgets[2027]).toBeUndefined()
    expect(state.homeBudget).toBe(second.budget)
  })

  it('limits Mia invalidation to the selected unapplied shared operations', () => {
    const draft = { items: [
      { id: 1, action_type: 'update_allocation', operation_key: 'budget.allocation.set' },
      { id: 2, action_type: 'update_income_source', operation_key: 'income.source.update' },
      { id: 3, action_type: 'update_debt', applied_at: '2026-10-06' },
    ] } as unknown as MiaActionDraft
    expect(miaDraftChangesSharedFinancialRecords(draft, [1])).toBe(false)
    expect(miaDraftChangesSharedFinancialRecords(draft, [2])).toBe(true)
    expect(miaDraftChangesSharedFinancialRecords(draft)).toBe(true)
    expect(miaDraftChangesSharedFinancialRecords(draft, [3])).toBe(false)
  })
})


describe('committed changes with partial refresh failure', () => {
  it('invalidates all old year caches immediately and marks retained Home stale', () => {
    let state = workspaceViewReducer({ data: null, homeBudget: null, budgets: {} }, workspace(2026))
    state = workspaceViewReducer(state, workspace(2027))
    const priorHome = state.homeBudget
    state = workspaceViewReducer(state, { type: 'shared_financial_commit' })
    expect(state.budgets).toEqual({})
    expect(state.homeBudget).toBe(priorHome)
    expect(state.homeBudgetStale).toBe(true)
    expect(state.dataBudgetStale).toBe(true)
    // Nonfinancial state updates cannot accidentally revalidate the old payload.
    state = workspaceViewReducer(state, current => ({ ...current! }))
    expect(state.budgets).toEqual({})
    expect(state.homeBudgetStale).toBe(true)
    expect(state.dataBudgetStale).toBe(true)
  })

  it('retains a successful current refresh when the selected future reload fails', () => {
    let state = workspaceViewReducer({ data: null, homeBudget: null, budgets: {} }, workspace(2026))
    state = workspaceViewReducer(state, workspace(2027))
    state = workspaceViewReducer(state, { type: 'shared_financial_commit' })
    const current = workspace(2026, 1, 95)
    state = workspaceViewReducer(state, current)
    expect(state.homeBudget).toBe(current.budget)
    expect(state.homeBudgetStale).toBe(false)
    expect(state.dataBudgetStale).toBe(false)
    expect(state.budgets[2027]).toBeUndefined()
  })

  it('keeps Home marked stale if only a future plan reload succeeds', () => {
    let state = workspaceViewReducer({ data: null, homeBudget: null, budgets: {} }, workspace(2026))
    state = workspaceViewReducer(state, { type: 'shared_financial_commit' })
    state = workspaceViewReducer(state, workspace(2027, 1, 95))
    expect(state.homeBudgetStale).toBe(true)
    expect(state.dataBudgetStale).toBe(false)
    expect(Object.keys(state.budgets)).toEqual(['2027'])
  })
})


it('compares summary money numerically while preserving unknown versus zero', () => {
  expect(sameOptionalMoneyValue('150.00', '150')).toBe(true)
  expect(sameOptionalMoneyValue('25.50', '25.5')).toBe(true)
  expect(sameOptionalMoneyValue(' ', '')).toBe(true)
  expect(sameOptionalMoneyValue('', '0')).toBe(false)
  expect(sameOptionalMoneyValue('0.00', '0')).toBe(true)
  expect(sameOptionalMoneyValue('25.51', '25.5')).toBe(false)
})
