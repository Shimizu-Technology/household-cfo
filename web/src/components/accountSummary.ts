const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })

export function accountSummaryText(value: number, known: boolean, knownCount: number, accountCount: number) {
  if (known) return money.format(value)
  if (knownCount > 0) return `${money.format(value)} known so far`
  return accountCount > 0 ? 'Needs a balance' : 'Not entered'
}
