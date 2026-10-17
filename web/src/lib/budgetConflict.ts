import type { AnnualBudgetPlan } from '../api'

/**
 * Message for a budget save the API rejected because another tab or device
 * changed the same value first. The person's typed value is kept; they save
 * again to apply it on top of the latest numbers.
 */
export function changedElsewhereMessage({ rowName, latest, mine, savedCount }: {
  rowName: string
  latest: string
  mine: string
  savedCount: number
}) {
  const saved = savedCount > 0
    ? ` ${savedCount} earlier ${savedCount === 1 ? 'change was' : 'changes were'} saved; the rest were not.`
    : ''
  return `${rowName} changed in another tab — the latest is ${latest}; your value ${mine} is kept, save again to apply.${saved}`
}

export function latestAllocation(plan: AnnualBudgetPlan | undefined, allocationId: number) {
  for (const row of plan?.rows ?? []) {
    const month = row.months.find((candidate) => candidate.allocation_id === allocationId)
    if (month) return { rowName: row.name, planned: month.planned }
  }
  return null
}

export function latestCategory(plan: AnnualBudgetPlan | undefined, categoryId: number) {
  return plan?.rows.find((row) => row.id === categoryId) ?? null
}
