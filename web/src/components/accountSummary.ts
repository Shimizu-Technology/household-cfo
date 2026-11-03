import { formatReviewMoney } from '../lib/reviewMoney'

export function accountSummaryText(value: number, known: boolean, knownCount: number, accountCount: number) {
  if (known) return formatReviewMoney(Math.round((value) * 100))
  if (knownCount > 0) return `${formatReviewMoney(Math.round((value) * 100))} known so far`
  return accountCount > 0 ? 'Needs a balance' : 'Not entered'
}
