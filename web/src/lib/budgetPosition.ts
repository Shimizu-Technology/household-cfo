import type {
  AnnualBudgetPlan,
  BudgetMonth,
  BudgetStackKey,
  SpendingReport,
  TransactionDraft,
} from '../api'

export type BudgetPosition = {
  id: number
  name: string
  stackKey: BudgetStackKey
  stackLabel: string
  planned: number
  actual: number
  pending: number
  remaining: number
  active: boolean
}

export type BudgetPositionTotals = {
  planned: number
  actual: number
  pending: number
  remaining: number
}

export function budgetPositionsForMonth(
  plan: AnnualBudgetPlan,
  monthIndex: number,
  spendingReport?: SpendingReport | null,
): BudgetPosition[] {
  const month = plan.months[monthIndex]
  const reportMatchesMonth = Boolean(
    spendingReport && month && spendingReport.start_on === month.starts_on && spendingReport.end_on === month.ends_on,
  )

  if (spendingReport && reportMatchesMonth) {
    return spendingReport.categories.map((category) => ({
      id: category.id,
      name: category.name,
      stackKey: category.stack_key,
      stackLabel: category.stack_label,
      planned: category.planned,
      actual: category.actual,
      pending: category.pending,
      remaining: category.remaining,
      active: category.active ?? true,
    }))
  }

  const pendingByCategory = pendingAmountsByCategory(plan.pending_transaction_drafts, month)

  return plan.rows.map((row) => {
    const cell = row.months[monthIndex]
    return {
      id: row.id,
      name: row.name,
      stackKey: row.stack_key,
      stackLabel: row.stack_label,
      planned: cell?.planned ?? 0,
      actual: cell?.actual ?? 0,
      pending: pendingByCategory.get(row.id) ?? 0,
      remaining: cell?.remaining ?? (cell?.planned ?? 0) - (cell?.actual ?? 0),
      active: row.active,
    }
  })
}

export function budgetPositionTotals(positions: BudgetPosition[]): BudgetPositionTotals {
  return positions.reduce((totals, position) => ({
    planned: totals.planned + position.planned,
    actual: totals.actual + position.actual,
    pending: totals.pending + position.pending,
    remaining: totals.remaining + position.remaining,
  }), { planned: 0, actual: 0, pending: 0, remaining: 0 })
}

function pendingAmountsByCategory(drafts: TransactionDraft[], month?: BudgetMonth) {
  const totals = new Map<number, number>()
  if (!month) return totals

  drafts.forEach((draft) => {
    if (draft.occurred_on < month.starts_on || draft.occurred_on > month.ends_on) return

    const categorizedSplits = draft.splits?.filter((split) => split.budget_category_id) ?? []
    if (categorizedSplits.length > 0) {
      categorizedSplits.forEach((split) => {
        const categoryId = split.budget_category_id!
        totals.set(categoryId, (totals.get(categoryId) ?? 0) + split.amount)
      })
      return
    }

    if (draft.category_id) totals.set(draft.category_id, (totals.get(draft.category_id) ?? 0) + draft.amount)
  })

  return totals
}
