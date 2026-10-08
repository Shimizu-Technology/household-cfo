// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { AuthContext, type AuthContextValue } from '../contexts/authContextValue'
import { SignInButton, SignOutButton } from './AuthControls'
import { AuthLoginRoute } from './AuthLoginRoute'
const auth = (overrides: Partial<AuthContextValue> = {}): AuthContextValue => ({
  isClerkEnabled: false, isAuthEnabled: true, authProvider: 'workos', authIdentityId: null,
  isSignedIn: false, isLoading: false, isVerifyingApi: false, currentUser: null, activeCoachWorkspaceId: null,
  authError: null, refreshCurrentUser: async () => undefined, selectCoachWorkspace: () => undefined, ...overrides,
})
afterEach(cleanup)
it('lets invited users retry a failed hosted sign-in', async () => {
  const signIn = vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(undefined)
  render(<AuthContext.Provider value={auth({ signIn })}><SignInButton><button>Sign in</button></SignInButton></AuthContext.Provider>)
  fireEvent.click(screen.getByRole('button', { name: 'Sign in' }))
  await screen.findByRole('alert')
  fireEvent.click(screen.getByRole('button', { name: 'Sign in' }))
  await waitFor(() => expect(signIn).toHaveBeenCalledTimes(2))
  await waitFor(() => expect(screen.queryByRole('alert')).toBeNull())
})
it('starts externally initiated login once and provides a failed-start retry', async () => {
  const signIn = vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(undefined)
  const ui = render(<AuthContext.Provider value={auth({ signIn })}><AuthLoginRoute /></AuthContext.Provider>)
  await screen.findByRole('heading', { name: 'Sign-in could not start.' })
  ui.rerender(<AuthContext.Provider value={auth({ signIn })}><AuthLoginRoute /></AuthContext.Provider>)
  expect(signIn).toHaveBeenCalledOnce()
  fireEvent.click(screen.getByRole('button', { name: 'Check access again' }))
  await waitFor(() => expect(signIn).toHaveBeenCalledTimes(2))
})
it('provides a direct sign-out action and allows retry after a failure', async () => {
  const signOut = vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(undefined)
  render(<AuthContext.Provider value={auth({ signOut })}><SignOutButton /></AuthContext.Provider>)
  fireEvent.click(screen.getByRole('button', { name: 'Sign out' }))
  await screen.findByRole('alert')
  fireEvent.click(screen.getByRole('button', { name: 'Sign out' }))
  await waitFor(() => expect(signOut).toHaveBeenCalledTimes(2))
  await waitFor(() => expect(screen.queryByRole('alert')).toBeNull())
})
it('disables repeated sign-out while the request is pending', async () => {
  let finish!: () => void
  const signOut = vi.fn(() => new Promise<void>(resolve => { finish = resolve }))
  render(<AuthContext.Provider value={auth({ signOut })}><SignOutButton /></AuthContext.Provider>)
  fireEvent.click(screen.getByRole('button', { name: 'Sign out' }))
  const pending = screen.getByRole('button', { name: 'Signing out…' }) as HTMLButtonElement
  expect(pending.disabled).toBe(true)
  fireEvent.click(pending)
  expect(signOut).toHaveBeenCalledOnce()
  finish()
  await waitFor(() => expect(screen.getByRole('button', { name: 'Sign out' })).toBeTruthy())
})
it('reports unavailable sign-out rather than pretending it succeeded', async () => {
  render(<AuthContext.Provider value={auth()}><SignOutButton /></AuthContext.Provider>)
  fireEvent.click(screen.getByRole('button', { name: 'Sign out' }))
  await screen.findByRole('alert')
})

it('does not automatically restart a failed callback and starts a new login only after explicit retry', async () => {
  const signIn = vi.fn().mockResolvedValue(undefined)
  render(<AuthContext.Provider value={auth({ signIn, authError: 'This sign-in link could not be verified. Start sign-in again.' })}><AuthLoginRoute /></AuthContext.Provider>)
  expect(screen.getByRole('heading', { name: 'Sign-in could not finish.' })).toBeTruthy()
  expect(signIn).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Check access again' }))
  await waitFor(() => expect(signIn).toHaveBeenCalledOnce())
})
