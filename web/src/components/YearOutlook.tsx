import type { AnnualBudgetPlan, AnnualOutlookMonth } from '../api'
import { formatReviewMoney } from '../lib/reviewMoney'

const money = (dollars: number) => formatReviewMoney(Math.round(dollars * 100))
const signature = (month: AnnualOutlookMonth) => JSON.stringify([month.income, month.planned_outflow, month.expected_irregular, month.expected_contributors])

/** Group the steady months so irregular costs and shortfalls have room to stand out. */
export function YearOutlook({ plan, moneyKnown = true }: { plan: AnnualBudgetPlan; moneyKnown?: boolean }) {
  const known = moneyKnown && plan.monthly_debt_minimums_known !== false && plan.rows.every(row => row.active === false || (row.months.length === plan.months.length && row.months.every(month => !month.allocation_missing)))
  const months = plan.annual_outlook.months
  const startMonth = plan.plan_starts_on ? new Intl.DateTimeFormat('en', {month: 'long', year: 'numeric', timeZone: 'UTC'}).format(new Date(`${plan.plan_starts_on}T00:00:00Z`)) : null
  const groups: { months: AnnualOutlookMonth[]; signature: string }[] = []
  for (const month of months) {
    const key = signature(month)
    const last = groups.at(-1)
    if (last?.signature === key) last.months.push(month)
    else groups.push({ months: [month], signature: key })
  }
  return <section className="year-outlook annual-outlook" aria-label="Year outlook">
    <h3>Your {plan.year} outlook</h3>
    {startMonth && <p>Your plan starts in {startMonth}.</p>}
    {!known ? <p>Add the remaining numbers to see your year ahead.</p> : <>
      <p>{groups.length === 1 ? 'Your plan is steady across these months.' : 'Look ahead to the months when your plan changes.'}</p>
      <ul className="year-outlook-months">{groups.map(group => {
        const first = group.months[0]
        const last = group.months.at(-1)!
        return <li key={first.period_id} className={first.baseline_surplus != null && first.baseline_surplus < 0 ? 'is-short' : ''}>
          <div><strong>{first.label}{first !== last ? `–${last.label}` : ''}</strong><span>{first.baseline_surplus == null ? 'Income not known yet' : <>{money(Math.abs(first.baseline_surplus))} {first.baseline_surplus < 0 ? 'short' : 'left'}{first !== last ? ' each month' : ''}</>}</span></div>
          <p>{money(first.planned_outflow)} planned out{first.income == null ? ' · money in not known yet' : ` · ${money(first.income)} money in`}</p>
          {first.expected_contributors.length > 0 && <p>{first.expected_contributors.map(item => `${item.name}: ${money(item.amount)}`).join(' · ')}</p>}
        </li>
      })}</ul>
    </>}
  </section>
}
