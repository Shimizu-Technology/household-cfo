import { useId, type CSSProperties } from 'react'
import type { AnnualBudgetPlan, BudgetStackKey, DashboardData } from '../api'
import { budgetPositionTotals, type BudgetPosition } from '../lib/budgetPosition'
import { formatReviewMoney } from '../lib/reviewMoney'
import { addMoney, subtractMoney } from '../lib/moneyMath'

const stackOrder: BudgetStackKey[] = [
  'non_discretionary',
  'discretionary',
  'sinking_expected',
  'sinking_unexpected',
]

const stackLabels: Record<BudgetStackKey, string> = {
  non_discretionary: 'Must-pay bills',
  discretionary: 'Flexible spending',
  sinking_expected: 'Planned yearly costs',
  sinking_unexpected: 'Surprise fund',
}

export function MonthPlanSummary({
  label, income, planned, actual, pending, debtMinimums = 0,
  debtMinimumsKnown = true, incomeKnown = true, planKnown = true, compact = false,
}: {
  label: string
  income: number
  planned: number
  actual: number
  pending: number
  safeToSpend?: number | null
  baselineSurplus?: number
  debtMinimums?: number
  debtMinimumsKnown?: boolean
  incomeKnown?: boolean
  planKnown?: boolean
  compact?: boolean
}) {
  // Money in, money out: planned out includes debt minimums, matching the year chart.
  const plannedOut = planKnown && debtMinimumsKnown ? addMoney(planned, debtMinimums) : null
  const balance = incomeKnown && plannedOut !== null ? subtractMoney(income, plannedOut) : null
  const overPlan = planKnown ? subtractMoney(actual, planned) : 0
  return (
    <section className="month-plan-summary" aria-label={`${label} plan position`}>
      <h3 className={compact ? 'sr-only' : undefined}>{label}</h3>
      <div className="month-plan-values">
        <PlanValue label="Money in" value={incomeKnown ? income : null} />
        <PlanValue label="Planned out" value={plannedOut} />
        <PlanValue label="Spent so far" value={actual > 0 ? actual : null} emptyText="No confirmed transactions yet" />
      </div>
      {balance !== null && <p className={`month-plan-balance${balance < 0 ? ' is-short' : ''}`}>{balance < 0
        ? `This month’s plan is ${formatReviewMoney(Math.round((-balance) * 100))} more than money in.`
        : balance === 0 ? 'Your plan uses all of your money in.' : `Your plan leaves ${formatReviewMoney(Math.round((balance) * 100))} after planned spending.`}</p>}
      {overPlan > 0 && <p className="month-plan-balance is-short">Spending is {formatReviewMoney(Math.round((overPlan) * 100))} over the plan.</p>}
      {pending > 0 && <p className="month-plan-pending"><i className="pending-swatch" aria-hidden="true" /> {formatReviewMoney(Math.round((pending) * 100))} pending review · not counted as spent</p>}
      {planKnown && !compact && <BudgetProgressTrack planned={planned} actual={actual} pending={pending} label={`${label}: ${formatReviewMoney(Math.round((actual) * 100))} confirmed, ${formatReviewMoney(Math.round((pending) * 100))} pending, against ${formatReviewMoney(Math.round((planned) * 100))} planned`} />}
      {planKnown && !compact && (debtMinimums > 0 || !debtMinimumsKnown) && <p className="month-plan-note" role="group" aria-label="Monthly money out breakdown">
        Category plan {formatReviewMoney(Math.round((planned) * 100))} + Debt minimums {debtMinimumsKnown ? formatReviewMoney(Math.round((debtMinimums) * 100)) : 'Not entered'} = Planned out {debtMinimumsKnown ? formatReviewMoney(Math.round((addMoney(planned, debtMinimums)) * 100)) : 'Not available'}
      </p>}
    </section>
  )
}

