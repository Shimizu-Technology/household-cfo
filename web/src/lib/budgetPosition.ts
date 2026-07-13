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

export type TransactionDraftBudgetImpact = {
  categoryId: number | null
  categoryName: string
  draftAmount: number
  planned: number | null
  actual: number | null
  otherPending: number
  projectedIfApproved: number | null
  remainingIfApproved: number | null
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

export function transactionDraftBudgetImpacts(
  plan: AnnualBudgetPlan,
  candidateDraft: TransactionDraft,
): TransactionDraftBudgetImpact[] {
  const monthIndex = plan.months.findIndex((month) => candidateDraft.occurred_on >= month.starts_on && candidateDraft.occurred_on <= month.ends_on)
  if (monthIndex < 0) return []

  const candidateAmounts = draftAmountsByCategory(candidateDraft)
  const otherPendingAmounts = new Map<number, number>()
  plan.pending_transaction_drafts.forEach((draft) => {
    if (draft.id === candidateDraft.id) return
    if (draft.occurred_on < plan.months[monthIndex].starts_on || draft.occurred_on > plan.months[monthIndex].ends_on) return
    draftAmountsByCategory(draft).forEach((amount, categoryId) => {
      if (categoryId === null) return
      otherPendingAmounts.set(categoryId, (otherPendingAmounts.get(categoryId) ?? 0) + amount.amount)
    })
  })

  return Array.from(candidateAmounts.entries()).map(([categoryId, allocation]) => {
    if (categoryId === null) {
      return {
        categoryId,
        categoryName: allocation.categoryName || 'Needs category',
        draftAmount: allocation.amount,
        planned: null,
        actual: null,
        otherPending: 0,
        projectedIfApproved: null,
        remainingIfApproved: null,
      }
    }

    const row = plan.rows.find((candidate) => candidate.id === categoryId)
    const cell = row?.months[monthIndex]
    if (!row || !cell) {
      return {
        categoryId,
        categoryName: allocation.categoryName || 'Unknown category',
        draftAmount: allocation.amount,
        planned: null,
        actual: null,
        otherPending: otherPendingAmounts.get(categoryId) ?? 0,
        projectedIfApproved: null,
        remainingIfApproved: null,
      }
    }

    const otherPending = otherPendingAmounts.get(categoryId) ?? 0
    const projectedIfApproved = cell.actual + otherPending + allocation.amount
    return {
      categoryId,
      categoryName: row.name,
      draftAmount: allocation.amount,
      planned: cell.planned,
      actual: cell.actual,
      otherPending,
      projectedIfApproved,
      remainingIfApproved: cell.planned - projectedIfApproved,
    }
  })
}

function draftAmountsByCategory(draft: TransactionDraft) {
  const amounts = new Map<number | null, { amount: number; categoryName: string | null }>()
  const splits = draft.splits?.filter((split) => split.amount > 0) ?? []
  if (splits.length > 0) {
    splits.forEach((split) => {
      const categoryId = split.budget_category_id ?? null
      const current = amounts.get(categoryId)
      amounts.set(categoryId, {
        amount: (current?.amount ?? 0) + split.amount,
        categoryName: split.category_name ?? current?.categoryName ?? null,
      })
    })
    return amounts
  }

  amounts.set(draft.category_id, { amount: draft.amount, categoryName: draft.category_name })
  return amounts
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
