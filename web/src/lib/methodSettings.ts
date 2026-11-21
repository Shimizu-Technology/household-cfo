import type { CohortExperienceDraft, MethodCoreProtectedCategory, MethodOptionalProtectedCategory, MethodPriority, MethodProtectedCategory, MethodSettings, MethodWindfallStep } from '../api'

/** Mrs. Mel's method. Mirrors CohortExperience::MethodSettings::DEFAULTS in the API. */
export const defaultMethod: MethodSettings = {
  status: { target_green_months: 12, target_yellow_months: 36, surplus_green_cents: 100_000, surplus_yellow_cents: 50_000 },
  emergency_fund_months: 3,
  protected: ['housing', 'utilities', 'medical', 'childcare_school', 'debt_minimums', 'family_support'],
  priorities: ['emergency_fund', 'debt', 'wealth', 'experiences'],
  windfall: ['emergency_fund', 'consumer_debt', 'surplus'],
  income_split: { emergency_fund: 50, debt: 25, surplus: 25 },
}

/** Never suggested as cuts in any program; a coach can add to these, not remove them. */
export const coreProtected: MethodCoreProtectedCategory[] = ['housing', 'utilities', 'medical', 'childcare_school', 'debt_minimums', 'family_support']
export const optionalProtected: MethodOptionalProtectedCategory[] = ['groceries', 'giving', 'community']

export const protectedLabels: Record<MethodProtectedCategory, string> = {
  housing: 'Housing',
  utilities: 'Utilities',
  medical: 'Medical',
  childcare_school: 'Childcare and school',
  debt_minimums: 'Debt minimums',
  family_support: 'Family support',
  groceries: 'Groceries',
  giving: 'Giving (tithes and donations)',
  community: 'Family & community',
}

export const priorityLabels: Record<MethodPriority, string> = {
  emergency_fund: 'Emergency fund',
  debt: 'Debt acceleration',
  wealth: 'Wealth building',
  experiences: 'Experiences and life',
}

export const windfallLabels: Record<MethodWindfallStep, string> = {
  emergency_fund: 'Fill the emergency fund gap',
  consumer_debt: 'Pay down consumer debt (cards and loans, not the mortgage)',
  surplus: 'Keep the rest as surplus',
}

export const splitLabels = { emergency_fund: 'Emergency fund', debt: 'Extra debt payments', surplus: 'Surplus' } as const

/** The method a draft gives participants; before schema 5 it is the default. */
export function methodOf(draft: Pick<CohortExperienceDraft, 'schema_version' | 'method'> | null | undefined): MethodSettings {
  return draft?.schema_version === 5 && draft.method ? draft.method : defaultMethod
}

const whole = (value: number, min: number, max: number) => Number.isInteger(value) && value >= min && value <= max

/** Plain-language problems a coach must fix before saving; the API checks the same rules. */
export function methodProblems(method: MethodSettings): string[] {
  const problems: string[] = []
  const { status, income_split: split } = method
  if (!whole(status.target_green_months, 1, 119) || !whole(status.target_yellow_months, status.target_green_months + 1, 120)) {
    problems.push('Use whole months from 1 to 120, with yellow longer than green.')
  }
  if (!whole(status.surplus_yellow_cents, 0, 10_000_000) || !whole(status.surplus_green_cents, status.surplus_yellow_cents, 10_000_000) || status.surplus_yellow_cents % 100 !== 0 || status.surplus_green_cents % 100 !== 0) {
    problems.push('Use whole dollars up to $100,000 for the surplus colours, with green at or above yellow.')
  }
  if (!whole(method.emergency_fund_months, 1, 24)) problems.push('Set the emergency fund target to 1–24 months.')
  if (coreProtected.some(key => !method.protected.includes(key))) problems.push('Housing, utilities, medical, childcare and school, debt minimums and family support are always protected.')
  if (![split.emergency_fund, split.debt, split.surplus].every(value => whole(value, 0, 100)) || split.emergency_fund + split.debt + split.surplus !== 100) {
    problems.push('The new income split must be whole percentages that add up to 100%.')
  }
  return problems
}

const dollars = (cents: number) => `$${(cents / 100).toLocaleString('en-US')}`

/** One line per changed setting, for the Go live review. */
export function methodChanges(previous: MethodSettings, next: MethodSettings): string[] {
  const changes: string[] = []
  const before = previous.status
  const after = next.status
  if (before.target_green_months !== after.target_green_months || before.target_yellow_months !== after.target_yellow_months) {
    changes.push(`Method: goals are green within ${after.target_green_months} months and yellow within ${after.target_yellow_months} months (was ${before.target_green_months} and ${before.target_yellow_months}).`)
  }
  if (before.surplus_green_cents !== after.surplus_green_cents || before.surplus_yellow_cents !== after.surplus_yellow_cents) {
    changes.push(`Method: monthly surplus is green from ${dollars(after.surplus_green_cents)} and yellow from ${dollars(after.surplus_yellow_cents)} (was ${dollars(before.surplus_green_cents)} and ${dollars(before.surplus_yellow_cents)}).`)
  }
  if (previous.emergency_fund_months !== next.emergency_fund_months) {
    changes.push(`Method: emergency fund target is ${next.emergency_fund_months} months of planned costs (was ${previous.emergency_fund_months}).`)
  }
  const added = next.protected.filter(key => !previous.protected.includes(key)).map(key => protectedLabels[key])
  const removed = previous.protected.filter(key => !next.protected.includes(key)).map(key => protectedLabels[key])
  if (added.length) changes.push(`Method: ${added.join(', ')} ${added.length === 1 ? 'is' : 'are'} never suggested as cuts.`)
  if (removed.length) changes.push(`Method: ${removed.join(', ')} can be suggested as cuts again.`)
  if (previous.priorities.join() !== next.priorities.join()) changes.push(`Method: priority order is ${next.priorities.map((key, index) => `${index + 1} ${priorityLabels[key]}`).join(' · ')}.`)
  if (previous.windfall.join() !== next.windfall.join()) changes.push(`Method: one-time money goes to ${next.windfall.map(key => windfallLabels[key].toLowerCase()).join(', then ')}.`)
  const split = next.income_split
  if (JSON.stringify(previous.income_split) !== JSON.stringify(split)) changes.push(`Method: new monthly income splits ${split.emergency_fund}% emergency fund, ${split.debt}% extra debt payments, ${split.surplus}% surplus.`)
  return changes
}
