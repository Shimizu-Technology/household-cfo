import type { AnnualBudgetPlan, DashboardData } from '../api'

/** Shared with the explanatory copy so an unknown figure never gets a known-total claim. */
export function plannedOutForMonth(plan: AnnualBudgetPlan, monthIndex: number, planKnown: boolean, confirmedFields: string[] = [], answer?: DashboardData['month_answer']) {
  if (answer) return answer.planned_out_cents == null ? null : answer.planned_out_cents / 100
  const month = plan.months[monthIndex]
  const outlook = plan.annual_outlook.months.find(candidate => candidate.period_id === month?.id)
  const costsKnown = (['fixed_expenses', 'flexible_spend'] as const).every((field, index) => confirmedFields.includes(field) || plan.rows.some(row => row.active && row.stack_key === (index === 0 ? 'non_discretionary' : 'discretionary')))
  const amountsKnown = plan.rows.every(row => !row.active || (row.months[monthIndex] && !row.months[monthIndex].allocation_missing))
  return plan.plan_available !== false && planKnown && costsKnown && amountsKnown && plan.monthly_debt_minimums_known !== false ? outlook?.planned_outflow ?? null : null
}

