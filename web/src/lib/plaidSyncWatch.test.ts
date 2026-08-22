import { describe, expect, it } from 'vitest'
import type { PlaidItem } from '../api'
import { plaidSyncOutcome } from './plaidSyncWatch'

function item(values: Partial<PlaidItem> = {}): PlaidItem {
  return {
    id: 7,
    institution_name: 'Sandbox Bank',
    status: 'active',
    environment: 'sandbox',
    consented_at: '2026-08-22T00:00:00Z',
    last_synced_at: null,
    health: {
      state: 'initializing',
      label: 'Preparing history',
      message: 'The first transaction history sync is still being prepared.',
      requires_attention: false,
      last_successful_update_at: null,
      stale_after: '2026-08-23T00:00:00Z',
    },
    error_message: null,
    disconnected_at: null,
    auto_confirm_trusted_merchants: false,
    accounts: [],
    ...values,
  }
}

describe('Plaid sync completion detection', () => {
  it('waits for an initial item until its first successful sync arrives', () => {
    expect(plaidSyncOutcome(item(), null)).toBe('waiting')
    expect(plaidSyncOutcome(item({ last_synced_at: '2026-08-22T01:00:00Z' }), null)).toBe('complete')
  })

  it('requires a newer timestamp for a repeat sync', () => {
    const previous = '2026-08-22T01:00:00Z'
    expect(plaidSyncOutcome(item({ last_synced_at: previous }), previous)).toBe('waiting')
    expect(plaidSyncOutcome(item({ last_synced_at: '2026-08-22T02:00:00Z' }), previous)).toBe('complete')
  })

  it('stops when the item fails or disappears', () => {
    expect(plaidSyncOutcome(item({ status: 'error' }), null)).toBe('failed')
    expect(plaidSyncOutcome(undefined, null)).toBe('missing')
  })
})
