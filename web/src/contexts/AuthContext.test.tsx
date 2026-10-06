// @vitest-environment jsdom

import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import type { ReactNode } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { CurrentUser } from '../api'
import { useAuthContext } from './authContextValue'

const mocks = vi.hoisted(() => ({
  fetchCurrentUser: vi.fn(),
  setActiveCoachWorkspaceId: vi.fn(),
  setAuthTokenGetter: vi.fn(),
  setApiActorIdentity: vi.fn(),
  clerkUserId: 'clerk-1' as string | null,
  isLoaded: true,
  isSignedIn: true,
}))

vi.mock('@clerk/clerk-react', () => ({
  SignInButton: ({ children }: { children: ReactNode }) => children,
  SignUpButton: ({ children }: { children: ReactNode }) => children,
  UserButton: () => null,
  useAuth: () => ({
    getToken: vi.fn(async () => 'test-token'),
    userId: mocks.clerkUserId,
    isLoaded: mocks.isLoaded,
    isSignedIn: mocks.isSignedIn,
    signOut: vi.fn(async () => undefined),
  }),
  useUser: () => ({ isLoaded: false, user: null }),
}))

vi.mock('../api', async (importOriginal) => {
  const original = await importOriginal<typeof import('../api')>()
  return {
    ...original,
    fetchCurrentUser: mocks.fetchCurrentUser,
    setActiveCoachWorkspaceId: mocks.setActiveCoachWorkspaceId,
    setAuthTokenGetter: mocks.setAuthTokenGetter,
    setApiActorIdentity: mocks.setApiActorIdentity,
  }
})

import { AUTH_VERIFICATION_TIMEOUT_MS, AuthProvider, AuthVerificationBridge, type AuthSession } from './AuthContext'
import { ApiRequestError } from '../api'
import App from '../App'

function AuthProbe() {
  const auth = useAuthContext()
  return (
    <div>
      <span data-testid="verification">{auth.isVerifyingApi ? 'pending' : 'settled'}</span>
      <span data-testid="user">{auth.currentUser?.clerk_id ?? 'none'}</span>
      <span data-testid="name">{auth.currentUser?.full_name ?? 'none'}</span>
      <span data-testid="workspace">{auth.activeCoachWorkspaceId ?? 'none'}</span>
      <button onClick={() => auth.selectCoachWorkspace(2)}>Choose workspace</button>
      <button onClick={() => void auth.refreshCurrentUser()}>Refresh account</button>
      <span data-testid="error">{auth.authError ?? 'none'}</span>
      <span data-testid="recovery">{String(Boolean(auth.authRecoveryRequired))}</span>
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
  mocks.isLoaded = true
  mocks.isSignedIn = true
  mocks.fetchCurrentUser.mockReset()
  mocks.setActiveCoachWorkspaceId.mockReset()
  mocks.setAuthTokenGetter.mockReset()
  mocks.setApiActorIdentity.mockReset()
})

afterEach(() => { cleanup(); vi.useRealTimers() })

