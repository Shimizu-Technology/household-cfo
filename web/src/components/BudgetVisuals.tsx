import { useId, type CSSProperties } from 'react'
import type { AnnualBudgetPlan, BudgetStackKey } from '../api'
import { budgetPositionTotals, type BudgetPosition } from '../lib/budgetPosition'

const currency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })
const compactCurrency = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  notation: 'compact',
  maximumFractionDigits: 1,
})

const stackOrder: BudgetStackKey[] = [
  'non_discretionary',
  'discretionary',
  'sinking_expected',
  'sinking_unexpected',
]

const stackLabels: Record<BudgetStackKey, string> = {
  non_discretionary: 'Non-discretionary',
  discretionary: 'Discretionary',
  sinking_expected: 'Sinking Fund — Expected',
  sinking_unexpected: 'Sinking Fund — Unexpected',
}

export function MonthPlanSummary({
  label,
  income,
  planned,
  actual,
  pending,
  safeToSpend,
  baselineSurplus,
}: {
  label: string
  income: number
  planned: number
  actual: number
  pending: number
  safeToSpend?: number
  baselineSurplus?: number
}) {
  const remaining = planned - actual
  const projected = actual + pending

  return (
    <section className="month-plan-summary" aria-label={`${label} plan position`}>
      <div className="month-plan-summary-heading">
        <div>
          <span>{label}</span>
          <h3>Month-to-date inside the annual plan</h3>
        </div>
        <div className="month-plan-income">
          <span>Expected income</span>
          <strong>{currency.format(income)}</strong>
        </div>
      </div>

      <div className="month-plan-values">
        <PlanValue label="Planned" value={planned} />
        <PlanValue label="Confirmed actual" value={actual} />
        <PlanValue label="Pending review" value={pending} tone="pending" />
        <PlanValue label={remaining >= 0 ? 'Plan remaining' : 'Over plan'} value={Math.abs(remaining)} tone={remaining < 0 ? 'negative' : undefined} />
      </div>

      <BudgetProgressTrack planned={planned} actual={actual} pending={pending} label={`${label}: ${currency.format(actual)} confirmed, ${currency.format(pending)} pending, against ${currency.format(planned)} planned`} />

      <div className="month-plan-explanation">
        <span><i className="confirmed-swatch" /> Confirmed actuals</span>
        <span><i className="pending-swatch" /> Pending if approved</span>
        <strong>{projected > planned && planned > 0 ? `${currency.format(projected - planned)} over plan if all pending items are approved` : `${currency.format(Math.max(planned - projected, 0))} remains after pending review`}</strong>
      </div>

      {(safeToSpend !== undefined || baselineSurplus !== undefined) && (
        <div className="month-plan-decision-row">
          {safeToSpend !== undefined && (
            <div>
              <span>Safe to spend</span>
              <strong>{currency.format(safeToSpend)}</strong>
              <small>Readiness-aware CFO amount—not ordinary budget remaining.</small>
            </div>
          )}
          {baselineSurplus !== undefined && (
            <div>
              <span>Baseline surplus</span>
              <strong>{currency.format(baselineSurplus)}</strong>
              <small>Expected income less the full planned monthly outflow.</small>
            </div>
          )}
        </div>
      )}
    </section>
  )
}

export function ExpenseStackOverview({ positions }: { positions: BudgetPosition[] }) {
  const titleId = useId()
  const groups = stackOrder.map((stackKey) => {
    const stackPositions = positions.filter((position) => position.stackKey === stackKey && position.active)
    return {
      stackKey,
      label: stackPositions[0]?.stackLabel ?? stackLabels[stackKey],
      totals: budgetPositionTotals(stackPositions),
    }
  })

  return (
    <section className="expense-stack-overview" aria-labelledby={titleId}>
      <div className="financial-visual-heading">
        <div>
          <span>Expense Stack</span>
          <h4 id={titleId}>See which layer is using the plan.</h4>
        </div>
        <p>Confirmed spending is solid. Pending review stays striped until you approve it.</p>
      </div>
      <div className="expense-stack-list">
        {groups.map(({ stackKey, label, totals }) => (
          <article className={`expense-stack-row stack-${stackKey}`} key={stackKey}>
            <div className="expense-stack-row-heading">
              <div>
                <strong>{label}</strong>
                <span>{currency.format(totals.actual)} actual · {currency.format(totals.planned)} planned</span>
              </div>
              <b className={totals.remaining < 0 ? 'negative' : ''}>{totals.remaining < 0 ? `${currency.format(Math.abs(totals.remaining))} over` : `${currency.format(totals.remaining)} left`}</b>
            </div>
            <BudgetProgressTrack planned={totals.planned} actual={totals.actual} pending={totals.pending} label={`${label}: ${currency.format(totals.actual)} confirmed and ${currency.format(totals.pending)} pending against ${currency.format(totals.planned)} planned`} />
            {totals.pending > 0 && <small>{currency.format(totals.pending)} pending review—not included in actuals.</small>}
          </article>
        ))}
      </div>
    </section>
  )
}

