// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError } from '../api'
import { BrowserSessionClient, captureBrowserAuthError, checkedBrowserAuthRedirect, clearBrowserAuthCallbackParameters, restoreBrowserAuthNavigation } from './browserAuthSession'
import { captureAuthInvitation } from './authInvitation'
const clientId = 'client_FICTIONAL1'
const session = (id = 'user_FICTIONAL1') => ({ client_id: clientId, user: { id, first_name: 'Fictional', last_name: 'Person', email: 'fictional@pilot.test' }, organization_id: 'org_FICTIONAL1', authentication_method: 'SSO', access_token: `short-lived-${id}`, expires_at: new Date(Date.now() + 120_000).toISOString() })
const fetchMock = vi.fn()
function authorization() {
  const url = new URL('https://api.workos.com/user_management/authorize')
  url.searchParams.set('client_id', clientId); url.searchParams.set('redirect_uri', `${window.location.origin}/api/auth/callback`)
  return url.href
}
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
    expect(JSON.parse(fetchMock.mock.calls[2][1].body)).toEqual({})
  })
  it.each(['org_FICTIONAL1', null])('fences logout with the fresh subject and exact nullable organization %s', async organizationId => {
    const current = { ...session(), organization_id: organizationId }
    fetchMock.mockResolvedValueOnce(Response.json(current)).mockResolvedValueOnce(Response.json(current)).mockResolvedValueOnce(Response.json({ redirect_url: window.location.origin }))
    const client = new BrowserSessionClient(clientId); await client.load()
    expect(await client.logout()).toBe(`${window.location.origin}/`)
    expect(fetchMock.mock.calls[2][0]).toBe('/api/auth/logout')
    expect(JSON.parse(fetchMock.mock.calls[2][1].body)).toEqual({ expected_subject: current.user.id, expected_organization_id: organizationId })
    expect(client.getSnapshot().session).toBeNull()
  })
  it('closes obsolete browser access on atomic logout conflict and permits an explicit current-cookie check', async () => {
    fetchMock.mockResolvedValueOnce(Response.json(session())).mockResolvedValueOnce(Response.json(session()))
      .mockResolvedValueOnce(Response.json({ code: 'account_changed', error: 'untrusted private server detail' }, { status: 409 }))
      .mockResolvedValueOnce(Response.json(session('user_OTHER')))
    const client = new BrowserSessionClient(clientId); await client.load()
    await expect(client.logout()).rejects.toMatchObject({ status: 409, code: 'account_changed', message: 'Your account or organization changed. Check the current account before signing out.' })
    expect(client.getSnapshot()).toMatchObject({ status: 'error', error: { status: 409, code: 'account_changed' }, session: null })
    expect((await client.load())?.user.id).toBe('user_OTHER')
    expect(fetchMock.mock.calls.filter(([path]) => path === '/api/auth/logout')).toHaveLength(1)
  })
  it('rejects a session appearing between signed-out preflight and POST without assuming logout succeeded', async () => {
    fetchMock.mockResolvedValueOnce(Response.json({ client_id: clientId, user: null }))
      .mockResolvedValueOnce(Response.json({ code: 'account_changed' }, { status: 409 }))
      .mockResolvedValueOnce(Response.json(session('user_OTHER')))
    const client = new BrowserSessionClient(clientId)
    await expect(client.logout()).rejects.toMatchObject({ status: 409, code: 'account_changed' })
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({})
    expect((await client.load())?.user.id).toBe('user_OTHER')
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
describe('hosted server-session navigation roundtrip', () => {
  it.each([
    ['/?code=used-code&state=used-state&code=duplicate&state=duplicate#Review', '/#Review'],
    ['/organization-access?code=used-code&state=used-state', '/organization-access'],
    ['/?code=used-code&state=used-state&enterprise=1', '/?enterprise=1'],
    ['/login?returnTo=%2F%23Review&code=used-code&state=used-state', '/login?returnTo=%2F%23Review'],
    ['/?oauth_state_id=fictional-bank-ref&code=used-code&state=used-state#Review', '/?oauth_state_id=fictional-bank-ref#Review'],
  ])('cleans the consumed WorkOS callback in %s without changing the app destination', (start, expected) => {
    window.history.replaceState({ navigation: 'preserved' }, '', start)
    clearBrowserAuthCallbackParameters('workos')
    expect(window.location.pathname + window.location.search + window.location.hash).toBe(expected)
    expect(window.history.state).toEqual({ navigation: 'preserved' })
    clearBrowserAuthCallbackParameters('workos')
    expect(window.location.pathname + window.location.search + window.location.hash).toBe(expected)
  })
  it.each(['clerk', 'preview'])('leaves the %s provider URL untouched', provider => {
    window.history.replaceState(null, '', '/?code=other-provider&state=other-state')
    clearBrowserAuthCallbackParameters(provider)
    expect(window.location.search).toBe('?code=other-provider&state=other-state')
  })
  it.each(['/api/auth/callback', '/auth/callback', '/other-route'])('leaves the raw callback or unrelated route %s untouched', route => {
    window.history.replaceState(null, '', `${route}?code=unconsumed&state=unconsumed`)
    clearBrowserAuthCallbackParameters('workos')
    expect(window.location.search).toBe('?code=unconsumed&state=unconsumed')
  })
  it('keeps one-use invitation capture and callback recovery working together', () => {
    window.history.replaceState(null, '', '/login?invitation_token=fictional-invite&code=used-code&state=used-state&auth_error=retry')
    expect(captureAuthInvitation()).toEqual({ token: 'fictional-invite', error: null })
    clearBrowserAuthCallbackParameters('workos')
    expect(captureBrowserAuthError()).toContain('temporarily unavailable')
    expect(window.location.search).toBe('')
    expect(captureAuthInvitation().token).toBeNull()
  })
  it.each([
    ['/?oauth_state_id=fictional-bank-ref&income=4500#Review', '/#Review', 'hosted'],
    ['/?oauth_state_id=fictional-bank-ref&enterprise=1&email=private@example.test', '/organization-access', 'hosted'],
    ['/?oauth_state_id=fictional-bank-ref&income=4500#Review', '/#Review', 'email'],
    ['/?oauth_state_id=fictional-bank-ref&enterprise=1&email=private@example.test', '/organization-access', 'email'],
  ])('restores the one-use bank callback and safe destination from %s through %s (%s)', async (start, returned, method) => {
    window.history.replaceState(null, '', start)
    fetchMock.mockResolvedValue(Response.json({ ...(method === 'email' ? { step: 'redirect' } : {}), authorization_url: authorization() }))
    const client = new BrowserSessionClient(clientId)
    if (method === 'email') await client.startEmail({ email: 'bank@pilot.test' })
    else await client.login('sign-in')
    const body = JSON.parse(fetchMock.mock.calls[0][1].body)
    expect(body.return_to).toBe(`${window.location.origin}${returned}`)
    expect(JSON.stringify(body)).not.toContain('fictional-bank-ref')
    expect(JSON.stringify(body)).not.toContain('4500')
    const raw = sessionStorage.getItem('household-cfo:server-auth-navigation')!
    const saved = JSON.parse(raw)
    expect(saved.state.navigationKey).toBeTruthy()
    window.history.replaceState(null, '', `${returned.split('#')[0]}?code=used-code&state=used-state${returned.includes('#') ? '#Review' : ''}`)
    clearBrowserAuthCallbackParameters('workos')
    restoreBrowserAuthNavigation()
    expect(window.location.pathname).toBe(returned.startsWith('/organization-access') ? '/organization-access' : '/')
    expect(window.location.hash).toBe(returned.includes('#') ? '#Review' : '')
    expect(window.location.search).toBe('?oauth_state_id=fictional-bank-ref')
    expect(sessionStorage.getItem('household-cfo:server-auth-navigation')).toBeNull()
    expect(sessionStorage.getItem(`household-cfo:auth-navigation:${saved.state.navigationKey}`)).toBeNull()
    window.history.replaceState(null, '', returned)
    restoreBrowserAuthNavigation()
    expect(window.location.search).toBe('')
  })
  it.each([Date.now() - 31 * 60_000, Date.now() + 60_000])('discards expired or future hosted return snapshots at %s', createdAt => {
    window.history.replaceState(null, '', '/#Review')
    sessionStorage.setItem('household-cfo:server-auth-navigation', JSON.stringify({ state: { returnTo: `${window.location.origin}/#Review`, navigationKey: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }, createdAt }))
    restoreBrowserAuthNavigation()
    expect(window.location.hash).toBe('#Review'); expect(window.location.search).toBe('')
    expect(sessionStorage.getItem('household-cfo:server-auth-navigation')).toBeNull()
  })
  it.each(['wrong-destination', 'invalid-reference', 'expired-bank-snapshot'])('keeps safe navigation but rejects a bank snapshot with %s', async invalid => {
    window.history.replaceState(null, '', '/?oauth_state_id=fictional-bank-ref#Review')
    fetchMock.mockResolvedValue(Response.json({ authorization_url: authorization() }))
    await new BrowserSessionClient(clientId).login('sign-in')
    const saved = JSON.parse(sessionStorage.getItem('household-cfo:server-auth-navigation')!)
    const key = `household-cfo:auth-navigation:${saved.state.navigationKey}`
    const bank = JSON.parse(sessionStorage.getItem(key)!)
    if (invalid === 'wrong-destination') bank.returnTo = `${window.location.origin}/#My%20Profile`
    if (invalid === 'invalid-reference') bank.oauthState = 'invalid/ref!'
    if (invalid === 'expired-bank-snapshot') bank.createdAt = Date.now() - 31 * 60_000
    sessionStorage.setItem(key, JSON.stringify(bank))
    window.history.replaceState(null, '', '/#Review')
    restoreBrowserAuthNavigation()
    expect(window.location.hash).toBe('#Review'); expect(window.location.search).toBe('')
    expect(sessionStorage.getItem(key)).toBeNull()
    expect(sessionStorage.getItem('household-cfo:server-auth-navigation')).toBeNull()
  })
  it('ignores invalid navigation keys and malformed snapshots without exposing arbitrary query or destinations', () => {
    sessionStorage.setItem('household-cfo:server-auth-navigation', JSON.stringify({ state: { returnTo: 'https://evil.test/?secret=private', navigationKey: '../untrusted' }, createdAt: Date.now() }))
    restoreBrowserAuthNavigation()
    expect(window.location.href).toBe(`${window.location.origin}/`)
    expect(sessionStorage.getItem('household-cfo:server-auth-navigation')).toBeNull()
    sessionStorage.setItem('household-cfo:server-auth-navigation', '{malformed')
    restoreBrowserAuthNavigation()
    expect(window.location.search).toBe('')
    expect(sessionStorage.getItem('household-cfo:server-auth-navigation')).toBeNull()
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


describe('in-app email sign-in transport', () => {
  const challenge = { step: 'code', challenge_id: 'c'.repeat(43), email: 'fictional@pilot.test', expires_at: new Date(Date.now() + 600_000).toISOString(), resend_after: 60 }
  it('normalizes entered email and keeps invitation and code solely in no-store POST bodies', async () => {
    fetchMock.mockResolvedValueOnce(Response.json(challenge)).mockResolvedValueOnce(Response.json({ step: 'complete', return_to: `${window.location.origin}/#Review` }))
    const client = new BrowserSessionClient(clientId)
    expect(await client.startEmail({ email: ' Fictional@Pilot.Test ', invitationToken: 'fictional-invite', returnTo: '/#Review' })).toEqual(challenge)
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({ email: challenge.email, invitation_token: 'fictional-invite', return_to: `${window.location.origin}/#Review` })
    expect(await client.verifyEmail(challenge.challenge_id, '123456')).toMatchObject({ step: 'complete' })
    expect(fetchMock.mock.calls[1][0]).toBe('/api/auth/email/verify')
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({ challenge_id: challenge.challenge_id, code: '123456' })
    expect(localStorage.length).toBe(0); expect(sessionStorage.length).toBe(0)
    expect(client.getSnapshot().session).toBeNull()
  })
  it('preserves an existing session on an invalid code and sanitizes provider errors', async () => {
    fetchMock.mockResolvedValueOnce(Response.json(session())).mockResolvedValueOnce(Response.json({ code: 'email_code_invalid', error: 'private provider response' }, { status: 401 }))
    const client = new BrowserSessionClient(clientId); await client.load()
    await expect(client.verifyEmail(challenge.challenge_id, '123456')).rejects.toMatchObject({ code: 'email_code_invalid', status: 401 })
    expect(client.getSnapshot().session?.user.id).toBe('user_FICTIONAL1')
  })
  it.each([60, 3500, '3500', -1, 3601])('keeps only bounded numeric rate-delay metadata (%s)', async retry => {
    fetchMock.mockResolvedValue(Response.json({ code: 'auth_rate_limited', error: 'SECRET provider detail', retry_after_sec: retry, secret: 'SECRET' }, { status: 429 }))
    const payload = typeof retry === 'number' && retry > 0 && retry <= 3600 ? { retry_after_sec: retry } : {}
    const error = await new BrowserSessionClient(clientId).startEmail({ email: challenge.email }).catch(caught => caught)
    expect(error).toBeInstanceOf(ApiRequestError)
    expect(error).toMatchObject({ code: 'auth_rate_limited', status: 429 })
    expect(error.payload).toEqual(payload)
  })
  it.each([{ ...challenge, email: 'other@pilot.test' }, { ...challenge, challenge_id: 'unsafe' }, { ...challenge, resend_after: -1 }, { ...challenge, expires_at: 'not-a-date' }, { step: 'redirect', authorization_url: 'https://attacker.test/' }])('rejects unsafe challenge metadata and destinations', async response => {
    fetchMock.mockResolvedValue(Response.json(response))
    await expect(new BrowserSessionClient(clientId).startEmail({ email: challenge.email })).rejects.toMatchObject({ status: 503 })
  })
  it('validates Google availability and serializes explicit OAuth choice and popup flag', async () => {
    fetchMock.mockResolvedValueOnce(Response.json({ google_enabled: true })).mockResolvedValueOnce(Response.json({ authorization_url: authorization() }))
    const client = new BrowserSessionClient(clientId)
    expect(await client.authOptions()).toEqual({ google_enabled: true })
    await client.login('sign-in', { authenticationMethod: 'google', popup: true })
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toMatchObject({ authentication_method: 'google', popup: true })
  })
  it('supports no-content cancellation without changing the session', async () => {
    fetchMock.mockResolvedValue(new Response(null, { status: 204 }))
    const client = new BrowserSessionClient(clientId)
    await client.cancelEmail(challenge.challenge_id)
    expect(fetchMock.mock.calls[0][0]).toBe('/api/auth/email/cancel')
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ credentials: 'same-origin', cache: 'no-store' })
    expect(client.getSnapshot().status).toBe('loading')
  })
})

describe('owned external login operation transport', () => {
  const ownedUrl = () => { const url = new URL(authorization()); url.searchParams.set('state', 's'.repeat(43)); return url.href }
  it('sends status and cancellation credentials only in origin-bound no-store JSON', async () => {
    fetchMock.mockResolvedValueOnce(Response.json({ status: 'pending' })).mockResolvedValueOnce(Response.json({ status: 'cancelled' }))
    const client = new BrowserSessionClient(clientId)
    expect(await client.loginStatus(ownedUrl())).toEqual({ status: 'pending' })
    expect(await client.cancelLogin(ownedUrl())).toEqual({ status: 'cancelled' })
    expect(fetchMock.mock.calls.map(([path]) => path)).toEqual(['/api/auth/login/status', '/api/auth/login/cancel'])
    for (const [, request] of fetchMock.mock.calls) {
      expect(request).toMatchObject({ credentials: 'same-origin', cache: 'no-store', method: 'POST' })
      expect(JSON.parse(request.body)).toEqual({ state: 's'.repeat(43) })
    }
    expect(localStorage.length).toBe(0); expect(sessionStorage.length).toBe(0)
  })
  it('does not cancel a provider link belonging to a different application client', async () => {
    const url = new URL(ownedUrl()); url.searchParams.set('client_id', 'client_OTHER')
    await expect(new BrowserSessionClient(clientId).cancelLogin(url.href)).rejects.toMatchObject({ status: 503 })
    expect(fetchMock).not.toHaveBeenCalled()
  })
  it('rejects malformed operation state and unexpected completion response values', async () => {
    fetchMock.mockResolvedValue(Response.json({ status: 'trusted-unverified' }))
    await expect(new BrowserSessionClient(clientId).loginStatus(ownedUrl())).rejects.toMatchObject({ status: 503 })
    const malformed = new URL(ownedUrl()); malformed.searchParams.set('state', 'bad')
    await expect(new BrowserSessionClient(clientId).cancelLogin(malformed.href)).rejects.toMatchObject({ status: 503 })
    expect(fetchMock).toHaveBeenCalledOnce()
  })
})

it('offers invited-account recovery after a denied provider callback and consumes the marker once', () => {
  window.history.replaceState(null, '', '/login?auth_error=denied')
  expect(captureBrowserAuthError()).toBe('This account cannot open this program. Sign in with the email your program invited.')
  expect(window.location.search).toBe('')
  expect(captureBrowserAuthError()).toBeNull()
})

it.each([
  ['hosted', '/#Review'], ['email', '/#Review'],
  ['hosted', '/organization-access'], ['email', '/organization-access'],
])('keeps the one-use bank reference when %s explicitly returns to %s instead of the initial section', async (method, destination) => {
  window.history.replaceState(null, '', '/?oauth_state_id=fictional-explicit-ref&income=4500#Home')
  fetchMock.mockResolvedValue(Response.json({ ...(method === 'email' ? { step: 'redirect' } : {}), authorization_url: authorization() }))
  const client = new BrowserSessionClient(clientId)
  if (method === 'email') await client.startEmail({ email: 'bank@pilot.test', returnTo: destination })
  else await client.login('sign-in', { returnTo: destination })
  const body = JSON.parse(fetchMock.mock.calls[0][1].body)
  expect(body.return_to).toBe(`${window.location.origin}${destination}`)
  expect(JSON.stringify(body)).not.toContain('fictional-explicit-ref')
  expect(JSON.stringify(body)).not.toContain('4500')
  const saved = JSON.parse(sessionStorage.getItem('household-cfo:server-auth-navigation')!)
  expect(saved.state.returnTo).toBe(body.return_to)
  const bankKey = `household-cfo:auth-navigation:${saved.state.navigationKey}`
  expect(JSON.parse(sessionStorage.getItem(bankKey)!).returnTo).toBe(body.return_to)
  window.history.replaceState(null, '', destination)
  restoreBrowserAuthNavigation()
  expect(window.location.search).toBe('?oauth_state_id=fictional-explicit-ref')
  expect(window.location.hash).toBe(destination.includes('#') ? '#Review' : '')
  expect(sessionStorage.getItem(bankKey)).toBeNull()
  expect(sessionStorage.getItem('household-cfo:server-auth-navigation')).toBeNull()
  window.history.replaceState(null, '', destination)
  restoreBrowserAuthNavigation()
  expect(window.location.search).toBe('')
})