/** The selected month's plan; pending purchases never reduce the remainder. */
export function BudgetPlanStrip({ plan, monthIndex, planKnown, confirmedFields = [], answer }: { plan: AnnualBudgetPlan; monthIndex: number; planKnown: boolean; confirmedFields?: string[]; answer?: DashboardData['month_answer'] }) {
  const month = plan.months[monthIndex]
  const outlook = plan.annual_outlook.months.find(candidate => candidate.period_id === month?.id)
  const approved = plan.plan_available !== false
  const costsKnown = (['fixed_expenses', 'flexible_spend'] as const).every((field, index) => confirmedFields.includes(field) || plan.rows.some(row => row.active && row.stack_key === (index === 0 ? 'non_discretionary' : 'discretionary')))
  const income = answer ? (answer.money_in_cents == null ? null : answer.money_in_cents / 100) : approved && month ? plan.monthly_income[month.id] : null
  const amountsKnown = plan.rows.every(row => !row.active || (row.months[monthIndex] && !row.months[monthIndex].allocation_missing))
  const planned = answer ? (answer.planned_out_cents == null ? null : answer.planned_out_cents / 100) : approved && planKnown && costsKnown && amountsKnown && plan.monthly_debt_minimums_known !== false ? outlook?.planned_outflow : null
  const left = answer ? (answer.plan_left_cents == null ? null : answer.plan_left_cents / 100) : income != null && planned != null ? subtractMoney(income, planned) : null
  return <section className={`budget-plan-strip ui-card${[income, planned, left].some(value => value == null || formatReviewMoney(Math.round(Math.abs(value) * 100)).length >= 9) ? ' is-long-money' : ''}`} aria-label={`${month?.label ?? 'Selected month'} plan position`}>
    <p className="budget-strip-period ui-label">{month && new Intl.DateTimeFormat('en-US', { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(new Date(`${month.starts_on}T00:00:00Z`))}</p>
    <dl>
      <div><dt>Money in</dt><dd>{income == null ? 'Not entered' : formatReviewMoney(Math.round(income * 100))}</dd></div>
      <div><dt>Planned out</dt><dd>{planned == null ? 'Not entered' : formatReviewMoney(Math.round(planned * 100))}</dd></div>
      <div><dt>{left != null && left < 0 ? 'Short of the plan' : 'Left after the plan'}</dt><dd>{left == null ? 'Not entered' : formatReviewMoney(Math.round(Math.abs(left) * 100))}</dd></div>
    </dl>
    <p>Plan figures, not a bank balance.</p>
  </section>
}

export function ExpenseStackOverview({ positions, debtMinimums }: { positions: BudgetPosition[]; debtMinimums?: number | null }) {
  const titleId = useId()
  const groups = stackOrder.map((stackKey) => {
    const stackPositions = positions.filter((position) => position.stackKey === stackKey && (position.active || position.actual > 0))
    // Money spent in an archived category still counts in its group; its old allocation is no longer part of the plan.
    const totals = { ...budgetPositionTotals(stackPositions), planned: budgetPositionTotals(stackPositions.filter(position => position.active)).planned }
    return { stackKey, label: stackLabels[stackKey], positions: stackPositions, totals }
  })

  return (
    <section className="expense-stack-overview ui-card" aria-labelledby={titleId}>
      <div className="financial-visual-heading"><h4 id={titleId}>Your spending groups</h4><p>Must-pay bills stay steady. Flexible spending is where you can adjust.</p></div>
      <div className="expense-stack-list">
        {groups.map(({ stackKey, label, totals, positions: categories }) => {
          const known = categories.some(category => category.id !== 0) && !categories.some(category => category.id !== 0 && category.active && category.allocationMissing)
          const over = known ? subtractMoney(totals.actual, totals.planned) : 0
          const spent = totals.actual > 0 ? `${formatReviewMoney(Math.round(totals.actual * 100))} spent` : 'No confirmed transactions yet'
          const value = known && totals.planned > 0 ? Math.min(100, Math.max(0, totals.actual / totals.planned * 100)) : known && totals.actual > 0 ? 100 : 0
          return <article className={`expense-stack-row stack-${stackKey}${over > 0 ? ' is-over' : ''}${formatReviewMoney(Math.round(Math.max(totals.planned, totals.actual) * 100)).length > 12 ? ' is-long-money' : ''}`} key={stackKey}>
            <details className="expense-group-details">
              <summary aria-label={label} aria-describedby={`${titleId}-${stackKey}-values ${titleId}-${stackKey}-meaning`}>
                <div className="expense-stack-row-heading">
                  <div><strong>{label}</strong><span>{stackKey === 'non_discretionary' ? 'Fixed commitments' : stackKey === 'discretionary' ? 'Room to make choices' : stackKey === 'sinking_expected' ? 'Set aside for costs you can see coming' : 'Set aside for the unexpected'}</span></div>
                  <div id={`${titleId}-${stackKey}-values`} className="expense-group-money"><b>{known ? `${formatReviewMoney(Math.round(totals.planned * 100))} planned` : 'Not entered'}</b><span>{spent}</span></div>
                </div>
                {known && <div className="ui-track" aria-hidden="true" style={{ '--value': `${value}%` } as CSSProperties}><span className="ui-track__fill" /></div>}
                <p id={`${titleId}-${stackKey}-meaning`} className="expense-group-meaning">{!known ? 'Add planned amounts to compare with spending.' : over > 0 ? `${formatReviewMoney(Math.round(over * 100))} over the plan.` : totals.actual === 0 ? 'Nothing spent against this plan yet.' : totals.actual === totals.planned ? 'Spending has used the full plan.' : `${formatReviewMoney(Math.round(subtractMoney(totals.planned, totals.actual) * 100))} left in this group.`}</p>
              </summary>
              {categories.length === 0 ? <p>No categories yet.</p> : <ul className="expense-group-categories">{categories.map(category => <li key={category.id}><span>{category.name}</span><strong>{category.id === 0 ? `${formatReviewMoney(Math.round(category.pending * 100))} pending review` : !category.active ? `${formatReviewMoney(Math.round(category.actual * 100))} spent · archived` : category.allocationMissing ? 'Not entered' : formatReviewMoney(Math.round(category.planned * 100))}</strong></li>)}</ul>}
            </details>
            {stackKey === 'non_discretionary' && debtMinimums !== undefined && <p className="expense-debt-note">{debtMinimums === null ? 'Add your debt minimums.' : `Plus ${formatReviewMoney(Math.round(debtMinimums * 100))} in debt minimums.`}</p>}
          </article>
        })}
      </div>
    </section>
  )
}

export function CategoryPressureList({
  positions,
  limit,
  title = 'Categories needing the closest look',
  eyebrow = 'Category attention',
  planKnown = true,
}: {
  positions: BudgetPosition[]
  limit?: number
  title?: string
  eyebrow?: string
  planKnown?: boolean
}) {
  const titleId = useId()
  const activePositions = positions.filter((position) => position.active && (planKnown || position.actual > 0 || position.pending > 0))
  const rankedPositions = [...activePositions]
    .sort((left, right) => categoryPressureScore(right) - categoryPressureScore(left) || right.actual - left.actual)
    .slice(0, limit ?? activePositions.length)

  return (
    <section className="category-pressure-panel" aria-labelledby={titleId}>
      <div className="financial-visual-heading">
        <div>
          <span>{eyebrow}</span>
          <h4 id={titleId}>{title}</h4>
        </div>
        <p>See what you’ve spent and what’s waiting for review.</p>
      </div>
      <div className="category-pressure-list">
        {rankedPositions.length === 0 ? (
          <p className="category-pressure-empty">{planKnown ? 'Add categories to see monthly plan pressure here.' : 'Approved spending is not known yet.'}</p>
        ) : rankedPositions.map((position) => {
          const positionPlanKnown = planKnown && position.id !== 0
          const projected = addMoney(position.actual, position.pending)
          const projectedDifference = subtractMoney(position.planned, projected)
          return (
            <article className="category-pressure-row" key={position.id}>
              <div className="category-pressure-row-heading">
                <div>
                  <strong>{position.name}</strong>
                  <span>{stackLabels[position.stackKey]}</span>
                </div>
                <div className="category-pressure-status">
                  {position.pending > 0 && <span>{formatReviewMoney(Math.round((position.pending) * 100))} pending</span>}
                  {positionPlanKnown && <b className={projectedDifference < 0 ? 'negative' : ''}>
                    {position.planned <= 0
                      ? `${formatReviewMoney(Math.round((position.actual) * 100))} unplanned`
                      : projectedDifference < 0
                        ? `${formatReviewMoney(Math.round((Math.abs(projectedDifference)) * 100))} over if approved`
                        : `${formatReviewMoney(Math.round((projectedDifference) * 100))} after pending`}
                  </b>}
                </div>
              </div>
              {positionPlanKnown && <BudgetProgressTrack planned={position.planned} actual={position.actual} pending={position.pending} label={`${position.name}: ${formatReviewMoney(Math.round((position.actual) * 100))} confirmed and ${formatReviewMoney(Math.round((position.pending) * 100))} pending against ${formatReviewMoney(Math.round((position.planned) * 100))} planned`} />}
              <div className="category-pressure-values">
                <span>{positionPlanKnown || position.actual > 0 ? `${formatReviewMoney(Math.round(position.actual * 100))} actual` : 'Approved spending not known yet'}</span>
                {positionPlanKnown && <>
                  <span>{formatReviewMoney(Math.round((position.planned) * 100))} planned</span>
                  <span className={position.remaining < 0 ? 'negative' : ''}>{position.remaining < 0 ? `${formatReviewMoney(Math.round((Math.abs(position.remaining)) * 100))} over now` : `${formatReviewMoney(Math.round((position.remaining) * 100))} remaining now`}</span>
                </>}
              </div>
            </article>
          )
        })}
      </div>
    </section>
  )
}

function PlanValue({ label, value, tone, emptyText = 'Not entered' }: { label: string; value: number | null; tone?: 'pending' | 'negative'; emptyText?: string }) {
  const formattedValue = value === null ? emptyText : formatReviewMoney(Math.round((value) * 100))
  const lengthClass = formattedValue.length > 14 ? ' value-xlong' : formattedValue.length > 10 ? ' value-long' : ''
  return (
    <div className={tone ? `plan-value ${tone}` : 'plan-value'}>
      <span>{label}</span>
      <strong className={`${lengthClass}${value === null ? ' is-empty' : ''}`.trim()} title={formattedValue}>{formattedValue}</strong>
    </div>
  )
}

function BudgetProgressTrack({ planned, actual, pending, label }: { planned: number; actual: number; pending: number; label: string }) {
  const comparisonMaximum = Math.max(planned, addMoney(actual, pending), 1)
  const actualWidth = Math.min((Math.max(actual, 0) / comparisonMaximum) * 100, 100)
  const pendingWidth = Math.min((Math.max(pending, 0) / comparisonMaximum) * 100, Math.max(100 - actualWidth, 0))
  const planMarker = Math.min((Math.max(planned, 0) / comparisonMaximum) * 100, 100)
  const style = {
    '--actual-width': `${actualWidth}%`,
    '--pending-width': `${pendingWidth}%`,
    '--plan-marker': `${planMarker}%`,
  } as CSSProperties

  return (
    <div className="budget-progress-track" role="img" aria-label={label} style={style}>
      <i className="budget-progress-actual" />
      <i className="budget-progress-pending" />
      <i className="budget-progress-plan-marker" />
    </div>
  )
}

function categoryPressureScore(position: BudgetPosition) {
  const planned = Math.max(position.planned, 1)
  const projected = addMoney(position.actual, position.pending)
  const projectedRatio = projected / planned
  const confirmedRatio = position.actual / planned
  const overPlanWeight = position.remaining < 0 ? 4 : 0
  const projectedOverWeight = projected > position.planned ? 2 : 0
  const pendingWeight = position.pending > 0 ? Math.min(position.pending / planned, 1) : 0
  return overPlanWeight + projectedOverWeight + projectedRatio + confirmedRatio * 0.25 + pendingWeight * 0.25
}
