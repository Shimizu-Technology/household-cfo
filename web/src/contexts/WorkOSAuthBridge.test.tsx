// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { AuthProvider } from './AuthContext'
import { useAuthContext } from './authContextValue'
import App from '../App'
import { UserButton } from '../components/AuthControls'
const clientId = 'client_FICTIONAL1'
const browserSession = { client_id: clientId, user: { id: 'workos-subject', email: 'fictional@pilot.test', first_name: 'Fictional', last_name: 'Person' }, organization_id: 'org_FICTIONAL1', authentication_method: 'SSO', access_token: 'short-lived-access-token', expires_at: new Date(Date.now() + 120_000).toISOString() }
const fetchMock = vi.fn()
function Probe() {
  const auth = useAuthContext()
  return <><p>{auth.currentUser ? 'Verified WorkOS account' : 'Closed workspace'}</p><p>{auth.authError}</p><span data-testid="status">{auth.authErrorStatus}</span>
    <button onClick={() => void auth.refreshCurrentUser()}>Check access</button></>
}
beforeEach(() => {
  fetchMock.mockReset(); vi.stubGlobal('fetch', fetchMock)
  fetchMock.mockImplementation(async input => String(input).endsWith('/api/auth/session') ? Response.json(browserSession) : Response.json({ user: { id: 17, clerk_id: 'legacy-clerk', auth_provider: 'workos', auth_subject: 'workos-subject' } }))
})
afterEach(() => { cleanup(); vi.unstubAllGlobals(); window.history.replaceState(null, '', '/') })
it('verifies the server session subject against permanent Rails identity and uses bearer finance transport', async () => {
  render(<AuthProvider provider="workos" clientId={clientId}><Probe /></AuthProvider>)
  await screen.findByText('Verified WorkOS account')
  const apiCall = fetchMock.mock.calls.find(([input]) => String(input).endsWith('/api/v1/auth/me'))!
  expect(apiCall[1].headers.Authorization).toBe('Bearer short-lived-access-token')
  expect(localStorage.getItem('workos_refresh_token')).toBeNull()
})
it('withholds the workspace on transient session outage and succeeds with bounded retry', async () => {
  fetchMock.mockResolvedValueOnce(Response.json({}, { status: 503 }))
  render(<AuthProvider provider="workos" clientId={clientId}><Probe /></AuthProvider>)
  await screen.findByText('Secure sign-in is temporarily unavailable. Try again in a moment.')
  expect(screen.getByTestId('status').textContent).toBe('503')
  expect(screen.getByText('Closed workspace')).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Check access' }))
  await screen.findByText('Verified WorkOS account')
})
it('closes a verified workspace immediately on revoked session signal', async () => {
  render(<AuthProvider provider="workos" clientId={clientId}><Probe /></AuthProvider>)
  await screen.findByText('Verified WorkOS account')
  await act(async () => window.dispatchEvent(new Event('household-cfo:auth-expired')))
  await waitFor(() => expect(screen.queryByText('Verified WorkOS account')).toBeNull())
  expect(screen.getByTestId('status').textContent).toBe('401')
})

it('retries initial BFF outage without identity and verifies Rails access before any financial workspace request', async () => {
  fetchMock.mockResolvedValueOnce(Response.json({}, { status: 503 }))
  render(<AuthProvider provider="workos" clientId={clientId}><App /></AuthProvider>)
  await screen.findByRole('heading', { name: 'Secure access is temporarily unavailable.' })
  expect(fetchMock.mock.calls.some(([input]) => String(input).endsWith('/api/v1/auth/me'))).toBe(false)
  expect(screen.queryByText('$0')).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Check access again' }))
  await waitFor(() => expect(fetchMock.mock.calls.some(([input]) => String(input).endsWith('/api/v1/auth/me'))).toBe(true))
  const apiCall = fetchMock.mock.calls.find(([input]) => String(input).endsWith('/api/v1/auth/me'))!
  expect(apiCall[1].headers.Authorization).toBe('Bearer short-lived-access-token')
})

it('offers App recovery after an atomic logout conflict and verifies the new cookie actor without sign-in', async () => {
  let other = false
  const expire = vi.fn()
  window.addEventListener('household-cfo:auth-expired', expire)
  fetchMock.mockImplementation(async input => {
    const path = String(input)
    if (path.endsWith('/api/auth/logout')) { other = true; return Response.json({ code: 'account_changed' }, { status: 409 }) }
    if (path.endsWith('/api/auth/session')) return Response.json(other ? { ...browserSession, user: { ...browserSession.user, id: 'other-subject' }, access_token: 'new-account-token' } : browserSession)
    if (path.endsWith('/api/v1/auth/me')) return Response.json({ user: { id: other ? 18 : 17, clerk_id: 'legacy-clerk', auth_provider: 'workos', auth_subject: other ? 'other-subject' : 'workos-subject', full_name: other ? 'Other fictional account' : 'Original fictional account' } })
    throw new Error(`Unexpected private request: ${path}`)
  })
  function Workspace() {
    const auth = useAuthContext()
    return auth.authError ? <App /> : <><p>{auth.currentUser?.full_name}</p><UserButton /></>
  }
  try {
    render(<AuthProvider provider="workos" clientId={clientId}><Workspace /></AuthProvider>)
    await screen.findByText('Original fictional account')
    fireEvent.click(screen.getByRole('button', { name: 'Account' }))
    fireEvent.click(screen.getByRole('button', { name: 'Sign out' }))
    await screen.findByRole('heading', { name: 'We couldn’t finish checking your access.' })
    expect(screen.queryByText('Original fictional account')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Sign in again' })).toBeNull()
    expect(expire).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Check access again' }))
    await screen.findByText('Other fictional account')
    const calls = fetchMock.mock.calls.filter(([input]) => String(input).endsWith('/api/v1/auth/me'))
    expect(calls).toHaveLength(2)
    expect(calls[1][1].headers.Authorization).toBe('Bearer new-account-token')
    expect(fetchMock.mock.calls.filter(([input]) => String(input).endsWith('/api/auth/logout'))).toHaveLength(1)
    expect(fetchMock.mock.calls.some(([input]) => String(input).endsWith('/api/auth/login'))).toBe(false)
  } finally { window.removeEventListener('household-cfo:auth-expired', expire) }
})
