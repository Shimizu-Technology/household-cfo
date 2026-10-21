import type { BudgetData, DashboardData, ReadinessMilestone } from '../api'
import { AnnualCashFlowChart, MonthPlanSummary } from './BudgetVisuals'
import { budgetPositionsForMonth, budgetPositionTotals } from '../lib/budgetPosition'
import { Button } from './Button'
import { useBrand } from '../contexts/brandContextValue'

const currency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })

type HomeScreenProps = {
  dashboard: DashboardData
  budget: BudgetData
  onAskMia: () => void
  onReviewTransactions: () => void
  onReviewMiaActions: () => void
  pendingImportCount: number
  onReviewImports: () => void
  onOpenDebt?: () => void
  onOpenBudget?: () => void
  incomeKnown?: boolean
  planKnown?: boolean
}

export function HomeScreen({ dashboard, budget, onAskMia, onReviewTransactions, onReviewMiaActions, pendingImportCount, onReviewImports, onOpenBudget, incomeKnown = true, planKnown = true }: HomeScreenProps) {
  const { assistantName } = useBrand()
  const actionCenter = dashboard.action_center
  const plan = budget.annual_plan?.year === actionCenter.current_year ? budget.annual_plan : null
  const monthIndex = Math.max(0, Math.min(11, actionCenter.current_month_index))
  const totals = budgetPositionTotals(plan ? budgetPositionsForMonth(plan, monthIndex) : [])
  const month = plan?.months[monthIndex]
  const income = month ? plan?.monthly_income[month.id] ?? dashboard.summary.monthly_income : dashboard.summary.monthly_income
  const spike = plan?.annual_outlook.upcoming_spikes[0]
  const purchaseCount = actionCenter.transaction_review_count

  return (
    <section className="screen-grid home-screen">
      <div className="screen-heading home-heading">
        <h2 data-page-heading tabIndex={-1}>Home</h2>
        <p>{actionCenter.current_month_label} {actionCenter.current_year}</p>
      </div>
      {plan ? <MonthPlanSummary compact label={`${actionCenter.current_month_label} ${actionCenter.current_year}`} income={income} planned={totals.planned} actual={totals.actual} pending={totals.pending} debtMinimums={plan.monthly_debt_minimums} debtMinimumsKnown={plan.monthly_debt_minimums_known !== false} incomeKnown={incomeKnown} planKnown={planKnown} /> : <p role="status">Your current plan could not be loaded. This does not mean spending is zero.</p>}
      <div className="home-next-action">
        <Button onClick={purchaseCount > 0 ? onReviewTransactions : onAskMia}>{purchaseCount > 0 ? `Review ${purchaseCount} purchase${purchaseCount === 1 ? '' : 's'}` : `Tell ${assistantName} what changed`}</Button>
      </div>
      {plan && <section className="home-financial-visuals" aria-label="Your year outlook">
        <AnnualCashFlowChart plan={plan} compact selectedMonthIndex={monthIndex} moneyKnown={incomeKnown && planKnown && plan.monthly_debt_minimums_known !== false} />
        {incomeKnown && planKnown && spike && <p className="home-year-note"><strong>{spike.label}: {currency.format(spike.planned_outflow)} planned out.</strong> {spike.amount_above_typical != null && `${currency.format(spike.amount_above_typical)} above a typical month.`}</p>}
      </section>}
      <p className="home-plan-link"><button type="button" className="text-button" onClick={onOpenBudget}>Plan details →</button></p>
      <div className="home-readiness-line">
        <span>Readiness: {dashboard.summary.readiness_label}</span>
        <details className="home-readiness-details">
          <summary>Readiness details</summary>
          <p>Red: protect the basics. Yellow: build your cash cushion. Green: your target cushion and a positive monthly balance are in place.</p>
          {dashboard.readiness_path.available === false ? <p>{dashboard.readiness_path.unavailable_reason}</p> : <div className="readiness-milestone-grid"><ReadinessMilestoneCard label="Yellow checkpoint" milestone={dashboard.readiness_path.yellow} /><ReadinessMilestoneCard label="Green target" milestone={dashboard.readiness_path.green} /></div>}
        </details>
      </div>
      {(pendingImportCount > 0 || actionCenter.mia_action_review_count > 0) && <div className="home-other-reviews">
        {pendingImportCount > 0 && <button type="button" className="text-button" onClick={onReviewImports}>{pendingImportCount} file{pendingImportCount === 1 ? '' : 's'} waiting for review</button>}
        {actionCenter.mia_action_review_count > 0 && <button type="button" className="text-button" onClick={onReviewMiaActions}>{actionCenter.mia_action_review_count} {assistantName} change{actionCenter.mia_action_review_count === 1 ? '' : 's'} waiting for review</button>}
      </div>}
    </section>
  )
}

function ReadinessMilestoneCard({ label, milestone }: { label: string; milestone: ReadinessMilestone }) {
  return (
    <article className={`readiness-milestone-card ${milestone.tone} ${milestone.reached ? 'reached' : ''}`}>
      <div className="readiness-milestone-title">
        <span>{label}</span>
        <b>{milestone.reached ? 'Reached' : 'Building'}</b>
      </div>
      <strong title={currency.format(milestone.protected_liquid_target)}>{currency.format(milestone.protected_liquid_target)}</strong>
      <p>Protected liquid runway for {milestone.runway_months} months.</p>
      <dl>
        <div>
          <dt>Still to protect</dt>
          <dd>{milestone.protected_liquid_gap > 0 ? currency.format(milestone.protected_liquid_gap) : '$0.00 — threshold protected'}</dd>
        </div>
        <div>
          <dt>Cash-flow rule</dt>
          <dd>{milestone.cash_flow_requirement}</dd>
        </div>
      </dl>
    </article>
  )
}
