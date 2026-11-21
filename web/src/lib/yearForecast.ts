import type { YearForecast } from '../api'
import { formatReviewMoney } from './reviewMoney'

/** A saved date in words; the year only when asked for. */
export const billDate = (value: string, withYear = true) => {
  const parsed = new Date(`${value}T00:00:00Z`)
  return Number.isNaN(parsed.getTime()) ? 'date not entered' : new Intl.DateTimeFormat('en', { month: 'long', day: 'numeric', ...(withYear ? { year: 'numeric' } : {}), timeZone: 'UTC' }).format(parsed)
}
/** One plain sentence for the first short month, or why there isn't one. Home and Budget both use it. */
export function forecastHeadline(forecast: YearForecast) {
  const short = forecast.first_short_month
  if (short) return `${short.label} may run short: cash would end about ${formatReviewMoney(-short.ending_cents!)} below zero.`
  if (forecast.status === 'no_short_month') return 'No month runs short through December.'
  return 'We can’t tell yet whether a month runs short.'
}

/** Which estimates a known answer rests on, so "no month runs short" is never read as certain. Empty when none. */
export function forecastEstimates(forecast: YearForecast) {
  if (forecast.status === 'unknown') return ''
  const reasons = forecast.estimate_reasons ?? []
  if (reasons.length) return `This rests on estimates: ${listWords(reasons)}.`
  const flagged = forecast.first_short_month?.includes_estimates || forecast.months.some(month => month.includes_estimates)
  return flagged ? 'Some of these amounts are estimates.' : ''
}

const listWords = (items: string[]) => items.length < 3 ? items.join(' and ') : `${items.slice(0, -1).join(', ')}, and ${items.at(-1)}`

/** Words for what is still missing, or the cash-balance note when that is the gap. */
export function forecastUnknown(forecast: YearForecast) {
  return [forecast.starting_cash_cents == null ? forecast.starting_note : '', forecast.missing.length ? `Still needed: ${forecast.missing.join(', ')}.` : ''].filter(Boolean).join(' ')
}
