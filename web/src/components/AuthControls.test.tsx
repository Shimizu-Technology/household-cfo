// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { AuthContext, type AuthContextValue } from '../contexts/authContextValue'
import { SignInButton, UserButton } from './AuthControls'
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
it('keeps the account menu operable by keyboard and allows sign-out retry', async () => {
  const signOut = vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(undefined)
  render(<AuthContext.Provider value={auth({ signOut })}><UserButton /></AuthContext.Provider>)
  const trigger = screen.getByRole('button', { name: 'Account' })
  fireEvent.click(trigger)
  fireEvent.click(screen.getByRole('button', { name: 'Sign out' }))
  await screen.findByRole('alert')
  fireEvent.click(screen.getByRole('button', { name: 'Sign out' }))
  await waitFor(() => expect(signOut).toHaveBeenCalledTimes(2))
  fireEvent.keyDown(trigger, { key: 'Escape' })
  expect(screen.queryByRole('button', { name: 'Sign out' })).toBeNull()
  expect(document.activeElement).toBe(trigger)
})
