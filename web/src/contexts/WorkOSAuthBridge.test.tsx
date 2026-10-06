// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { AuthProvider } from './AuthContext'
import { useAuthContext } from './authContextValue'
const mocks = vi.hoisted(() => ({ getAccessToken: vi.fn(), signIn: vi.fn(), signUp: vi.fn(), signOut: vi.fn(), setAuthTokenGetter: vi.fn(), fetchCurrentUser: vi.fn() }))
vi.mock('@workos-inc/authkit-react', () => ({ useAuth: () => ({
  isLoading: false, user: { id: 'workos-subject' }, organizationId: 'org-a', authenticationMethod: 'SSO',
  getAccessToken: mocks.getAccessToken, signIn: mocks.signIn, signUp: mocks.signUp, signOut: mocks.signOut,
}) }))
vi.mock('../api', async original => ({
  ...await original<typeof import('../api')>(), fetchCurrentUser: mocks.fetchCurrentUser, setAuthTokenGetter: mocks.setAuthTokenGetter,
}))
function Probe() {
  const auth = useAuthContext()
  return <><p>{auth.currentUser ? 'Verified WorkOS account' : 'Closed workspace'}</p><p>{auth.authError}</p>
    <button onClick={() => void auth.signIn?.()}>Sign in</button><button onClick={() => void auth.signOut?.()}>Sign out</button></>
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
