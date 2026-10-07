// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest'
import { ApiRequestError, fetchCurrentUser, setAuthTokenGetter } from './api'
afterEach(() => { setAuthTokenGetter(null); vi.unstubAllGlobals() })
it('invalidates a signed-in session on API 401 while treating denied access separately', async () => {
  const expired = vi.fn()
  window.addEventListener('household-cfo:auth-expired', expired)
  setAuthTokenGetter(async () => 'verified-token')
  vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(Response.json({ error: 'Not authorized' }, { status: 401 })).mockResolvedValueOnce(Response.json({ error: 'Program denied' }, { status: 403 })))
  try {
    await expect(fetchCurrentUser()).rejects.toMatchObject({ status: 401 })
    expect(expired).toHaveBeenCalledOnce()
    await expect(fetchCurrentUser()).rejects.toMatchObject({ status: 403 })
    expect(expired).toHaveBeenCalledOnce()
  } finally { window.removeEventListener('household-cfo:auth-expired', expired) }
})

it('propagates a temporary SDK token outage as 503 without sending an unauthenticated request', async () => {
  const fetch = vi.fn()
  vi.stubGlobal('fetch', fetch)
  setAuthTokenGetter(async () => { throw new ApiRequestError('Secure sign-in is temporarily unavailable', { status: 503 }) })
  await expect(fetchCurrentUser()).rejects.toMatchObject({ status: 503 })
  expect(fetch).not.toHaveBeenCalled()
})
