import { useEffect, useId, useRef, useState } from 'react'
import { fetchMonthlyClose, type MonthlyCloseData, type MonthlyCloseStatus } from '../api'
import { expenseGroupLabels, expenseGroupOrder, useExpenseGroupNames } from '../lib/expenseGroups'
import { formatReviewMoney } from '../lib/reviewMoney'
import './MonthlyClosePanel.css'

export type MonthlyClosePanelProps = {
  year: number
  month: number
  refreshKey?: string | number
  onAdjustCategory?: (categoryId: number) => void
  planningBlockedReason?: string
  loadMonthlyClose?: (year: number, month: number, signal?: AbortSignal) => Promise<MonthlyCloseData>
}

function statusPillClass(status: MonthlyCloseStatus): string {
  if (status === 'complete') return 'ui-pill ui-pill--good'
  if (status === 'partial') return 'ui-pill ui-pill--attention'
  return 'ui-pill'
}

function statusDotClass(status: MonthlyCloseStatus): string {
  if (status === 'complete') return 'ui-dot ui-dot--good'
  if (status === 'partial') return 'ui-dot ui-dot--attention'
  if (status === 'open') return 'ui-dot'
  return 'ui-dot ui-dot--neutral'
}

function formatSignedDelta(cents: number): string {
  if (cents === 0) return 'No change'
  return cents > 0 ? `+${formatReviewMoney(cents)}` : `-${formatReviewMoney(-cents)}`
}

function formatIncomeVariance(diffCents: number): string {
  if (diffCents === 0) return 'Matched plan'
  return diffCents > 0
    ? `${formatReviewMoney(diffCents)} above plan`
    : `${formatReviewMoney(-diffCents)} under plan`
}

function formatSpendingVariance(diffCents: number): string {
  if (diffCents === 0) return 'On plan'
  return diffCents > 0
    ? `${formatReviewMoney(diffCents)} over`
    : `${formatReviewMoney(-diffCents)} under`
}

function monthNameFallback(year: number, month: number): string {
  const safeMonth = Math.max(1, Math.min(12, month))
  return new Intl.DateTimeFormat('en-US', { month: 'long', year: 'numeric', timeZone: 'UTC' })
    .format(new Date(Date.UTC(year, safeMonth - 1, 1)))
}

