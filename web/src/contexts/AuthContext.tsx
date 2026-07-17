import { useCallback, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { useAuth, useUser } from '@clerk/clerk-react'
import { fetchCurrentUser, setAuthTokenGetter } from '../api'
import type { CurrentUser } from '../api'
import { AuthContext } from './authContextValue'
import type { AuthContextValue } from './authContextValue'

function ClerkAuthBridge({ children }: { children: ReactNode }) {
  const { getToken, isLoaded, isSignedIn, signOut } = useAuth()
  const { user: clerkUser } = useUser()
  const [currentUser, setCurrentUser] = useState<CurrentUser | null>(null)
  const [authError, setAuthError] = useState<string | null>(null)
  const [isVerifyingApi, setIsVerifyingApi] = useState(false)

  useEffect(() => {
    setAuthTokenGetter(async () => {
      try {
        return await getToken()
      } catch (error) {
        console.warn('Unable to load Clerk token', error)
        return null
      }
    })

    return () => setAuthTokenGetter(null)
  }, [getToken])

  const refreshCurrentUser = useCallback(async () => {
    if (!isLoaded) return

    if (!isSignedIn) {
      setCurrentUser(null)
      setAuthError(null)
      setIsVerifyingApi(false)
      return
    }

    setIsVerifyingApi(true)
    try {
      const user = await fetchCurrentUser()
      setCurrentUser(user)
      setAuthError(null)
    } catch (error) {
      setCurrentUser(null)
      setAuthError(error instanceof Error ? error.message : 'Unable to verify Household CFO access')
    } finally {
      setIsVerifyingApi(false)
    }
  }, [isLoaded, isSignedIn])

  useEffect(() => {
    let cancelled = false

    queueMicrotask(() => {
      if (!cancelled) void refreshCurrentUser()
    })

    return () => {
      cancelled = true
    }
  }, [refreshCurrentUser, clerkUser?.id])

  const value = useMemo<AuthContextValue>(() => ({
    isClerkEnabled: true,
    isSignedIn: Boolean(isSignedIn),
    isLoading: !isLoaded,
    isVerifyingApi,
    currentUser,
    authError,
    refreshCurrentUser,
    signOut: () => signOut(),
  }), [authError, currentUser, isLoaded, isSignedIn, isVerifyingApi, refreshCurrentUser, signOut])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

function NoAuthBridge({ children }: { children: ReactNode }) {
  const pilotE2ERole = import.meta.env.DEV && import.meta.env.VITE_E2E_AUTH === 'true'
    ? new URLSearchParams(window.location.search).get('pilot_e2e_role')
    : null
  const currentUser = useMemo(
    () => pilotE2ERole === 'admin' || pilotE2ERole === 'participant'
      ? e2eCurrentUser(pilotE2ERole)
      : null,
    [pilotE2ERole],
  )

  useEffect(() => {
    setAuthTokenGetter(null)
  }, [])

  const value = useMemo<AuthContextValue>(() => ({
    isClerkEnabled: false,
    isSignedIn: Boolean(currentUser),
    isLoading: false,
    isVerifyingApi: false,
    currentUser,
    authError: null,
    refreshCurrentUser: async () => undefined,
  }), [currentUser])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

function e2eCurrentUser(role: 'admin' | 'participant'): CurrentUser {
  return {
    id: role === 'admin' ? 900 : 901,
    clerk_id: `e2e_${role}`,
    email: `${role}@pilot.test`,
    first_name: role === 'admin' ? 'Pilot' : 'Test',
    last_name: role === 'admin' ? 'Admin' : 'Participant',
    full_name: role === 'admin' ? 'Pilot Admin' : 'Test Participant',
    role,
    invitation_status: 'accepted',
    invited_at: '2026-07-01T00:00:00Z',
    accepted_at: '2026-07-02T00:00:00Z',
    last_sign_in_at: '2026-07-17T00:00:00Z',
    created_at: '2026-07-01T00:00:00Z',
    is_admin: role === 'admin',
    is_coach: false,
    is_participant: role === 'participant',
    is_staff: role === 'admin',
  }
}

export function AuthProvider({ children, isClerkEnabled }: { children: ReactNode; isClerkEnabled: boolean }) {
  return isClerkEnabled ? <ClerkAuthBridge>{children}</ClerkAuthBridge> : <NoAuthBridge>{children}</NoAuthBridge>
}
