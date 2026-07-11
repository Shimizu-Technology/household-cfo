import type { BudgetData, DashboardData, ReadinessMilestone } from '../api'
import { Metric } from './Metric'

const currency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })

const statusCopy: Record<string, string> = {
  green: 'steady',
  yellow: 'watch',
  red: 'pause',
  blue: 'context',
  gold: 'build',
}

type HomeScreenProps = {
  dashboard: DashboardData
  budget: BudgetData
  onAskMia: () => void
  onReviewTransactions: () => void
  onReviewMiaActions: () => void
}

export function HomeScreen({ dashboard, budget, onAskMia, onReviewTransactions, onReviewMiaActions }: HomeScreenProps) {
  const actionCenter = dashboard.action_center
  const currentPlan = budget.annual_plan?.year === actionCenter.current_year ? budget.annual_plan : null
  const currentMonthIndex = Math.max(0, Math.min(11, actionCenter.current_month_index))
  const monthPlanned = currentPlan?.rows.reduce((sum, row) => sum + (row.months[currentMonthIndex]?.planned ?? 0), 0) ?? 0
  const monthActual = currentPlan?.rows.reduce((sum, row) => sum + (row.months[currentMonthIndex]?.actual ?? 0), 0) ?? 0
  const annualPlanned = currentPlan?.rows.reduce((sum, row) => sum + row.months.reduce((monthSum, month) => monthSum + month.planned, 0), 0) ?? 0
  const annualActual = currentPlan?.rows.reduce((sum, row) => sum + row.months.reduce((monthSum, month) => monthSum + month.actual, 0), 0) ?? 0
  const upcomingSpike = currentPlan?.annual_outlook?.upcoming_spikes[0]
  const nextIrregular = currentPlan?.annual_outlook?.next_irregular_month

  return (
    <section className="screen-grid home-screen">
      <div className="screen-heading">
        <p className="eyebrow">Home</p>
        <h2>CFO snapshot</h2>
        <p>Review what needs your call, see where the month sits inside the annual plan, and make one next move.</p>
      </div>

      <section className="home-action-center" aria-label="Household CFO action center">
        <article className={`home-review-card ${actionCenter.total_review_count > 0 ? 'has-reviews' : 'is-clear'}`}>
          <span>What needs review?</span>
          <strong>{actionCenter.total_review_count}</strong>
          <p>{actionCenter.total_review_count === 0 ? 'You are caught up. New transactions and Mia changes will wait here for your approval.' : 'Pending items do not change actuals or the plan until you approve them.'}</p>
          <div className="home-review-actions">
            {actionCenter.transaction_review_count > 0 && <button type="button" onClick={onReviewTransactions}>Review {actionCenter.transaction_review_count} transaction{actionCenter.transaction_review_count === 1 ? '' : 's'}</button>}
            {actionCenter.mia_action_review_count > 0 && <button type="button" className="subtle" onClick={onReviewMiaActions}>Review {actionCenter.mia_action_review_count} Mia change{actionCenter.mia_action_review_count === 1 ? '' : 's'}</button>}
          </div>
        </article>

        <article className="home-period-card">
          <span>{actionCenter.current_month_label} {actionCenter.current_year}</span>
          <h3>Month-to-date inside the annual plan</h3>
          <div className="home-period-metrics">
            <Metric label="Month planned" value={currency.format(monthPlanned)} />
            <Metric label="Month actual" value={currency.format(monthActual)} />
            <Metric label="Annual planned" value={currency.format(annualPlanned)} />
            <Metric label="Annual actual" value={currency.format(annualActual)} />
          </div>
        </article>
      </section>

      {(upcomingSpike || nextIrregular) && (
        <section className="home-look-ahead" aria-label="Annual plan look ahead">
          <div>
            <span>Look ahead</span>
            <h3>The next annual-plan pressure is visible now.</h3>
          </div>
          {upcomingSpike && (
            <article>
              <span>{upcomingSpike.label} spending spike</span>
              <strong>{currency.format(upcomingSpike.planned_outflow)} planned</strong>
              <p>{currency.format(upcomingSpike.amount_above_typical ?? 0)} above a typical planned month.</p>
            </article>
          )}
          {nextIrregular && (
            <article>
              <span>{nextIrregular.label} expected irregular plan</span>
              <strong>{currency.format(nextIrregular.expected_irregular)}</strong>
              <p>{nextIrregular.expected_contributors.map((item) => item.name).join(' · ') || 'Expected sinking funds'}</p>
            </article>
          )}
        </section>
      )}

      <div className={`status-ribbon ${dashboard.summary.readiness_tone}`}>
        <div>
          <span>Readiness</span>
          <strong>{dashboard.summary.readiness_label}</strong>
        </div>
        <p>Red means stabilize basics first. Yellow means cash flow is close but runway still needs protection. Green means target runway and positive monthly surplus are both in place.</p>
      </div>

      <section className="readiness-path-panel" aria-labelledby="readiness-path-title">
        <div className="readiness-path-heading">
          <div>
            <p className="eyebrow">Annual runway</p>
            <h3 id="readiness-path-title">Your path from Red to Yellow to Green</h3>
          </div>
          <p>Yellow is the halfway runway checkpoint. Green is the full runway target. They are planning signals, not grades.</p>
        </div>
        <div className="readiness-current-row">
          <Metric label="Protected liquid" value={currency.format(dashboard.readiness_path.protected_liquid_amount)} />
          <Metric label="Current runway" value={`${dashboard.readiness_path.current_runway_months} months`} />
          <Metric label="Monthly surplus" value={currency.format(dashboard.readiness_path.monthly_surplus)} />
          <Metric label="Full target" value={`${dashboard.readiness_path.target_runway_months} months`} />
        </div>
        <div className="readiness-milestone-grid">
          <ReadinessMilestoneCard label="Yellow checkpoint" milestone={dashboard.readiness_path.yellow} />
          <ReadinessMilestoneCard label="Green target" milestone={dashboard.readiness_path.green} />
        </div>
      </section>

      <div className="metric-row">
        <Metric label="Monthly income" value={currency.format(dashboard.summary.monthly_income)} />
        <Metric label="Runway" value={`${dashboard.summary.runway_months} months`} />
        <Metric label="Safe to spend" value={currency.format(dashboard.summary.next_safe_to_spend_amount)} />
        <Metric label="Baseline surplus" value={currency.format(budget.baseline_surplus)} />
      </div>

      <div className="two-column">
        <article className={`panel coach-panel ${dashboard.summary.readiness_tone}`}>
          <p className="eyebrow">One next move</p>
          <h3>{dashboard.coach_read.title}</h3>
          <p>{dashboard.coach_read.body}</p>
          <button type="button" onClick={onAskMia}>Ask Mia for my next move</button>
        </article>
        <div className="card-list">
          {dashboard.alerts.map((alert) => (
            <article className={`insight-card ${alert.tone}`} key={alert.title}>
              <span>{statusCopy[alert.tone] ?? 'note'}</span>
              <h3>{alert.title}</h3>
              <p>{alert.body}</p>
            </article>
          ))}
        </div>
      </div>

      <article className="panel next-steps">
        <h3>This week’s household CFO rhythm</h3>
        <ol>
          {dashboard.next_steps.map((step) => <li key={step}>{step}</li>)}
        </ol>
      </article>
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
