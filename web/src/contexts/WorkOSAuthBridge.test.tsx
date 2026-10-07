// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { AuthProvider } from './AuthContext'
import { useAuthContext } from './authContextValue'
import App from '../App'
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
