import type { SetStateAction } from 'react'
import type { AppData, BudgetData } from '../api'

export type WorkspaceView = { data: AppData | null; homeBudget: BudgetData | null; budgets: Record<number, BudgetData> }

// Browsing another budget year must not replace Home's current-period ledger.
// Retain that snapshot only for the same workspace; a fresh current-year payload
// replaces it, including confirmations and corrections.
export function workspaceViewReducer(state: WorkspaceView, action: SetStateAction<AppData | null>): WorkspaceView {
  const data = typeof action === 'function' ? action(state.data) : action
  if (!data) return { data: null, homeBudget: null, budgets: {} }
  const sameWorkspace = state.data?.workspace.household_id === data.workspace.household_id
    && state.data?.workspace.mode === data.workspace.mode
  const currentYear = data.dashboard.action_center.current_year
  const budgets = sameWorkspace ? { ...state.budgets } : {}
  if (data.budget.annual_plan) budgets[data.budget.annual_plan.year] = data.budget
  return { data, homeBudget: budgets[currentYear] ?? null, budgets }
}
