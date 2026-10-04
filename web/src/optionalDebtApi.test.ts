import { beforeEach, describe, expect, it, vi } from 'vitest'
vi.mock('./api', () => ({ fetchPrivateJson: vi.fn() }))
import { fetchPrivateJson } from './api'
import { optionalDebtApi } from './optionalDebtApi'
import { debtFixtureScope, fictionalTerms } from './test/optionalDebtFixtures'
beforeEach(() => vi.clearAllMocks())
describe('private optional debt transport', () => {
  it('uses selected cohort, no-store and original request key without client actor or enrollment injection', async () => { await optionalDebtApi.mutate(debtFixtureScope, 'stage', { terms: fictionalTerms(), expected_version_id: null, expected_head_lock_version: 0, source_mapping: null, reason: '' }, 'original-key'); expect(fetchPrivateJson).toHaveBeenCalledWith('/api/v1/savings_challenge/debt/actions/stage', expect.objectContaining({ cache: 'no-store', headers: { 'X-Cohort-Id': '701', 'Idempotency-Key': 'original-key', 'Content-Type': 'application/json' }, body: expect.not.stringContaining('user_id') })); await optionalDebtApi.status(debtFixtureScope, 'approve', 'original-key'); expect(fetchPrivateJson).toHaveBeenLastCalledWith('/api/v1/savings_challenge/debt/request_status?review_action=approve', expect.objectContaining({ headers: { 'X-Cohort-Id': '701', 'Idempotency-Key': 'original-key' } })) })
  it('passes stable cursor and abort signal on scoped reads', async () => { const signal = new AbortController().signal; await optionalDebtApi.records(debtFixtureScope, 'versions', 50, signal); expect(fetchPrivateJson).toHaveBeenCalledWith('/api/v1/savings_challenge/debt/records?kind=versions&cursor=50', expect.objectContaining({ signal, cache: 'no-store', headers: { 'X-Cohort-Id': '701' } })) })
})
