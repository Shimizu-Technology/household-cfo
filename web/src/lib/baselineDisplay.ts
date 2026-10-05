import type { BaselineSource } from './financialBaseline'

// Display only: repeated extraction fragments can repeat an identical reviewed
// account label. Never merge separate identities or distinct periods, and never
// alter the accounts or revision IDs sent for baseline approval.
export function uniqueBaselineAccountLabels(accounts: BaselineSource['accounts']): BaselineSource['accounts'] {
  const seen = new Set<string>()
  return accounts.filter((account) => {
    const key = JSON.stringify([account.tracked_account_id, account.label, account.period_start_on, account.period_end_on])
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}