describe('AuthProvider identity verification', () => {
  it('settles into access denied state after API verification fails', async () => {
    mocks.fetchCurrentUser.mockRejectedValue(new ApiRequestError('Program access is unavailable', { status: 403 }))

    render(<AuthProvider isClerkEnabled><AuthProbe /><App /></AuthProvider>)

    await waitFor(() => expect(screen.getByTestId('verification').textContent).toBe('settled'))
    expect(screen.getByTestId('user').textContent).toBe('none')
    expect(screen.getByTestId('error').textContent).toBe('Program access is unavailable')
    expect(screen.getByRole('heading', { name: 'This account cannot open this program.' })).toBeTruthy()
    expect(mocks.setActiveCoachWorkspaceId).toHaveBeenLastCalledWith(null)
  })

  it('verifies the session identity even when the full Clerk profile never loads', async () => {
    mocks.fetchCurrentUser.mockResolvedValue(apiUser('clerk-1'))
    render(<AuthProvider isClerkEnabled><AuthProbe /></AuthProvider>)
    await waitFor(() => expect(screen.getByTestId('user').textContent).toBe('clerk-1'))
    expect(screen.getByTestId('verification').textContent).toBe('settled')
    expect(mocks.fetchCurrentUser).toHaveBeenCalledOnce()
  })

  it.each(['sdk', 'identity', 'request'])('provides recovery for stalled %s verification without exposing a workspace', async stage => {
    vi.useFakeTimers()
    if (stage === 'sdk') mocks.isLoaded = false
    if (stage === 'identity') mocks.clerkUserId = null
    let complete!: (user: CurrentUser) => void
    mocks.fetchCurrentUser.mockImplementation(() => new Promise<CurrentUser>(resolve => { complete = resolve }))
    render(<AuthProvider isClerkEnabled><AuthProbe /><App /></AuthProvider>)
    await act(async () => { await Promise.resolve() })
    await act(async () => { await vi.advanceTimersByTimeAsync(AUTH_VERIFICATION_TIMEOUT_MS + 1) })
    expect(screen.getByRole('heading', { name: 'We couldn’t finish checking your access.' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Reload page' })).toBeTruthy()
    expect(screen.getByTestId('user').textContent).toBe('none')
    if (stage === 'request') {
      await act(async () => { complete(apiUser('clerk-1')); await Promise.resolve() })
      expect(screen.getByTestId('user').textContent).toBe('none')
      const signal = mocks.fetchCurrentUser.mock.calls[0][0] as AbortSignal
      expect(signal.aborted).toBe(true)
    } else expect(mocks.fetchCurrentUser).not.toHaveBeenCalled()
  })

  it('retries a connection failure without claiming that the program seat is missing', async () => {
    mocks.fetchCurrentUser.mockRejectedValueOnce(new Error('Network unavailable')).mockResolvedValueOnce(apiUser('clerk-1'))
    render(<AuthProvider isClerkEnabled><AuthProbe /><App /></AuthProvider>)
    await screen.findByRole('heading', { name: 'We couldn’t finish checking your access.' })
    expect(screen.queryByText(/has not linked your program seat/)).toBeNull()
    await act(async () => { screen.getByRole('button', { name: 'Check access again' }).click() })
    await waitFor(() => expect(screen.getByTestId('user').textContent).toBe('clerk-1'))
  })

  it('installs one token getter across verification renders and cancels reads on identity changes', async () => {
    let resolveOld!: (user: CurrentUser) => void
    mocks.fetchCurrentUser.mockImplementationOnce(() => new Promise<CurrentUser>(resolve => { resolveOld = resolve }))
    const view = render(<AuthProvider isClerkEnabled><AuthProbe /></AuthProvider>)
    await waitFor(() => expect(mocks.fetchCurrentUser).toHaveBeenCalledOnce())
    const oldSignal = mocks.fetchCurrentUser.mock.calls[0][0] as AbortSignal
    mocks.clerkUserId = 'clerk-2'
    mocks.fetchCurrentUser.mockResolvedValueOnce(apiUser('clerk-2'))
    view.rerender(<AuthProvider isClerkEnabled><AuthProbe /></AuthProvider>)
    await waitFor(() => expect(screen.getByTestId('user').textContent).toBe('clerk-2'))
    await act(async () => { resolveOld(apiUser('clerk-1')); await Promise.resolve() })
    expect(screen.getByTestId('user').textContent).toBe('clerk-2')
    expect(oldSignal.aborted).toBe(true)
    expect(mocks.setAuthTokenGetter).toHaveBeenCalledOnce()
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


describe('opt-in local real API QA authentication', () => {
  afterEach(() => {
    vi.unstubAllEnvs()
    window.history.replaceState(null, '', '/')
  })

  it('loads and refreshes actual server identity instead of a static workspace list', async () => {
    vi.stubEnv('DEV', true)
    vi.stubEnv('VITE_E2E_AUTH', 'true')
    window.history.replaceState(null, '', '/?pilot_e2e_role=coach&pilot_e2e_live_api=true')
    mocks.fetchCurrentUser.mockResolvedValueOnce({ ...apiUser('e2e_coach'), full_name: 'Before program creation' })
    render(<AuthProvider isClerkEnabled={false}><AuthProbe /></AuthProvider>)
    await waitFor(() => expect(screen.getByTestId('name').textContent).toBe('Before program creation'))
    mocks.fetchCurrentUser.mockResolvedValueOnce({ ...apiUser('e2e_coach'), full_name: 'After program creation' })
    screen.getByRole('button', { name: 'Refresh account' }).click()
    await waitFor(() => expect(screen.getByTestId('name').textContent).toBe('After program creation'))
    expect(mocks.fetchCurrentUser).toHaveBeenCalledTimes(2)
  })

  it('fails closed when the QA API identity differs from the selected synthetic account', async () => {
    vi.stubEnv('DEV', true)
    vi.stubEnv('VITE_E2E_AUTH', 'true')
    window.history.replaceState(null, '', '/?pilot_e2e_role=coach&pilot_e2e_live_api=true')
    mocks.fetchCurrentUser.mockResolvedValue(apiUser('another-account'))
    render(<AuthProvider isClerkEnabled={false}><AuthProbe /></AuthProvider>)
    await waitFor(() => expect(screen.getByTestId('error').textContent).toBe('QA account identity did not match the API'))
    expect(screen.getByTestId('user').textContent).toBe('none')
  })

  it('clears both live QA workspace selections after verification fails on refresh', async () => {
    vi.stubEnv('DEV', true)
    vi.stubEnv('VITE_E2E_AUTH', 'true')
    window.history.replaceState(null, '', '/?pilot_e2e_role=coach&pilot_e2e_live_api=true')
    mocks.fetchCurrentUser.mockResolvedValueOnce({ ...apiUser('e2e_coach'), active_coach_workspace: { id: 1 } })
    render(<AuthProvider isClerkEnabled={false}><AuthProbe /></AuthProvider>)
    await waitFor(() => expect(screen.getByTestId('user').textContent).toBe('e2e_coach'))
    screen.getByRole('button', { name: 'Choose workspace' }).click()
    await waitFor(() => expect(screen.getByTestId('workspace').textContent).toBe('2'))
    mocks.fetchCurrentUser.mockRejectedValueOnce(new Error('Verification unavailable'))
    screen.getByRole('button', { name: 'Refresh account' }).click()
    await waitFor(() => expect(screen.getByTestId('error').textContent).toBe('Verification unavailable'))
    expect(screen.getByTestId('user').textContent).toBe('none')
    expect(screen.getByTestId('workspace').textContent).toBe('none')
    expect(mocks.setActiveCoachWorkspaceId).toHaveBeenLastCalledWith(null)
  })
})


describe('WorkOS verified identity boundary', () => {
  const session = (overrides: Partial<AuthSession> = {}): AuthSession => ({
    provider: 'workos', userId: 'workos-1', isLoaded: true, isSignedIn: true,
    getToken: async () => 'workos-token', signOut: async () => undefined, ...overrides,
  })
  const workosUser = (overrides: Partial<CurrentUser> = {}): CurrentUser => ({
    ...apiUser('legacy-clerk'), auth_provider: 'workos', auth_subject: 'workos-1', ...overrides,
  })
  it('accepts only the verified WorkOS subject and preserves the permanent local user ID', async () => {
    mocks.fetchCurrentUser.mockResolvedValue(workosUser())
    render(<AuthVerificationBridge session={session()}><AuthProbe /></AuthVerificationBridge>)
    await waitFor(() => expect(screen.getByTestId('name').textContent).toBe('Test Participant'))
    expect(mocks.setApiActorIdentity).toHaveBeenLastCalledWith('workos:workos-1:1:')
  })
  it.each([{ auth_subject: 'other-user' }, { auth_provider: 'clerk' as const }, { auth_subject: undefined, auth_provider: undefined }])('rejects cross-provider or mismatched WorkOS identity %j', overrides => {
    mocks.fetchCurrentUser.mockResolvedValue(workosUser(overrides))
    render(<AuthVerificationBridge session={session()}><AuthProbe /></AuthVerificationBridge>)
    return waitFor(() => {
      expect(screen.getByTestId('error').textContent).toBe('Unable to verify program access for this account')
      expect(screen.getByTestId('name').textContent).toBe('none')
    })
  })
  it('discards late verification when the same raw subject changes providers', async () => {
    let resolveOld!: (user: CurrentUser) => void
    mocks.fetchCurrentUser.mockImplementationOnce(() => new Promise<CurrentUser>(resolve => { resolveOld = resolve }))
    const ui = render(<AuthVerificationBridge session={session({ provider: 'clerk', userId: 'same-subject' })}><AuthProbe /></AuthVerificationBridge>)
    await waitFor(() => expect(mocks.fetchCurrentUser).toHaveBeenCalledOnce())
    mocks.fetchCurrentUser.mockResolvedValueOnce(workosUser({ auth_subject: 'same-subject', full_name: 'WorkOS account' }))
    ui.rerender(<AuthVerificationBridge session={session({ userId: 'same-subject' })}><AuthProbe /></AuthVerificationBridge>)
    await screen.findByText('WorkOS account')
    await act(async () => resolveOld(apiUser('same-subject')))
    expect(screen.getByTestId('name').textContent).toBe('WorkOS account')
  })
  it('withholds verified data immediately when organization scope changes', async () => {
    mocks.fetchCurrentUser.mockResolvedValueOnce(workosUser())
    const ui = render(<AuthVerificationBridge session={session({ sessionScope: 'org-a' })}><AuthProbe /></AuthVerificationBridge>)
    await screen.findByText('Test Participant')
    mocks.fetchCurrentUser.mockImplementationOnce(() => new Promise(() => undefined))
    ui.rerender(<AuthVerificationBridge session={session({ sessionScope: 'org-b' })}><AuthProbe /></AuthVerificationBridge>)
    expect(screen.getByTestId('name').textContent).toBe('none')
  })
  it.each([401, 403, 503])('keeps HTTP %i separate in protected recovery', async status => {
    mocks.fetchCurrentUser.mockRejectedValue(new ApiRequestError('Access check failed', { status }))
    render(<AuthVerificationBridge session={session()}><AuthProbe /><App /></AuthVerificationBridge>)
    const heading = status === 401 ? 'Sign in again to continue.' : status === 503 ? 'Secure access is temporarily unavailable.' : 'This account cannot open this program.'
    await screen.findByRole('heading', { name: heading })
    expect(screen.getByTestId('name').textContent).toBe('none')
    expect(screen.getByTestId('recovery').textContent).toBe(String(status !== 403))
  })
  it('closes a verified workspace immediately on SDK refresh failure', async () => {
    mocks.fetchCurrentUser.mockResolvedValueOnce(workosUser())
    const ui = render(<AuthVerificationBridge session={session()}><AuthProbe /></AuthVerificationBridge>)
    await screen.findByText('Test Participant')
    ui.rerender(<AuthVerificationBridge session={session({ sessionError: 'Secure session expired' })}><AuthProbe /></AuthVerificationBridge>)
    expect(screen.getByTestId('name').textContent).toBe('none')
    expect(screen.getByTestId('error').textContent).toBe('Secure session expired')
  })
})
