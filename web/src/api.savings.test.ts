import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { approveSavingsEntry, approveSavingsPlan, attestSavingsZero, enrollSavingsChallenge, fetchSavingsChallenge, fetchSavingsPage, setActiveCoachWorkspaceId, setAuthTokenGetter, stageSavingsEntry, stageSavingsPlan } from './api'
import { savingsFixture } from './test/savingsFixtures'
const response = (payload: unknown, status = 200) => new Response(JSON.stringify(payload), { status, headers: { 'Content-Type': 'application/json' } })
beforeEach(() => { setAuthTokenGetter(async () => 'fictional-token'); setActiveCoachWorkspaceId(42) })
afterEach(() => { setAuthTokenGetter(null); setActiveCoachWorkspaceId(null); vi.unstubAllGlobals() })
describe('participant challenge HTTP helpers', () => {
  it('sends flat bodies and caller-owned idempotency keys through all six authenticated operations', async () => {
    const fetchMock = vi.fn().mockImplementation(async () => response({ record: {}, replayed: false, challenge: savingsFixture() }))
    vi.stubGlobal('fetch', fetchMock)
    await enrollSavingsChallenge({ participation_accepted: true, policy_version: 'fictional-v1', late_start_accepted: false, expected_acceptance_digest: 'a'.repeat(64) }, 'join-key')
    await stageSavingsPlan({ target_cents: null, expected_plan_version_id: null }, 'plan-key')
    await approveSavingsPlan(11, { accepted: true, expected_draft_lock_version: 2, expected_plan_version_id: null }, 'plan-approve-key')
    await stageSavingsEntry({ signed_cents: -2550, effective_on: '2026-10-04', funding_source: 'withdrawal', expected_version_id: null }, 'entry-key')
    await approveSavingsEntry(31, { accepted: true, expected_draft_lock_version: 1, expected_version_id: 51, expected_entry_lock_version: 3 }, 'entry-approve-key')
    await attestSavingsZero({ known_zero: true, cutoff_on: '2026-10-04', expected_enrollment_lock_version: 2 }, 'zero-key')
    const paths = fetchMock.mock.calls.map(([url]) => new URL(String(url)).pathname)
    expect(paths).toEqual(['/api/v1/savings_challenge/enrollment', '/api/v1/savings_challenge/plan_drafts', '/api/v1/savings_challenge/plan_drafts/11/approve', '/api/v1/savings_challenge/entry_drafts', '/api/v1/savings_challenge/entry_drafts/31/approve', '/api/v1/savings_challenge/zero_attestations'])
    for (const [, options] of fetchMock.mock.calls) expect((options as RequestInit).headers).toMatchObject({ Authorization: 'Bearer fictional-token', 'X-Coach-Workspace-Id': '42' })
    expect(JSON.parse((fetchMock.mock.calls[3][1] as RequestInit).body as string)).toEqual({ signed_cents: -2550, effective_on: '2026-10-04', funding_source: 'withdrawal', expected_version_id: null })
    expect((fetchMock.mock.calls[4][1] as RequestInit).headers).toMatchObject({ 'Idempotency-Key': 'entry-approve-key' })
  })
  it('rejects missing identity, invalid records and invalid pages before reading or approving', async () => {
    const fetchMock = vi.fn(); vi.stubGlobal('fetch', fetchMock)
    await expect(stageSavingsPlan({ target_cents: null, expected_plan_version_id: null }, '')).rejects.toThrow('identity')
    expect(() => approveSavingsPlan(-1, { accepted: true, expected_draft_lock_version: 0, expected_plan_version_id: null }, 'valid-key')).toThrow('valid savings record')
    await expect(fetchSavingsPage('entries', -1)).rejects.toThrow('Invalid savings history page')
    expect(fetchMock).not.toHaveBeenCalled()
  })
  it('uses bounded stable cursor pages with refreshed workspace identity', async () => {
    const fetchMock = vi.fn().mockResolvedValue(response({ records: [{ id: 41 }], next_cursor: 41 })); vi.stubGlobal('fetch', fetchMock)
    setActiveCoachWorkspaceId(43)
    await fetchSavingsPage('entries', 31)
    expect(String(fetchMock.mock.calls[0][0])).toMatch(/entries\?limit=10&cursor=31$/)
    expect((fetchMock.mock.calls[0][1] as RequestInit).headers).toMatchObject({ 'X-Coach-Workspace-Id': '43' })
  })
  it('rejects missing approved amounts instead of interpreting them as zero', async () => {
    const fixture = savingsFixture(); fixture.projection = { ...fixture.projection!, reporting_known: true, reported_cents: null }
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(response(fixture)))
    await expect(fetchSavingsChallenge()).rejects.toThrow('incomplete')
  })
  it('rejects oversized or non-advancing history instead of dropping rows or looping', async () => {
    const fetchMock = vi.fn().mockResolvedValueOnce(response({ records: Array.from({ length: 11 }, (_, id) => ({ id: id + 1 })), next_cursor: 11 })).mockResolvedValueOnce(response({ records: [{ id: 31 }], next_cursor: 31 })); vi.stubGlobal('fetch', fetchMock)
    await expect(fetchSavingsPage('entries')).rejects.toThrow('could not be verified')
    await expect(fetchSavingsPage('entries', 31)).rejects.toThrow('could not be verified')
  })
})
