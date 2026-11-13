import type { CSSProperties } from 'react'
import { guamTodayIso } from '../lib/householdDate'
import type { AnnualBudgetPlan, AnnualOutlookMonth } from '../api'
import { formatReviewMoney } from '../lib/reviewMoney'

const money = (dollars: number) => formatReviewMoney(Math.round(dollars * 100))
const signature = (month: AnnualOutlookMonth) => JSON.stringify([month.income, month.planned_outflow, month.expected_irregular, month.expected_contributors])

/** Group the steady months so irregular costs and shortfalls have room to stand out. */
export function YearOutlook({ plan, moneyKnown = true, currentMonth = Number(guamTodayIso().slice(5, 7)) }: { plan: AnnualBudgetPlan; moneyKnown?: boolean; currentMonth?: number }) {
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
  const values = months.flatMap(month => month.baseline_surplus == null ? [] : [month.baseline_surplus])
  const maximum = Math.max(1, ...values.map(Math.abs))
  const tightest = months.reduce<AnnualOutlookMonth | null>((tight, month) => month.baseline_surplus != null && (!tight || month.baseline_surplus < tight.baseline_surplus!) ? month : tight, null)
  const differs = new Set(values).size > 1
  const tightMonth = tightest && new Intl.DateTimeFormat('en', { month: 'long', timeZone: 'UTC' }).format(new Date(`${tightest.starts_on}T00:00:00Z`))
  return <section className="year-outlook annual-outlook ui-card" aria-label="Year outlook">
    <h3>Your {plan.year} outlook</h3>
    {startMonth && <p>Your plan starts in {startMonth}.</p>}
    {!known ? <p>Add the remaining numbers to see your year ahead.</p> : <>
      <p>{groups.length === 1 ? 'Your plan is steady across these months.' : 'Look ahead to the months when your plan changes.'}</p>
      {months.length >= 4 && <div className="ui-cols home-year-columns" aria-hidden="true" style={{ '--columns': months.length } as CSSProperties}>
        {months.map(month => <div key={month.period_id} className={`ui-cols__column${Number(month.starts_on.slice(5, 7)) === currentMonth ? ' ui-cols__column--current' : ''}${differs && month === tightest ? ' ui-cols__column--attention' : ''}`}>
          <span className="ui-cols__bar" style={{ '--value': `${month.baseline_surplus == null ? 0 : Math.abs(month.baseline_surplus) / maximum * 100}%` } as CSSProperties} />
          <span className="ui-cols__label">{month.label.slice(0, 1)}</span>
        </div>)}
      </div>}
      {differs && tightest && <p className="home-tight-month">{tightMonth} is your tight month: {money(Math.abs(tightest.baseline_surplus!))} {tightest.baseline_surplus! < 0 ? 'short' : 'left'} after {tightest.expected_contributors.length > 0 ? `${money(tightest.expected_contributors.reduce((sum, cost) => sum + cost.amount, 0))} for ${tightest.expected_contributors.map(cost => cost.name).join(' and ')}` : `${money(tightest.planned_outflow)} planned out`}.</p>}
      <ul className="year-outlook-months">{groups.map(group => {
        const first = group.months[0]
        const last = group.months.at(-1)!
        return <li key={first.period_id} className={first.baseline_surplus != null && first.baseline_surplus < 0 ? 'is-short' : ''}>
          <div><strong>{first.label}{first !== last ? `–${last.label}` : ''}</strong><span>{first.baseline_surplus == null ? 'Income not known yet' : <>{money(Math.abs(first.baseline_surplus))} {first.baseline_surplus < 0 ? 'short' : 'left'}{first !== last ? ' each month' : ''}</>}</span></div>
          {first.baseline_surplus != null && <i className="ui-track home-outlook-track" aria-hidden="true"><span className="ui-track__fill" data-reveal-key={`year-${plan.year}-${first.period_id}`} style={{ '--value': `${Math.abs(first.baseline_surplus) / maximum * 100}%` } as CSSProperties} /></i>}
          <p>{money(first.planned_outflow)} planned out{first.income == null ? ' · money in not known yet' : ` · ${money(first.income)} money in`}</p>
          {first.expected_contributors.length > 0 && <p>{first.expected_contributors.map(item => `${item.name}: ${money(item.amount)}`).join(' · ')}</p>}
        </li>
      })}</ul>
    </>}
  </section>
}
