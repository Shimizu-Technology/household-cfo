/** Keep the cushion useful to read, even for exceptionally large balances. */
export function formatRunway(months: number) {
  if (months > 60) return 'More than 5 years of breathing room'
  const rounded = new Intl.NumberFormat('en-US', { maximumFractionDigits: 1 }).format(months)
  return `${rounded} ${rounded === '1' ? 'month' : 'months'} of breathing room`
}
