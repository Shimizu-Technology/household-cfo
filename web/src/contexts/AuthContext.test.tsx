// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react'
import type { ReactNode } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { CurrentUser } from '../api'
import { useAuthContext } from './authContextValue'

const mocks = vi.hoisted(() => ({
  fetchCurrentUser: vi.fn(),
  setActiveCoachWorkspaceId: vi.fn(),
  setAuthTokenGetter: vi.fn(),
  clerkUserId: 'clerk-1' as string | null,
}))

vi.mock('@clerk/clerk-react', () => ({
  SignInButton: ({ children }: { children: ReactNode }) => children,
  SignUpButton: ({ children }: { children: ReactNode }) => children,
  UserButton: () => null,
  useAuth: () => ({
    getToken: vi.fn(async () => 'test-token'),
    isLoaded: true,
    isSignedIn: true,
    signOut: vi.fn(async () => undefined),
  }),
  useUser: () => ({ user: mocks.clerkUserId ? { id: mocks.clerkUserId } : null }),
}))

vi.mock('../api', async (importOriginal) => {
  const original = await importOriginal<typeof import('../api')>()
  return {
    ...original,
    fetchCurrentUser: mocks.fetchCurrentUser,
    setActiveCoachWorkspaceId: mocks.setActiveCoachWorkspaceId,
    setAuthTokenGetter: mocks.setAuthTokenGetter,
  }
})

import { AuthProvider } from './AuthContext'
import App from '../App'

function AuthProbe() {
  const auth = useAuthContext()
  return (
    <div>
      <span data-testid="verification">{auth.isVerifyingApi ? 'pending' : 'settled'}</span>
      <span data-testid="user">{auth.currentUser?.clerk_id ?? 'none'}</span>
      <span data-testid="error">{auth.authError ?? 'none'}</span>
    </div>
  )
}

function apiUser(clerkId: string): CurrentUser {
  return {
    id: 1,
    clerk_id: clerkId,
    email: 'participant@example.com',
    first_name: 'Test',
    last_name: 'Participant',
    full_name: 'Test Participant',
    role: 'participant',
    invitation_status: 'accepted',
    invited_at: null,
    accepted_at: null,
    last_sign_in_at: null,
    created_at: '2026-10-01T00:00:00Z',
    is_admin: false,
    is_coach: false,
    is_participant: true,
    is_staff: false,
  }
}

beforeEach(() => {
  mocks.clerkUserId = 'clerk-1'
  mocks.fetchCurrentUser.mockReset()
  mocks.setActiveCoachWorkspaceId.mockReset()
  mocks.setAuthTokenGetter.mockReset()
})

afterEach(() => cleanup())

describe('AuthProvider identity verification', () => {
  it('settles into access denied state after API verification fails', async () => {
    mocks.fetchCurrentUser.mockRejectedValue(new Error('Program access is unavailable'))

    render(<AuthProvider isClerkEnabled><AuthProbe /><App /></AuthProvider>)

    await waitFor(() => expect(screen.getByTestId('verification').textContent).toBe('settled'))
    expect(screen.getByTestId('user').textContent).toBe('none')
    expect(screen.getByTestId('error').textContent).toBe('Program access is unavailable')
    expect(screen.getByRole('heading', { name: 'Your sign-in is active, but VERA has not linked your program seat.' })).toBeTruthy()
    expect(mocks.setActiveCoachWorkspaceId).toHaveBeenLastCalledWith(null)
  })

  it('rejects an API user that does not match the active Clerk identity', async () => {
    mocks.fetchCurrentUser.mockResolvedValue(apiUser('clerk-2'))

    render(<AuthProvider isClerkEnabled><AuthProbe /></AuthProvider>)

    await waitFor(() => expect(screen.getByTestId('verification').textContent).toBe('settled'))
    expect(screen.getByTestId('user').textContent).toBe('none')
    expect(screen.getByTestId('error').textContent).toBe('Unable to verify program access for this account')
    expect(mocks.setActiveCoachWorkspaceId).toHaveBeenLastCalledWith(null)
  })
})
