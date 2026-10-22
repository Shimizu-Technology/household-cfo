import type { IncomeTimelineSource } from '../api'
import { guamTodayIso } from '../lib/householdDate'
export const currency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })
export const cadenceOptions = ['weekly', 'biweekly', 'semi_monthly', 'monthly', 'annual']
export function titleize(value: string) { return value.replace(/_/g, ' ').replace(/\b\w/g, letter => letter.toUpperCase()) }
export function formatMonthYear(value: string) {
  const [year, month] = value.split('-').map(Number)
  return year && month ? new Intl.DateTimeFormat('en-US', { month: 'short', year: 'numeric', timeZone: 'UTC' }).format(new Date(Date.UTC(year, month - 1, 1))) : 'Choose a month'
}
export function guamCurrentMonthIso() { return guamTodayIso().slice(0, 7) }

export function effectiveIncomeTerms(source: IncomeTimelineSource) {
  const today = guamTodayIso()
  const latest = source.schedule_entries
    .filter((entry) => entry.active !== false && entry.entry_type === 'recurring_change' && entry.effective_on <= today)
    .sort((left, right) => right.effective_on.localeCompare(left.effective_on))[0]
  return {
    amount: latest?.amount ?? source.base_amount,
    cadence: latest?.cadence ?? source.base_cadence,
  }
}

export function monthlyIncomeAmount(source: IncomeTimelineSource) {
  if (source.current_monthly_amount !== undefined) return source.current_monthly_amount
  const terms = effectiveIncomeTerms(source)
  const multipliers: Record<string, number> = { weekly: 52 / 12, biweekly: 26 / 12, semi_monthly: 2, monthly: 1, annual: 1 / 12 }
  return terms.amount * (multipliers[terms.cadence] ?? 1)
}

export function incomeSourceIsCurrent(source: IncomeTimelineSource) {
  if (source.timeline_status) return source.timeline_status === 'current'
  if (source.active === false && !source.ends_on) return false
  const currentMonth = guamCurrentMonthIso()
  return (!source.starts_on || source.starts_on.slice(0, 7) <= currentMonth)
    && (!source.ends_on || source.ends_on.slice(0, 7) > currentMonth)
}

export function nextIncomeChange(source: IncomeTimelineSource) {
  const today = guamTodayIso()
  return source.schedule_entries
    .filter((entry) => entry.effective_on > today && incomeSourceEffectiveInMonth(source, entry.effective_on))
    .sort((left, right) => left.effective_on.localeCompare(right.effective_on))[0] ?? null
}

export function incomeSourceEffectiveInMonth(source: IncomeTimelineSource, value: string) {
  const month = value.slice(0, 7)
  if (!month) return false
  if (source.active === false && !source.ends_on && source.timeline_status !== 'future') return false
  return (!source.starts_on || source.starts_on.slice(0, 7) <= month)
    && (!source.ends_on || source.ends_on.slice(0, 7) > month)
}

