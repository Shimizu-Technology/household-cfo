import { afterEach, expect, it, vi } from 'vitest'
import {
  eraseDailyReflection,
  fetchDailyEraseStatus,
  fetchDailyRequestStatus,
  fetchDailyContext,
  fetchDailyCandidates,
  fetchDailyPage,
  mutateDaily,
  setAuthTokenGetter,
} from '../api'
afterEach(() => {
  vi.unstubAllGlobals()
  setAuthTokenGetter(null)
})
it('authenticates exact daily action and erasure inputs without cohort claims or query keys', async () => {
  const fetch = vi
    .fn()
    .mockImplementation(async () => new Response('{}', { headers: { 'Content-Type': 'application/json' } }))
  vi.stubGlobal('fetch', fetch)
  setAuthTokenGetter(async () => 'fictional-auth')
  const body = {
    local_on: '2026-09-28',
    spending_state: 'unknown',
    accepted: true,
    expected_version_id: null,
    expected_head_lock_version: 0,
  }
  await mutateDaily('check_in_save', body, 'same-request')
  await eraseDailyReflection(
    600,
    { erase_accepted: true, expected_version_id: 601, expected_head_lock_version: 3 },
    'erase-key'
  )
  expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual(body)
  expect(JSON.parse(fetch.mock.calls[1][1].body)).toEqual({
    erase_accepted: true,
    expected_version_id: 601,
    expected_head_lock_version: 3,
  })
  expect(new Headers(fetch.mock.calls[0][1].headers).get('Authorization')).toBe('Bearer fictional-auth')
  expect(new Headers(fetch.mock.calls[1][1].headers).get('Idempotency-Key')).toBe('erase-key')
  expect(fetch.mock.calls[1][1].cache).toBe('no-store')
  expect(fetch.mock.calls[1][0]).not.toContain('erase-key')
})
it('keeps recovery keys in headers and reflection lookup bounded to the purchase', async () => {
  const fetch = vi
    .fn()
    .mockImplementation(async () => new Response('{}', { headers: { 'Content-Type': 'application/json' } }))
  vi.stubGlobal('fetch', fetch)
  await fetchDailyRequestStatus('purchase_approve', 'approval-key')
  await fetchDailyEraseStatus(600, 'erase-key')
  await fetchDailyPage('reflections', null, 200)
  await fetchDailyContext()
  expect(new URL(fetch.mock.calls[0][0]).search).toBe('?review_action=purchase_approve')
  expect(new Headers(fetch.mock.calls[1][1].headers).get('Idempotency-Key')).toBe('erase-key')
  expect(new URL(fetch.mock.calls[2][0]).searchParams.get('parent_id')).toBe('200')
  expect(new URL(fetch.mock.calls[3][0]).search).toBe('')
})

it('omits the first-page cursor and carries only a real next-page identity', async () => {
  const fetch = vi
    .fn()
    .mockImplementation(async () => new Response('{}', { headers: { 'Content-Type': 'application/json' } }))
  vi.stubGlobal('fetch', fetch)
  await fetchDailyPage('purchases', null)
  await fetchDailyCandidates('2026-10-05', null)
  await fetchDailyPage('purchases', 50)
  await fetchDailyCandidates('2026-10-05', 70)
  expect(new URL(fetch.mock.calls[0][0]).searchParams.has('cursor')).toBe(false)
  expect(new URL(fetch.mock.calls[1][0]).searchParams.has('cursor')).toBe(false)
  expect(new URL(fetch.mock.calls[2][0]).searchParams.get('cursor')).toBe('50')
  expect(new URL(fetch.mock.calls[3][0]).searchParams.get('cursor')).toBe('70')
})
