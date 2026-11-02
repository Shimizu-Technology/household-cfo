import type { BudgetData, DashboardData } from '../api'
import { YearOutlook } from './YearOutlook'
import { formatReviewMoney } from '../lib/reviewMoney'
import { Button } from './Button'
import { useBrand } from '../contexts/brandContextValue'

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
  canAskMia?: boolean
  canReviewTransactions?: boolean
}

export function HomeScreen({ dashboard, budget, onAskMia, onReviewTransactions, onReviewMiaActions, pendingImportCount, onReviewImports, onOpenBudget, incomeKnown = true, planKnown = true, canAskMia = true, canReviewTransactions = true }: HomeScreenProps) {
  const { assistantName } = useBrand()
  const { action_center: actionCenter, month_answer: answer } = dashboard
  const plan = budget.annual_plan?.year === actionCenter.current_year ? budget.annual_plan : null
  const left = answer?.plan_left_cents
  const purchaseCount = canReviewTransactions ? actionCenter.transaction_review_count : 0
  return <section className="screen-grid home-screen">
    <div className="screen-heading home-heading">
      <h2 data-page-heading tabIndex={-1}>Home</h2>
      <p>{actionCenter.current_month_label}{actionCenter.current_year !== new Date().getFullYear() ? ` ${actionCenter.current_year}` : ''}</p>
    </div>
    <section className="home-month-answer" aria-label="Your month in money">
      <dl className="home-money-values">
        <MoneyValue label="Money in" cents={answer?.money_in_cents} />
        <MoneyValue label="Money out · planned" cents={answer?.planned_out_cents} />
        <MoneyValue label={left != null && left < 0 ? 'Short of the plan' : 'What’s left · planned'} cents={left == null ? left : Math.abs(left)} />
      </dl>
      <p>{left == null ? 'Add the missing income or planned costs to see what’s left.' : 'After planned costs and debt minimums. This is your plan, not your bank balance.'}</p>
      <p className="home-spent">Spent so far: <strong>{answer?.spent_so_far_cents == null ? 'Not known yet' : formatReviewMoney(answer.spent_so_far_cents)}</strong> · confirmed category purchases</p>
      {answer && answer.pending_count == null && <p>More purchases may be waiting. Check Review before your next money decision.</p>}
    </section>
    {(purchaseCount > 0 || canAskMia) && <div className="home-next-action"><Button onClick={purchaseCount > 0 ? onReviewTransactions : onAskMia}>{purchaseCount > 0 ? `Review ${purchaseCount} purchase${purchaseCount === 1 ? '' : 's'}` : `Tell ${assistantName} what changed`}</Button></div>}
    <section className="home-cushion" aria-label="Your emergency cushion">
      <h3>{answer?.runway_months == null ? 'Your emergency cushion' : `${new Intl.NumberFormat('en-US', { maximumFractionDigits: 1 }).format(answer.runway_months)} months of breathing room`}</h3>
      <p>{answer?.readiness_guidance ?? 'Add the missing starting numbers before judging your cushion.'}</p>
      {answer?.runway_months != null && <p>Goal: {dashboard.readiness_path.target_runway_months} months of planned costs.</p>}
    </section>
    {plan && <YearOutlook plan={plan} moneyKnown={incomeKnown && planKnown && answer?.money_in_cents != null && answer?.planned_out_cents != null} />}
    {onOpenBudget && <p className="home-plan-link"><button type="button" className="text-button" onClick={onOpenBudget}>Plan details →</button></p>}
    {(pendingImportCount > 0 || (canAskMia && actionCenter.mia_action_review_count > 0)) && <div className="home-other-reviews">
      {pendingImportCount > 0 && <button type="button" className="text-button" onClick={onReviewImports}>{pendingImportCount} file{pendingImportCount === 1 ? '' : 's'} waiting for review</button>}
      {canAskMia && actionCenter.mia_action_review_count > 0 && <button type="button" className="text-button" onClick={onReviewMiaActions}>{actionCenter.mia_action_review_count} {assistantName} change{actionCenter.mia_action_review_count === 1 ? '' : 's'} waiting for review</button>}
    </div>}
  </section>
}

function MoneyValue({ label, cents }: { label: string; cents: number | null | undefined }) {
  return <div><dt>{label}</dt><dd>{cents == null ? 'Not entered' : formatReviewMoney(cents)}</dd></div>
}
