import { formatReviewMoney } from './reviewMoney'

export function cashCoverage(cashCents: number, candidates: { covers_cents: number; label: string }[]) {
  const partial = candidates.filter(candidate => candidate.covers_cents < cashCents)
  if (partial.length) return partial.map(candidate => `Choosing ${candidate.label}: ${formatReviewMoney(candidate.covers_cents)} already counted; the other ${formatReviewMoney(cashCents - candidate.covers_cents)} still counts on its own.`).join(' ')
  return `Your cash already counted when you took it out, so ${candidates.length === 1 ? 'Yes doesn’t' : 'choosing it doesn’t'} add to your spending.`
}
