import { afterEach, expect, it, vi } from 'vitest'
import { removeCoachGroupParticipant, setActiveCoachWorkspaceId, setAuthTokenGetter } from './api'
afterEach(() => { vi.unstubAllGlobals(); setActiveCoachWorkspaceId(null); setAuthTokenGetter(null) })
it('withdraws exactly one selected program enrollment using a parsed JSON snapshot', async () => {
  const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ removed: true, cohort_id: 10 }), { status: 200 }))
  vi.stubGlobal('fetch', fetch)
  setActiveCoachWorkspaceId(2)
  setAuthTokenGetter(async () => 'test-token')
  expect(await removeCoachGroupParticipant(10, 40, 100)).toEqual({ removed: true, cohort_id: 10 })
  const [url, options] = fetch.mock.calls[0]
  expect(url).toContain('/api/v1/admin/cohorts/10/participants/40')
  expect(options.method).toBe('DELETE')
  expect(options.headers['Content-Type']).toBe('application/json')
  expect(options.headers['X-Coach-Workspace-Id']).toBe('2')
  expect(JSON.parse(options.body)).toEqual({ expected_membership_id: 100 })
})
