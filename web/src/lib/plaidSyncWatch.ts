import type { PlaidItem } from '../api'

export type PlaidSyncOutcome = 'waiting' | 'complete' | 'failed' | 'missing'

export function plaidSyncOutcome(item: PlaidItem | undefined, baselineLastSyncedAt: string | null): PlaidSyncOutcome {
  if (!item) return 'missing'
  if (item.status === 'error' || item.status === 'update_required' || item.status === 'disconnecting' || item.status === 'disconnected') return 'failed'
  if (item.last_synced_at && item.last_synced_at !== baselineLastSyncedAt) return 'complete'

  return 'waiting'
}
