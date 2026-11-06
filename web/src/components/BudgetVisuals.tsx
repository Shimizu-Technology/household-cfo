import { useId, useState, useRef, useEffect, type CSSProperties } from 'react'
import type { AnnualBudgetPlan, BudgetStackKey } from '../api'
import { budgetPositionTotals, type BudgetPosition } from '../lib/budgetPosition'
import { formatReviewMoney } from '../lib/reviewMoney'
import { addMoney, subtractMoney } from '../lib/moneyMath'

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

export function ExpenseStackOverview({ positions, debtMinimums }: { positions: BudgetPosition[]; debtMinimums?: number | null }) {
  const titleId = useId()
  const groups = stackOrder.map((stackKey) => {
    const stackPositions = positions.filter((position) => position.stackKey === stackKey && position.active)
    return {
      stackKey,
      label: stackLabels[stackKey],
      positions: stackPositions,
      totals: budgetPositionTotals(stackPositions),
    }
  })

  return (
    <section className="expense-stack-overview" aria-labelledby={titleId}>
      <div className="financial-visual-heading"><h4 id={titleId}>Your spending groups</h4><p>Must-pay bills stay steady. Flexible spending is where you can adjust.</p></div>
      <div className="expense-stack-list">
        {groups.map(({ stackKey, label, totals, positions: categories }) => (
          <article className={`expense-stack-row stack-${stackKey}`} key={stackKey}>
            <div className="expense-stack-row-heading">
              <div>
                <strong>{label}</strong>
                <span>{stackKey === 'non_discretionary' ? 'Fixed commitments' : stackKey === 'discretionary' ? 'Room to make choices' : stackKey === 'sinking_expected' ? 'Set aside for costs you can see coming' : 'Set aside for the unexpected'}</span>
              </div>
              <b>{categories.length < 2 ? null : categories.some(category => category.allocationMissing) ? 'Not entered' : `${formatReviewMoney(Math.round(totals.planned * 100))} planned`}</b>
            </div>
            {categories.length === 0 ? <p>No categories yet.</p> : <ul className="expense-group-categories">{categories.map(category => <li key={category.id}><span>{category.name}</span><strong>{category.allocationMissing ? 'Not entered' : formatReviewMoney(Math.round(category.planned * 100))}</strong></li>)}</ul>}
            {stackKey === 'non_discretionary' && debtMinimums !== undefined && <p className="expense-debt-note">{debtMinimums === null ? 'Add your debt minimums.' : `Plus ${formatReviewMoney(Math.round(debtMinimums * 100))} in debt minimums.`}</p>}
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

export function AnnualCashFlowChart({
  plan,
  compact = false,
  selectedMonthIndex = 0,
  moneyKnown = true,
}: {
  plan: AnnualBudgetPlan
  compact?: boolean
  selectedMonthIndex?: number
  moneyKnown?: boolean
}) {
  const titleId = useId()
  const chart = useRef<HTMLDivElement>(null)
  const [narrow, setNarrow] = useState(false)
  useEffect(() => {
    const element = chart.current
    if (!element || typeof ResizeObserver === 'undefined') return
    const observer = new ResizeObserver(([entry]) => setNarrow(entry.contentRect.width < 620))
    observer.observe(element)
    return () => observer.disconnect()
  }, [])
  const months = plan.annual_outlook.months
  const reportPeriodId = months.find(month => month.period_id === plan.months?.[selectedMonthIndex]?.id)?.period_id ?? (plan.months ? months[0]?.period_id : months[selectedMonthIndex]?.period_id) ?? months[0]?.period_id ?? null
  const reportFocusKey = `${plan.year}:${reportPeriodId ?? 'none'}`
  const [chartFocus, setChartFocus] = useState<{
    reportFocusKey: string
    activePeriodId: number | null
    pinnedPeriodId: number | null
  }>(() => ({ reportFocusKey, activePeriodId: reportPeriodId, pinnedPeriodId: null }))
  const activePeriodId = chartFocus.reportFocusKey === reportFocusKey ? chartFocus.activePeriodId : reportPeriodId
  const pinnedPeriodId = chartFocus.reportFocusKey === reportFocusKey ? chartFocus.pinnedPeriodId : null
  const activeMonth = months.find((month) => month.period_id === activePeriodId) ?? months[0]
  const pinnedPeriodExists = months.some((month) => month.period_id === pinnedPeriodId)
  // Bars show what is left (or short) after the plan; income and outflow are
  // close every month, so charting them side by side hid the signal.
  // One linear scale: the area above the midline is sized by the largest surplus
  // and the area below by the largest shortfall, so equal amounts draw equal bars.
  const largestSurplus = Math.max(0, ...months.map((month) => (month.baseline_surplus ?? 0)))
  const largestShortfall = Math.max(0, ...months.map((month) => -(month.baseline_surplus ?? 0)))
  const chartRows = largestSurplus === 0 && largestShortfall === 0 ? '1fr 0fr' : `${largestSurplus}fr ${largestShortfall}fr`
  const negativeMonths = months.filter((month) => (month.baseline_surplus ?? 0) < 0)

  function previewPeriod(periodId: number) {
    setChartFocus((current) => ({
      reportFocusKey,
      activePeriodId: periodId,
      pinnedPeriodId: current.reportFocusKey === reportFocusKey ? current.pinnedPeriodId : null,
    }))
  }

  function togglePinnedPeriod(periodId: number) {
    setChartFocus((current) => {
      const currentPinnedPeriodId = current.reportFocusKey === reportFocusKey ? current.pinnedPeriodId : null
      return {
        reportFocusKey,
        activePeriodId: periodId,
        pinnedPeriodId: currentPinnedPeriodId === periodId ? null : periodId,
      }
    })
  }

  return (
    <section className={`annual-cash-flow-visual${compact ? ' compact' : ''}`} aria-labelledby={titleId}>
      <div className="financial-visual-heading">
        <div>
          <h4 id={titleId}>{compact ? `Your ${plan.year} outlook` : `What’s left each month in ${plan.year}`}</h4>
        </div>
        <p>{!moneyKnown ? 'Enter your income and plan to see your year.' : negativeMonths.length > 0 ? `${negativeMonths.length} planned month${negativeMonths.length === 1 ? ' needs' : 's need'} attention.` : months.some(month => month.baseline_surplus == null) ? 'Some months still need income.' : 'Every planned month has money left over.'}</p>
      </div>
      <div className="annual-cash-flow-legend" aria-hidden="true">
        <span><i className="surplus-swatch" /> Left after the plan</span>
        <span><i className="shortfall-swatch" /> Short of the plan</span>
      </div>
      <div ref={chart} className="annual-cash-flow-scroll" role="region" aria-label={`${plan.year} monthly income and planned outflow chart`} tabIndex={0}>
        <div className={`annual-cash-flow-chart${moneyKnown ? '' : ' is-unknown'}`} style={{ '--cash-flow-rows': chartRows } as CSSProperties}>
          {months.map((month) => {
            const rowMaximum = (month.baseline_surplus ?? 0) >= 0 ? largestSurplus : largestShortfall
            const surplusHeight = rowMaximum === 0 ? 0 : (Math.abs((month.baseline_surplus ?? 0)) / rowMaximum) * 100
            const style = { '--surplus-height': `${surplusHeight}%` } as CSSProperties
            const MonthTarget = narrow ? 'div' : 'button'
            const monthKnown = moneyKnown && month.income != null && month.baseline_surplus != null
            return (
              <article className={`cash-flow-month${(month.baseline_surplus ?? 0) < 0 ? ' negative' : ''}${month.period_id === reportPeriodId ? ' is-report-month' : ''}${pinnedPeriodId === month.period_id ? ' is-pinned' : ''}`} style={style} key={month.period_id}>
                <MonthTarget
                  type={narrow ? undefined : 'button'}
                  className="cash-flow-month-trigger"
                  aria-hidden={narrow || undefined}
                  aria-pressed={narrow ? undefined : pinnedPeriodId === month.period_id}
                  aria-current={month.period_id === reportPeriodId ? 'date' : undefined}
                  aria-label={!monthKnown ? `${month.label} ${plan.year}: Not entered` : `${month.label} ${plan.year}: ${formatReviewMoney(Math.round((month.income ?? 0) * 100))} income, ${formatReviewMoney(Math.round((month.planned_outflow) * 100))} planned outflow, and ${formatReviewMoney(Math.round((Math.abs((month.baseline_surplus ?? 0))) * 100))} ${(month.baseline_surplus ?? 0) < 0 ? 'short' : 'left over'}`}
                  onMouseEnter={narrow ? undefined : (event) => {
                    // Focusing a month can scroll another bar beneath a stationary
                    // pointer. Keep the keyboard user's detail on the focused month.
                    const keyboardFocusedMonth = event.currentTarget.closest('.annual-cash-flow-chart')?.querySelector('.cash-flow-month-trigger:focus-visible')
                    if (!keyboardFocusedMonth && (pinnedPeriodId === null || !pinnedPeriodExists)) previewPeriod(month.period_id)
                  }}
                  onFocus={narrow ? undefined : () => previewPeriod(month.period_id)}
                  onClick={narrow ? undefined : () => togglePinnedPeriod(month.period_id)}
                >
                  <div className="cash-flow-bars" aria-hidden="true">
                    <span className="cash-flow-bar-above">{monthKnown && (month.baseline_surplus ?? 0) > 0 && <i />}</span>
                    <span className="cash-flow-bar-below">{monthKnown && (month.baseline_surplus ?? 0) < 0 && <i />}</span>
                  </div>
                  <strong>{month.label}</strong>
                  <span className={`cash-flow-month-summary${(month.baseline_surplus ?? 0) < 0 ? ' negative' : ''}`}>
                    <b>{monthKnown ? compactCurrency.format(Math.abs((month.baseline_surplus ?? 0))) : '—'}</b>
                    {monthKnown && <small>{(month.baseline_surplus ?? 0) < 0 ? 'short' : 'left'}</small>}
                  </span>
                </MonthTarget>
              </article>
            )
          })}
        </div>
      </div>
      {narrow && activeMonth && <label className="cash-flow-month-picker">View month
        <select value={activeMonth.period_id} onChange={(event) => {
          const periodId = Number(event.target.value)
          setChartFocus({ reportFocusKey, activePeriodId: periodId, pinnedPeriodId: periodId })
        }}>
          {months.map((month) => <option key={month.period_id} value={month.period_id}>{month.label} {plan.year}</option>)}
        </select>
      </label>}
      {moneyKnown && activeMonth && activeMonth.baseline_surplus != null && activeMonth.income != null && (
        <div className="cash-flow-detail-panel" aria-live="polite">
          <div className="cash-flow-detail-summary">
            <span>{activeMonth.period_id === reportPeriodId ? 'Report month' : 'Chart preview'}</span>
            <strong>{activeMonth.label} {plan.year}</strong>
            <small>
              {activeMonth.baseline_surplus < 0
                ? `${formatReviewMoney(Math.round((Math.abs(activeMonth.baseline_surplus)) * 100))} more is planned than expected income.`
                : `${formatReviewMoney(Math.round((activeMonth.baseline_surplus) * 100))} remains after planned outflow.`}
            </small>
          </div>
          <dl>
            <div><dt>Income</dt><dd>{formatReviewMoney(Math.round((activeMonth.income) * 100))}</dd></div>
            <div><dt>Planned outflow</dt><dd>{formatReviewMoney(Math.round((activeMonth.planned_outflow) * 100))}</dd></div>
            <div className={activeMonth.baseline_surplus < 0 ? 'negative' : ''}>
              <dt>{activeMonth.baseline_surplus < 0 ? 'Short each month' : 'Left over each month'}</dt>
              <dd>{formatReviewMoney(Math.round((Math.abs(activeMonth.baseline_surplus)) * 100))}</dd>
            </div>
          </dl>
          <div className="cash-flow-detail-context">
            <div>
              <span>Expected irregular plan included in outflow</span>
              <strong>{formatReviewMoney(Math.round((activeMonth.expected_irregular) * 100))}</strong>
            </div>
            {activeMonth.expected_contributors.length > 0 ? (
              <ul>
                {activeMonth.expected_contributors.map((contributor) => (
                  <li key={`${activeMonth.period_id}-${contributor.name}`}>
                    <span>{contributor.name}</span>
                    <b>{formatReviewMoney(Math.round((contributor.amount) * 100))}</b>
                  </li>
                ))}
              </ul>
            ) : (
              <p>No expected irregular categories are planned this month.</p>
            )}
          </div>
        </div>
      )}

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