export function CategoryPressureList({
  positions,
  limit,
  title = 'Categories needing the closest look',
  eyebrow = 'Category attention',
}: {
  positions: BudgetPosition[]
  limit?: number
  title?: string
  eyebrow?: string
}) {
  const titleId = useId()
  const activePositions = positions.filter((position) => position.active)
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
        <p>Ranked by confirmed pace, pending review, and how much of the monthly plan remains.</p>
      </div>
      <div className="category-pressure-list">
        {rankedPositions.length === 0 ? (
          <p className="category-pressure-empty">Add categories to see monthly plan pressure here.</p>
        ) : rankedPositions.map((position) => {
          const projected = position.actual + position.pending
          const projectedDifference = position.planned - projected
          return (
            <article className="category-pressure-row" key={position.id}>
              <div className="category-pressure-row-heading">
                <div>
                  <strong>{position.name}</strong>
                  <span>{position.stackLabel}</span>
                </div>
                <div className="category-pressure-status">
                  {position.pending > 0 && <span>{currency.format(position.pending)} pending</span>}
                  <b className={projectedDifference < 0 ? 'negative' : ''}>
                    {position.planned <= 0
                      ? `${currency.format(position.actual)} unplanned`
                      : projectedDifference < 0
                        ? `${currency.format(Math.abs(projectedDifference))} over if approved`
                        : `${currency.format(projectedDifference)} after pending`}
                  </b>
                </div>
              </div>
              <BudgetProgressTrack planned={position.planned} actual={position.actual} pending={position.pending} label={`${position.name}: ${currency.format(position.actual)} confirmed and ${currency.format(position.pending)} pending against ${currency.format(position.planned)} planned`} />
              <div className="category-pressure-values">
                <span>{currency.format(position.actual)} actual</span>
                <span>{currency.format(position.planned)} planned</span>
                <span className={position.remaining < 0 ? 'negative' : ''}>{position.remaining < 0 ? `${currency.format(Math.abs(position.remaining))} over now` : `${currency.format(position.remaining)} remaining now`}</span>
              </div>
            </article>
          )
        })}
      </div>
    </section>
  )
}

export function AnnualCashFlowChart({ plan, compact = false }: { plan: AnnualBudgetPlan; compact?: boolean }) {
  const titleId = useId()
  const months = plan.annual_outlook.months
  const scaleMaximum = Math.max(...months.flatMap((month) => [month.income, month.planned_outflow]), 1)
  const negativeMonths = months.filter((month) => month.baseline_surplus < 0)

  return (
    <section className={`annual-cash-flow-visual${compact ? ' compact' : ''}`} aria-labelledby={titleId}>
      <div className="financial-visual-heading">
        <div>
          <span>Annual cash flow</span>
          <h4 id={titleId}>Income and planned outflow across {plan.year}</h4>
        </div>
        <p>{negativeMonths.length === 0 ? 'Every planned month keeps a baseline surplus.' : `${negativeMonths.length} planned month${negativeMonths.length === 1 ? '' : 's'} need attention.`}</p>
      </div>
      <div className="annual-cash-flow-legend" aria-hidden="true">
        <span><i className="income-swatch" /> Income</span>
        <span><i className="outflow-swatch" /> Planned outflow</span>
      </div>
      <div className="annual-cash-flow-scroll" role="region" aria-label={`${plan.year} monthly income and planned outflow chart`} tabIndex={0}>
        <div className="annual-cash-flow-chart">
          {months.map((month) => {
            const incomeHeight = Math.max((month.income / scaleMaximum) * 100, month.income > 0 ? 3 : 0)
            const outflowHeight = Math.max((month.planned_outflow / scaleMaximum) * 100, month.planned_outflow > 0 ? 3 : 0)
            const style = {
              '--income-height': `${incomeHeight}%`,
              '--outflow-height': `${outflowHeight}%`,
            } as CSSProperties
            return (
              <article className={`cash-flow-month${month.baseline_surplus < 0 ? ' negative' : ''}`} style={style} key={month.period_id} title={`${month.label}: ${currency.format(month.income)} income, ${currency.format(month.planned_outflow)} planned, ${currency.format(month.baseline_surplus)} baseline surplus`}>
                <div className="cash-flow-bars" aria-hidden="true">
                  <i className="income-bar" />
                  <i className="outflow-bar" />
                </div>
                <strong>{month.label}</strong>
                <span className={month.baseline_surplus < 0 ? 'negative' : ''}>
                  {month.baseline_surplus < 0
                    ? `${compactCurrency.format(Math.abs(month.baseline_surplus))} short`
                    : `${compactCurrency.format(month.baseline_surplus)} left`}
                </span>
                <span className="sr-only">{currency.format(month.income)} income, {currency.format(month.planned_outflow)} planned outflow, and {currency.format(month.baseline_surplus)} baseline surplus.</span>
              </article>
            )
          })}
        </div>
      </div>
    </section>
  )
}

function PlanValue({ label, value, tone }: { label: string; value: number; tone?: 'pending' | 'negative' }) {
  const formattedValue = currency.format(value)
  const lengthClass = formattedValue.length > 14 ? ' value-xlong' : formattedValue.length > 10 ? ' value-long' : ''
  return (
    <div className={tone ? `plan-value ${tone}` : 'plan-value'}>
      <span>{label}</span>
      <strong className={lengthClass.trim()} title={formattedValue}>{formattedValue}</strong>
    </div>
  )
}

function BudgetProgressTrack({ planned, actual, pending, label }: { planned: number; actual: number; pending: number; label: string }) {
  const comparisonMaximum = Math.max(planned, actual + pending, 1)
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
  const projectedRatio = (position.actual + position.pending) / planned
  const confirmedRatio = position.actual / planned
  const overPlanWeight = position.remaining < 0 ? 4 : 0
  const projectedOverWeight = position.actual + position.pending > position.planned ? 2 : 0
  const pendingWeight = position.pending > 0 ? Math.min(position.pending / planned, 1) : 0
  return overPlanWeight + projectedOverWeight + projectedRatio + confirmedRatio * 0.25 + pendingWeight * 0.25
}