export function MonthlyClosePanel({
  year,
  month,
  refreshKey,
  onAdjustCategory,
  planningBlockedReason,
  loadMonthlyClose = fetchMonthlyClose,
}: MonthlyClosePanelProps) {
  const titleId = useId()
  const groupNames = useExpenseGroupNames()
  const stackLabels = expenseGroupLabels[groupNames]
  const requestIdRef = useRef(0)
  const [reloadNonce, setReloadNonce] = useState(0)
  const [data, setData] = useState<MonthlyCloseData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    const requestId = ++requestIdRef.current
    setLoading(true)
    setError(null)

    loadMonthlyClose(year, month, controller.signal)
      .then((result) => {
        if (requestId !== requestIdRef.current || controller.signal.aborted) return
        setData(result)
        setError(null)
        setLoading(false)
      })
      .catch((caught: unknown) => {
        if (requestId !== requestIdRef.current || controller.signal.aborted) return
        if (caught instanceof DOMException && caught.name === 'AbortError') return
        const message = caught instanceof Error && caught.message.trim()
          ? caught.message
          : 'Monthly close could not be loaded right now.'
        setError(message)
        setLoading(false)
      })

    return () => {
      controller.abort()
    }
  }, [year, month, refreshKey, reloadNonce, loadMonthlyClose])

  const visibleData = data && data.year === year && data.month === month ? data : null
  const headingLabel = visibleData ? `${visibleData.period_label} close` : `${monthNameFallback(year, month)} close`

  const groupedCategories = visibleData
    ? expenseGroupOrder
        .map((stackKey) => ({
          stackKey,
          label: stackLabels[stackKey],
          categories: visibleData.categories.filter((cat) => cat.stack_key === stackKey),
        }))
        .filter((group) => group.categories.length > 0)
    : []

  const hasMovers = Boolean(
    visibleData && (
      visibleData.changes.increases.length > 0
      || visibleData.changes.decreases.length > 0
      || visibleData.changes.income_change !== null
    ),
  )

  return (
    <section
      className="monthly-close-panel ui-card"
      aria-labelledby={titleId}
      aria-busy={loading}
    >
      <div className="monthly-close-header">
        <div className="monthly-close-heading">
          <h4 id={titleId}>{headingLabel}</h4>
          <p className="monthly-close-subtitle">Actuals against your plan, and what changed from last month.</p>
        </div>
        {visibleData && (
          <span className={statusPillClass(visibleData.status)}>
            <span className={statusDotClass(visibleData.status)} aria-hidden="true" />
            <span>{visibleData.status_label}</span>
          </span>
        )}
      </div>

      {loading && !visibleData && (
        <p className="monthly-close-state" role="status">Loading monthly close…</p>
      )}

      {error && (
        <div className="monthly-close-error" role="alert">
          <p>{error}</p>
          <button
            type="button"
            className="ui-btn ui-btn--tonal"
            onClick={() => setReloadNonce((count) => count + 1)}
          >
            Try again
          </button>
        </div>
      )}

      {visibleData && (
        <div className="monthly-close-body">
          {visibleData.before_plan_start && (
            <p className="monthly-close-note">
              Your plan starts in {monthNameFallback(Number(visibleData.plan_starts_on.slice(0, 4)), Number(visibleData.plan_starts_on.slice(5, 7)))}, so {visibleData.period_label} has no plan to compare against.
            </p>
          )}
          {(visibleData.status !== 'complete' || visibleData.income.waiting_deposits > 0) && visibleData.income.coverage_note && (
            <p className="monthly-close-note">{visibleData.income.coverage_note}</p>
          )}

          {visibleData.highlights.length > 0 && (
            <ul className="monthly-close-highlights" aria-label="Monthly close summary">
              {visibleData.highlights.map((line, index) => (
                <li key={index}>{line}</li>
              ))}
            </ul>
          )}

          <div className="monthly-close-summary-grid" role="group" aria-label="Income, spending, and debt totals">
            <div className="monthly-close-summary-item">
              <span className="ui-label">Money in</span>
              <strong className="monthly-close-figure">
                {visibleData.income.actual_cents != null
                  ? `${formatReviewMoney(visibleData.income.actual_cents)}${visibleData.income.month_open || visibleData.income.partial ? ' so far' : ''}`
                  : 'Not known yet'}
              </strong>
              <span className="monthly-close-meta">
                Planned: {visibleData.income.planned_cents != null ? formatReviewMoney(visibleData.income.planned_cents) : 'Not entered'}
              </span>
              {visibleData.income.difference_cents != null ? (
                <span className={`monthly-close-variance${visibleData.income.difference_cents < 0 ? ' is-attention' : ' is-good'}`}>
                  {formatIncomeVariance(visibleData.income.difference_cents)}
                </span>
              ) : (visibleData.income.partial || visibleData.income.month_open) && (
                <span className="monthly-close-meta">Variance waits for complete statements</span>
              )}
              {visibleData.income.change_from_prior_cents != null && (
                <span className="monthly-close-meta">
                  {formatSignedDelta(visibleData.income.change_from_prior_cents)} vs. {visibleData.prior_period_label}
                </span>
              )}
            </div>

            <div className="monthly-close-summary-item">
              <span className="ui-label">Category spending</span>
              <strong className="monthly-close-figure">
                {visibleData.totals.has_spending_activity && visibleData.totals.actual_spending_cents != null
                  ? formatReviewMoney(visibleData.totals.actual_spending_cents)
                  : 'No confirmed spending yet'}
              </strong>
              <span className="monthly-close-meta">
                Planned: {visibleData.totals.planned_spending_cents != null ? formatReviewMoney(visibleData.totals.planned_spending_cents) : 'Not entered'}
              </span>
              {visibleData.totals.spending_difference_cents != null && (
                <span className={`monthly-close-variance${visibleData.totals.spending_difference_cents > 0 ? ' is-attention' : ' is-good'}`}>
                  {formatSpendingVariance(visibleData.totals.spending_difference_cents)}
                </span>
              )}
              {visibleData.totals.spending_change_from_prior_cents != null && (
                <span className="monthly-close-meta">
                  {formatSignedDelta(visibleData.totals.spending_change_from_prior_cents)} vs. {visibleData.prior_period_label}
                </span>
              )}
            </div>

            <div className="monthly-close-summary-item">
              <span className="ui-label">Monthly debt payments</span>
              <strong className="monthly-close-figure">
                {visibleData.totals.debt_minimums_known && visibleData.totals.debt_minimums_cents != null
                  ? formatReviewMoney(visibleData.totals.debt_minimums_cents)
                  : 'Not entered'}
              </strong>
              <span className="monthly-close-meta">Tracked separately from category spending.</span>
            </div>
          </div>

          {(visibleData.net.actual_net_before_debt_cents != null || visibleData.net.planned_net_before_debt_cents != null) && (
            <div className="monthly-close-net" role="group" aria-label="Net cash flow">
              <div className="monthly-close-net-row">
                <span className="ui-label">Left after category spending</span>
                <div className="monthly-close-net-values">
                  {visibleData.net.actual_net_before_debt_cents != null && (
                    <strong>{formatReviewMoney(visibleData.net.actual_net_before_debt_cents)} actual</strong>
                  )}
                  {visibleData.net.planned_net_before_debt_cents != null && (
                    <span className="monthly-close-meta">
                      {formatReviewMoney(visibleData.net.planned_net_before_debt_cents)} planned
                    </span>
                  )}
                </div>
              </div>
              {visibleData.totals.debt_minimums_known && (visibleData.net.actual_net_after_debt_cents != null || visibleData.net.planned_net_after_debt_cents != null) && (
                <div className="monthly-close-net-row">
                  <span className="ui-label">After monthly debt payments</span>
                  <div className="monthly-close-net-values">
                    {visibleData.net.actual_net_after_debt_cents != null && (
                      <strong>{formatReviewMoney(visibleData.net.actual_net_after_debt_cents)} actual</strong>
                    )}
                    {visibleData.net.planned_net_after_debt_cents != null && (
                      <span className="monthly-close-meta">
                        {formatReviewMoney(visibleData.net.planned_net_after_debt_cents)} planned
                      </span>
                    )}
                  </div>
                </div>
              )}
            </div>
          )}

          <div className="monthly-close-section">
            <h5 className="monthly-close-section-title">What changed from {visibleData.changes.prior_period_label}</h5>
            {!visibleData.changes.prior_month_has_activity && !visibleData.changes.income_change ? (
              <p className="monthly-close-note">
                No confirmed activity in {visibleData.changes.prior_period_label}, so month-over-month changes are not available yet.
              </p>
            ) : !hasMovers ? (
              <p className="monthly-close-note">
                No changes from {visibleData.changes.prior_period_label}.
              </p>
            ) : (
              <div className="monthly-close-changes">
                {visibleData.changes.income_change && (
                  <p className="monthly-close-income-change">
                    <span>Money in</span>
                    <strong className={visibleData.changes.income_change.change_from_prior_cents < 0 ? 'is-attention' : 'is-good'}>
                      {formatSignedDelta(visibleData.changes.income_change.change_from_prior_cents)}
                    </strong>
                    <span className="monthly-close-meta">
                      ({formatReviewMoney(visibleData.changes.income_change.prior_actual_cents)} → {formatReviewMoney(visibleData.changes.income_change.actual_cents)})
                    </span>
                  </p>
                )}

                {visibleData.changes.increases.length > 0 && (
                  <div className="monthly-close-mover-group">
                    <span className="ui-label">Biggest increases</span>
                    <ul className="monthly-close-mover-list">
                      {visibleData.changes.increases.map((mover) => (
                        <li key={mover.category_id}>
                          <span className="monthly-close-mover-name">
                            {mover.name}{!mover.active && <em className="monthly-close-tag">Archived</em>}
                          </span>
                          <span className="monthly-close-mover-amount is-attention">
                            {formatSignedDelta(mover.change_from_prior_cents)}
                          </span>
                        </li>
                      ))}
                    </ul>
                  </div>
                )}

                {visibleData.changes.decreases.length > 0 && (
                  <div className="monthly-close-mover-group">
                    <span className="ui-label">Biggest decreases</span>
                    <ul className="monthly-close-mover-list">
                      {visibleData.changes.decreases.map((mover) => (
                        <li key={mover.category_id}>
                          <span className="monthly-close-mover-name">
                            {mover.name}{!mover.active && <em className="monthly-close-tag">Archived</em>}
                          </span>
                          <span className="monthly-close-mover-amount is-good">
                            {formatSignedDelta(mover.change_from_prior_cents)}
                          </span>
                        </li>
                      ))}
                    </ul>
                  </div>
                )}
              </div>
            )}
          </div>

          <div className="monthly-close-section">
            <div className="monthly-close-section-head">
              <h5 className="monthly-close-section-title">Categories by spending group</h5>
              {planningBlockedReason && (
                <p className="monthly-close-note">{planningBlockedReason}</p>
              )}
            </div>

            {groupedCategories.length === 0 ? (
              <p className="monthly-close-note">No categories in this month yet.</p>
            ) : (
              <div className="monthly-close-groups">
                {groupedCategories.map((group) => (
                  <div className="monthly-close-group" key={group.stackKey}>
                    <h6 className="monthly-close-group-title">{group.label}</h6>
                    <ul className="monthly-close-category-list">
                      {group.categories.map((category) => (
                        <li className="monthly-close-category-row" key={category.id}>
                          <div className="monthly-close-category-main">
                            <div className="monthly-close-category-name">
                              <strong>{category.name}</strong>
                              {!category.active && <span className="monthly-close-tag">Archived</span>}
                            </div>
                            {category.refund_net_negative && (
                              <span className="monthly-close-meta">More came back in refunds than was spent.</span>
                            )}
                          </div>

                          <dl className="monthly-close-category-metrics">
                            <div>
                              <dt>Planned</dt>
                              <dd>
                                {!category.active
                                  ? 'Not in plan'
                                  : category.planned_cents != null
                                    ? formatReviewMoney(category.planned_cents)
                                    : 'Not entered'}
                              </dd>
                            </div>
                            <div>
                              <dt>Actual</dt>
                              <dd>{formatReviewMoney(category.actual_cents)}</dd>
                            </div>
                            <div>
                              <dt>Over / under</dt>
                              <dd className={category.difference_cents != null && category.difference_cents > 0 ? 'is-attention' : category.difference_cents != null && category.difference_cents < 0 ? 'is-good' : undefined}>
                                {category.difference_cents != null
                                  ? formatSpendingVariance(category.difference_cents)
                                  : '—'}
                              </dd>
                            </div>
                            <div>
                              <dt>Vs. prior</dt>
                              <dd>
                                {category.change_from_prior_cents != null
                                  ? formatSignedDelta(category.change_from_prior_cents)
                                  : '—'}
                              </dd>
                            </div>
                          </dl>

                          {category.active && onAdjustCategory && (
                            <div className="monthly-close-category-action">
                              <button
                                type="button"
                                className="ui-btn ui-btn--tonal monthly-close-adjust-btn"
                                disabled={Boolean(planningBlockedReason)}
                                aria-label={`Adjust plan for ${category.name}`}
                                onClick={() => onAdjustCategory(category.id)}
                              >
                                Adjust plan
                              </button>
                            </div>
                          )}
                        </li>
                      ))}
                    </ul>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}
    </section>
  )
}
