import type { ReactNode } from 'react'
import type { AnnualBudgetPlan } from '../api'
import { formatReviewMoney } from '../lib/reviewMoney'
import { forecastEstimates, forecastHeadline, forecastUnknown } from '../lib/yearForecast'

/** Home's one-glance year: the first short month and why, or that none runs short, or what is still unknown. Every month and the bills live in Budget. */
export function YearOutlook({ plan, moneyKnown = true, footer, onOpenBudget }: { plan: AnnualBudgetPlan; moneyKnown?: boolean; footer?: ReactNode; onOpenBudget?: () => void }) {
  const forecast = plan.year_forecast
  const short = forecast?.first_short_month
  const last = forecast?.months.at(-1)
  const estimates = forecast ? forecastEstimates(forecast) : ''
  const higher = forecast?.months.filter(month => month.higher_costs && month !== short).slice(0, 2) ?? []
  return <section className="year-outlook ui-card" aria-label="Year outlook">
    <h3>Your {plan.year} outlook</h3>
    {!forecast || !moneyKnown ? <p>Add the remaining numbers to see your year ahead.</p> : <>
      <p className={`year-outlook-headline${short ? ' is-short' : ''}`}>{forecastHeadline(forecast)}</p>
      {short && <p>Costs that month: {short.reasons.join(', ')}.</p>}
      {forecast.status === 'no_short_month' && last?.ending_cents != null && <p>{last.label} would end with about {formatReviewMoney(last.ending_cents)}.</p>}
      {estimates && <p className="year-outlook-estimates">{estimates}</p>}
      {forecast.status === 'unknown' && <p>{forecastUnknown(forecast)}</p>}
      {higher.length > 0 && <p>Higher costs than usual: {higher.map(month => `${month.label}${month.reasons.length ? ` (${month.reasons.slice(0, 2).join(', ')})` : ''}`).join('; ')}.</p>}
      {forecast.starting_cash_cents != null && <p className="year-outlook-note">{forecast.starting_note} This is a plan, not your bank balance.</p>}
    </>}
    {onOpenBudget && <button type="button" className="ui-btn ui-btn--tonal ui-btn--full" onClick={onOpenBudget}>See every month and your bills</button>}
    {footer}
  </section>
}
