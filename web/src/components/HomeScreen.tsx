import type { BudgetData, DashboardData } from '../api'
import { formatRunway } from '../lib/runway'
import { YearOutlook } from './YearOutlook'
import { guamTodayIso } from '../lib/householdDate'
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

export function HomeScreen({ dashboard, budget, onAskMia, onReviewTransactions, onReviewMiaActions, pendingImportCount, onReviewImports, onOpenDebt, onOpenBudget, incomeKnown = true, planKnown = true, canAskMia = true, canReviewTransactions = true }: HomeScreenProps) {
  const { assistantName } = useBrand()
  const { action_center: actionCenter, month_answer: answer } = dashboard
  const plan = budget.annual_plan?.year === actionCenter.current_year ? budget.annual_plan : null
  const left = answer?.plan_left_cents
  const purchaseCount = canReviewTransactions ? actionCenter.transaction_review_count : 0
  return <section className="screen-grid home-screen">
    <div className="screen-heading home-heading">
      <h2 data-page-heading tabIndex={-1}>Home</h2>
      <p>{actionCenter.current_month_label}{actionCenter.current_year !== Number(guamTodayIso().slice(0, 4)) ? ` ${actionCenter.current_year}` : ''}</p>
    </div>
    <section className="home-month-answer" aria-label="Your month in money">
      <HomeMoneyValues answer={answer} />
      <p className="home-plan-caveat">{answer?.main_income_missing ? 'Still to add: your main income.' : left == null ? 'Add the missing income or planned costs to see what’s left.' : 'This is your plan, not your bank balance.'}</p>
      {answer?.planned_out_cents == null && dashboard.coach_read?.action === 'open_debt' && onOpenDebt && <button type="button" className="text-button" onClick={onOpenDebt}>Add debt minimums</button>}
      <p className="home-spent">Spent so far this month: <strong>{answer?.spent_so_far_cents == null ? 'Not known yet' : formatReviewMoney(answer.spent_so_far_cents)}</strong></p>
      {answer && answer.pending_count == null && <p>More purchases may be waiting. Check Review before your next money decision.</p>}
    </section>
    {(purchaseCount > 0 || canAskMia) && <div className="home-next-action"><Button onClick={purchaseCount > 0 ? onReviewTransactions : onAskMia}>{purchaseCount > 0 ? `Review ${purchaseCount} purchase${purchaseCount === 1 ? '' : 's'}` : `Tell ${assistantName} what changed`}</Button></div>}
    <section className="home-cushion" aria-label="Your emergency cushion">
      <h3>{answer?.runway_months == null ? 'Your emergency cushion' : formatRunway(answer.runway_months)}</h3>
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

export function HomeMoneyValues({ answer }: { answer?: DashboardData['month_answer'] }) {
  const left = answer?.plan_left_cents
  return <dl className="home-money-values">
    <MoneyValue label="Money in" cents={answer?.money_in_cents} />
    <MoneyValue label="Money out · planned" cents={answer?.planned_out_cents} />
    <MoneyValue label={left != null && left < 0 ? 'Short of the plan' : 'What’s left · planned'} cents={left == null ? left : Math.abs(left)} />
  </dl>
}

/** The current month answer can travel with plan details without recalculation. */
export function MonthPlanLine({ answer }: { answer?: DashboardData['month_answer'] }) {
  if (!answer || (answer.money_in_cents == null && answer.planned_out_cents == null)) return null
  const money = (value: number | null | undefined) => value == null ? 'Not entered' : formatReviewMoney(value)
  const left = answer.plan_left_cents
  return <p className="month-plan-line" aria-label="Current month plan">
    {answer.period_label} plan: <strong>{money(answer.money_in_cents)}</strong> money in · <strong>{money(answer.planned_out_cents)}</strong> planned out · <strong>{money(left == null ? left : Math.abs(left))}</strong> {left != null && left < 0 ? 'short' : 'left'}.
    {' '}Plan figures, not a bank balance.
  </p>
}

function MoneyValue({ label, cents }: { label: string; cents: number | null | undefined }) {
  const value = cents == null ? 'Not entered' : formatReviewMoney(cents)
  return <div><dt>{label}</dt><dd className={value.length > 14 ? 'is-long-money' : undefined}>{value}</dd></div>
}
