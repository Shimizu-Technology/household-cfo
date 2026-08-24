import type { AnnualBudgetPlan } from '../api'
import { budgetPositionTotals, budgetPositionsForMonth } from '../lib/budgetPosition'
import { addMoney, subtractMoney } from '../lib/moneyMath'
import { CategoryPressureList, MonthPlanSummary } from './BudgetVisuals'

type ActivityPreviewProps = {
  plan: AnnualBudgetPlan
  monthIndex: number
  onOpenBudget: () => void
  onAskMia: () => void
}

export function ActivityPreview({ plan, monthIndex, onOpenBudget, onAskMia }: ActivityPreviewProps) {
  const safeMonthIndex = Math.max(0, Math.min(plan.months.length - 1, monthIndex))
  const month = plan.months[safeMonthIndex]
  const positions = budgetPositionsForMonth(plan, safeMonthIndex)
  const totals = budgetPositionTotals(positions)
  const income = plan.monthly_income[month.id] ?? 0
  const baselineSurplus = subtractMoney(income, addMoney(totals.planned, plan.monthly_debt_minimums))

  return (
    <article className="panel activity-preview" aria-labelledby="activity-preview-title">
      <div className="activity-preview-heading">
        <div>
          <p className="eyebrow">Preview operating view</p>
          <h3 id="activity-preview-title">See the month without inventing a transaction history.</h3>
          <p>This demo shows the monthly plan and any demo-safe category actuals. It has no confirmed merchant ledger, so missing activity is never presented as $0 spending.</p>
        </div>
        <span>Demo-safe data</span>
      </div>

      <MonthPlanSummary
        label={`${month.label} ${plan.year}`}
        income={income}
        planned={totals.planned}
        actual={totals.actual}
        pending={0}
        baselineSurplus={baselineSurplus}
        debtMinimums={plan.monthly_debt_minimums}
      />

      <CategoryPressureList
        positions={positions}
        limit={5}
        eyebrow={`${month.label} category view`}
        title="Where the plan needs attention"
      />

      <div className="activity-preview-actions">
        <button type="button" onClick={onOpenBudget}>Open the monthly plan</button>
        <button type="button" className="secondary-button" onClick={onAskMia}>Ask Mia about a spending decision</button>
      </div>
    </article>
  )
}
