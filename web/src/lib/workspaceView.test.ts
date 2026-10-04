import { describe, expect, it } from 'vitest'
import type { AppData } from '../api'
import { workspaceViewReducer } from './workspaceView'

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
