// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError } from '../api'
import { BrowserSessionClient, captureBrowserAuthError, checkedBrowserAuthRedirect } from './browserAuthSession'
const clientId = 'client_FICTIONAL1'
const session = (id = 'user_FICTIONAL1') => ({ client_id: clientId, user: { id, first_name: 'Fictional', last_name: 'Person', email: 'fictional@pilot.test' }, organization_id: 'org_FICTIONAL1', authentication_method: 'SSO', access_token: `short-lived-${id}`, expires_at: new Date(Date.now() + 120_000).toISOString() })
const fetchMock = vi.fn()
beforeEach(() => { fetchMock.mockReset(); vi.stubGlobal('fetch', fetchMock) })
afterEach(() => { vi.unstubAllGlobals(); localStorage.clear(); sessionStorage.clear(); window.history.replaceState(null, '', '/') })
describe('same-origin browser session credentials', () => {
  it('loads a no-store same-origin session with explicit frontend origin and keeps JWT solely in memory', async () => {
    fetchMock.mockImplementation(async () => Response.json(session()))
    const client = new BrowserSessionClient(clientId)
    expect((await client.load())?.user.id).toBe('user_FICTIONAL1')
    expect(fetchMock).toHaveBeenCalledWith('/api/auth/session', expect.objectContaining({ credentials: 'same-origin', cache: 'no-store', headers: { 'X-Frontend-Origin': window.location.origin } }))
    expect(await client.getAccessToken()).toBe('short-lived-user_FICTIONAL1')
    expect(localStorage.length).toBe(0); expect(sessionStorage.length).toBe(0)
  })
  it('shares one concurrent session read so callers cannot double-consume rotating refresh credentials', async () => {
    let finish!: (response: Response) => void
    fetchMock.mockImplementation(() => new Promise(resolve => { finish = resolve }))
    const client = new BrowserSessionClient(clientId)
    const reads = [client.getAccessToken(), client.getAccessToken(), client.getAccessToken()]
    expect(fetchMock).toHaveBeenCalledOnce()
    finish(Response.json(session()))
    expect(await Promise.all(reads)).toEqual(Array(3).fill('short-lived-user_FICTIONAL1'))
  })
  it.each([{ ...session(), client_id: 'client_OTHER' }, { ...session(), refresh_token: 'must-never-be-exposed' }, { ...session(), expires_at: '2020-01-01' }])('rejects unverified or unsafe session payload', async payload => {
    fetchMock.mockResolvedValue(Response.json(payload))
    const client = new BrowserSessionClient(clientId)
    await expect(client.load()).rejects.toMatchObject({ status: 503 })
    expect(client.getSnapshot().session).toBeNull()
  })
  it('closes revoked sessions and keeps transient failures distinct for a successful retry', async () => {
    fetchMock.mockResolvedValueOnce(Response.json(session())).mockResolvedValueOnce(Response.json({}, { status: 503 })).mockResolvedValueOnce(Response.json(session())).mockResolvedValueOnce(Response.json({}, { status: 401 }))
    const client = new BrowserSessionClient(clientId)
    await client.load(); await expect(client.getAccessToken()).rejects.toMatchObject({ status: 503 })
    expect(client.getSnapshot().session?.user.id).toBe('user_FICTIONAL1')
    expect(await client.getAccessToken()).toBe('short-lived-user_FICTIONAL1')
    await expect(client.getAccessToken()).rejects.toMatchObject({ status: 401 })
    expect(client.getSnapshot().session).toBeNull()
  })
  it('prevents an old logical request from adopting another account after a cookie switch', async () => {
    fetchMock.mockResolvedValueOnce(Response.json(session())).mockResolvedValueOnce(Response.json(session('user_OTHER')))
    const client = new BrowserSessionClient(clientId); await client.load()
    await expect(client.getAccessToken()).rejects.toMatchObject({ status: 409 })
    expect(client.getSnapshot().session?.user.id).toBe('user_OTHER')
  })
  it('does not reinstate a late session after logout or provider disposal', async () => {
    let finish!: (response: Response) => void
    fetchMock.mockImplementation(() => new Promise(resolve => { finish = resolve }))
    const client = new BrowserSessionClient(clientId); const read = client.load()
    client.invalidate(); finish(Response.json(session()))
    await expect(read).rejects.toMatchObject({ status: 409 })
    expect(client.getSnapshot().session).toBeNull()
  })
  it('allows idempotent logout when the current cookie is already signed out', async () => {
    fetchMock.mockResolvedValueOnce(Response.json(session())).mockResolvedValueOnce(Response.json({ client_id: clientId, user: null })).mockResolvedValueOnce(Response.json({ redirect_url: window.location.origin }))
    const client = new BrowserSessionClient(clientId); await client.load()
    expect(await client.logout()).toBe(`${window.location.origin}/`)
    expect(client.getSnapshot().session).toBeNull()
  })
  it('does not revoke another cookie account when a stale tab attempts sign-out', async () => {
    fetchMock.mockResolvedValueOnce(Response.json(session())).mockResolvedValueOnce(Response.json(session('user_OTHER')))
    const client = new BrowserSessionClient(clientId); await client.load()
    await expect(client.logout()).rejects.toMatchObject({ status: 409 })
    expect(fetchMock.mock.calls.some(([path]) => path === '/api/auth/logout')).toBe(false)
    expect(client.getSnapshot().session?.user.id).toBe('user_OTHER')
  })
  it('sends opaque invitation and validated navigation in POST JSON, never URLs or OAuth state', async () => {
    const authorization = new URL('https://api.workos.com/user_management/authorize')
    authorization.searchParams.set('client_id', clientId); authorization.searchParams.set('redirect_uri', `${window.location.origin}/api/auth/callback`)
    fetchMock.mockResolvedValue(Response.json({ authorization_url: authorization.href }))
    const client = new BrowserSessionClient(clientId)
    expect(await client.login('sign-up', { organizationId: 'org_FICTIONAL1', invitationToken: 'fictional+opaque/token=', returnTo: '/organization-access?income=4000' })).toBe(authorization.href)
    const [url, request] = fetchMock.mock.calls[0]
    expect(url).toBe('/api/auth/login')
    expect(JSON.parse(request.body)).toEqual({ screen_hint: 'sign-up', organization_id: 'org_FICTIONAL1', invitation_token: 'fictional+opaque/token=', return_to: `${window.location.origin}/organization-access` })
    expect(request.headers).toEqual({ 'Content-Type': 'application/json', 'X-Frontend-Origin': window.location.origin })
    expect(request.credentials).toBe('same-origin')
    expect(localStorage.length).toBe(0); expect(sessionStorage.length).toBe(0)
  })
  it('clears only in-memory state after confirmed logout and leaves failed logout available to retry', async () => {
    fetchMock.mockResolvedValueOnce(Response.json(session())).mockResolvedValueOnce(Response.json(session())).mockResolvedValueOnce(Response.json({}, { status: 503 })).mockResolvedValueOnce(Response.json(session())).mockResolvedValueOnce(Response.json({ redirect_url: window.location.origin }))
    const client = new BrowserSessionClient(clientId); await client.load()
    await expect(client.logout()).rejects.toMatchObject({ status: 503 })
    expect(client.getSnapshot().session).not.toBeNull()
    expect(await client.logout()).toBe(`${window.location.origin}/`)
    expect(client.getSnapshot().session).toBeNull()
  })
})
it.each(['https://api.workos.com.evil.test/user_management/authorize', 'http://api.workos.com/user_management/authorize', 'https://api.workos.com:8443/user_management/authorize', 'https://user:secret@api.workos.com/user_management/authorize'])('rejects unverified external authorization redirect %s', value => {
  expect(() => checkedBrowserAuthRedirect(value, 'login')).toThrow(ApiRequestError)
})
it('consumes callback errors before analytics and keeps retry distinct from invalid or canceled login', () => {
  window.history.replaceState(null, '', '/login?auth_error=retry')
  expect(captureBrowserAuthError()).toContain('temporarily unavailable')
  expect(window.location.search).toBe('')
  expect(captureBrowserAuthError()).toBeNull()
})
