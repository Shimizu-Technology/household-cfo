// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { AuthProvider } from './AuthContext'
import { useAuthContext, type AuthSignInOptions } from './authContextValue'
import { RefreshError } from '@workos-inc/authkit-js'
const mocks = vi.hoisted(() => ({ getAccessToken: vi.fn(), signIn: vi.fn(), signUp: vi.fn(), signOut: vi.fn(), setAuthTokenGetter: vi.fn(), fetchCurrentUser: vi.fn() }))
vi.mock('@workos-inc/authkit-react', () => ({ useAuth: () => ({
  isLoading: false, user: { id: 'workos-subject' }, organizationId: 'org-a', authenticationMethod: 'SSO',
  getAccessToken: mocks.getAccessToken, signIn: mocks.signIn, signUp: mocks.signUp, signOut: mocks.signOut,
}) }))
vi.mock('../api', async original => ({
  ...await original<typeof import('../api')>(), fetchCurrentUser: mocks.fetchCurrentUser, setAuthTokenGetter: mocks.setAuthTokenGetter,
}))
function Probe({ options }: { options?: AuthSignInOptions }) {
  const auth = useAuthContext()
  return <><p>{auth.currentUser ? 'Verified WorkOS account' : 'Closed workspace'}</p><p>{auth.authError}</p>
    <button onClick={() => void auth.signIn?.(options)}>Sign in</button><button onClick={() => void auth.signOut?.()}>Sign out</button>
    <button onClick={() => void auth.signUp?.(options)}>Sign up</button><button onClick={() => void auth.refreshCurrentUser()}>Check access</button>
    <span data-testid="status">{auth.authErrorStatus}</span><span data-testid="signed-in">{String(auth.isSignedIn)}</span></>
}
beforeEach(() => {
  vi.clearAllMocks()
  mocks.getAccessToken.mockResolvedValue('workos-access-token')
  mocks.fetchCurrentUser.mockResolvedValue({ id: 17, clerk_id: 'legacy-clerk', auth_provider: 'workos', auth_subject: 'workos-subject' })
})
afterEach(() => { cleanup(); window.history.replaceState(null, '', '/') })
it('uses the official SDK token and safe hosted navigation, then returns to the app origin on sign-out', async () => {
  window.history.replaceState(null, '', '/?income=4000#Ask%20Mia')
  render(<AuthProvider provider="workos"><Probe /></AuthProvider>)
  await screen.findByText('Verified WorkOS account')
  const getter = mocks.setAuthTokenGetter.mock.calls[0][0] as () => Promise<string>
  expect(await getter()).toBe('workos-access-token')
  fireEvent.click(screen.getByRole('button', { name: 'Sign in' }))
  expect(mocks.signIn).toHaveBeenCalledWith({ state: { returnTo: `${window.location.origin}/#Ask%20Mia` } })
  fireEvent.click(screen.getByRole('button', { name: 'Sign out' }))
  expect(mocks.signOut).toHaveBeenCalledWith({ returnTo: window.location.origin })
})
it('closes the workspace on SDK refresh failure and token acquisition failure', async () => {
  render(<AuthProvider provider="workos"><Probe /></AuthProvider>)
  await screen.findByText('Verified WorkOS account')
  mocks.getAccessToken.mockRejectedValueOnce(new Error('Login required'))
  const getter = mocks.setAuthTokenGetter.mock.calls[0][0] as () => Promise<string | null>
  await act(async () => expect(await getter()).toBeNull())
  await waitFor(() => expect(screen.queryByText('Verified WorkOS account')).toBeNull())
  expect(screen.getByText('Your secure session expired. Sign in again to continue.')).toBeTruthy()
})

it('passes exact organization and opaque invitation to the SDK without putting the credential in OAuth state', async () => {
  render(<AuthProvider provider="workos" invitationToken="fictional+opaque/token="><Probe options={{ organizationId: 'org_FICTIONAL1', returnTo: '/organization-access?income=4000' }} /></AuthProvider>)
  await screen.findByText('Verified WorkOS account')
  fireEvent.click(screen.getByRole('button', { name: 'Sign in' }))
  const expected = { organizationId: 'org_FICTIONAL1', invitationToken: 'fictional+opaque/token=', state: { returnTo: `${window.location.origin}/organization-access` } }
  expect(mocks.signIn).toHaveBeenCalledWith(expected)
  expect(JSON.stringify(mocks.signIn.mock.calls[0][0].state)).not.toContain('opaque')
  expect(JSON.stringify(mocks.signIn.mock.calls[0][0].state)).not.toContain('4000')
  fireEvent.click(screen.getByRole('button', { name: 'Sign up' }))
  expect(mocks.signUp).toHaveBeenCalledWith(expected)
})
it.each([
  new RefreshError('Provider unavailable', { isTransient: true, status: 503 }),
  new TypeError('Failed to fetch'),
  new DOMException('Request aborted', 'AbortError'),
  new DOMException('Request timed out', 'TimeoutError'),
])('withholds private state on %s while retaining the session and allowing a 503 retry', async failure => {
  const expired = vi.fn()
  window.addEventListener('household-cfo:auth-expired', expired)
  mocks.fetchCurrentUser.mockImplementation(async () => {
    const getter = mocks.setAuthTokenGetter.mock.calls[0][0] as () => Promise<string>
    await getter()
    return { id: 17, clerk_id: 'legacy-clerk', auth_provider: 'workos', auth_subject: 'workos-subject' }
  })
  try {
    render(<AuthProvider provider="workos"><Probe /></AuthProvider>)
    await screen.findByText('Verified WorkOS account')
    mocks.getAccessToken.mockRejectedValueOnce(failure)
    fireEvent.click(screen.getByRole('button', { name: 'Check access' }))
    await screen.findByText('Secure sign-in is temporarily unavailable. Try again in a moment.')
    expect(screen.getByTestId('status').textContent).toBe('503')
    expect(screen.getByText('Closed workspace')).toBeTruthy()
    expect(screen.getByTestId('signed-in').textContent).toBe('true')
    expect(expired).not.toHaveBeenCalled()
    expect(mocks.signIn).not.toHaveBeenCalled()
    expect(mocks.signOut).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Check access' }))
    await screen.findByText('Verified WorkOS account')
    expect(screen.getByTestId('status').textContent).toBe('')
  } finally { window.removeEventListener('household-cfo:auth-expired', expired) }
})
