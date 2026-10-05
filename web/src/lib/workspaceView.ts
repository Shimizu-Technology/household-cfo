import type { SetStateAction } from 'react'
import type { AppData, BudgetData, MiaActionDraft } from '../api'

export type WorkspaceMutation = { type: 'shared_financial_mutation'; update: SetStateAction<AppData | null> }
export type WorkspaceViewAction = SetStateAction<AppData | null> | WorkspaceMutation
export type WorkspaceView = { data: AppData | null; homeBudget: BudgetData | null; budgets: Record<number, BudgetData> }

// Browsing another budget year must not replace Home's current-period ledger.
// Retain that snapshot only for the same workspace; a fresh current-year payload
// replaces it, including confirmations and corrections.
export function workspaceViewReducer(state: WorkspaceView, action: WorkspaceViewAction): WorkspaceView {
  const invalidatesPlans = typeof action === 'object' && action !== null && 'type' in action && action.type === 'shared_financial_mutation'
  const update = invalidatesPlans ? action.update : action as SetStateAction<AppData | null>
  const data = typeof update === 'function' ? update(state.data) : update
  if (!data) return { data: null, homeBudget: null, budgets: {} }
  const sameWorkspace = state.data?.workspace.household_id === data.workspace.household_id
    && state.data?.workspace.mode === data.workspace.mode
    && state.data?.workspace.cohort?.id === data.workspace.cohort?.id
  const currentYear = data.dashboard.action_center.current_year
  const budgets = sameWorkspace && !invalidatesPlans ? { ...state.budgets } : {}
  if (data.budget.annual_plan) budgets[data.budget.annual_plan.year] = data.budget
  return { data, homeBudget: budgets[currentYear] ?? (sameWorkspace && state.homeBudget?.annual_plan?.year === currentYear ? state.homeBudget : null), budgets }
}

// Allocation edits belong to their budget year. Definitions and financial records
// can affect every year's income, debt minimums, category labels, or runway.
export function miaDraftChangesSharedFinancialRecords(draft: MiaActionDraft, itemIds?: number[]) {
  const selected = draft.items.filter(item => !item.applied_at && !item.canceled_at && (!itemIds || itemIds.includes(item.id)))
  return selected.some(item => item.action_type !== 'update_allocation' || (item.operation_key != null && !item.operation_key.startsWith('budget.allocation.')))
}
