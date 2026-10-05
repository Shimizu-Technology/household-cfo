import { afterEach, expect, it, vi } from 'vitest'
import { setAuthTokenGetter } from '../api'
import { fetchSavingsEvidenceCandidates, fetchSavingsEvidenceStatus, mutateSavingsEvidence } from '../evidenceApi'
afterEach(() => {
  vi.unstubAllGlobals()
  setAuthTokenGetter(null)
})
it('uses ordinary authenticated no-store transport with exact body and request key only in headers', async () => {
  const fetch = vi.fn().mockImplementation(async () => new Response(JSON.stringify({})))
  vi.stubGlobal('fetch', fetch)
  setAuthTokenGetter(async () => 'fictional-auth')
  const input = {
    entry_version_id: 11,
    expected_evidence_version_id: null,
    expected_head_lock_version: 0,
    accepted: true as const,
    reason: 'Exact reviewed proof',
  }
  await mutateSavingsEvidence('revoke', input, 'same-key')
  await fetchSavingsEvidenceStatus('revoke', 11, 'same-key')
  await fetchSavingsEvidenceCandidates(11, 50)
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual(input)
  expect(new Headers(fetch.mock.calls[0][1].headers).get('Authorization')).toBe('Bearer fictional-auth')
  expect(new Headers(fetch.mock.calls[1][1].headers).get('Idempotency-Key')).toBe('same-key')
  expect(fetch.mock.calls[1][1].cache).toBe('no-store')
  expect(new URL(fetch.mock.calls[1][0]).search).toBe('?review_action=revoke&entry_version_id=11')
  expect(new URL(fetch.mock.calls[2][0]).search).toBe('?entry_version_id=11&cursor=50')
  expect(() => fetchSavingsEvidenceCandidates(-1)).toThrow()
})
