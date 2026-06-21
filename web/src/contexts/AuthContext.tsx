import { useCallback, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { useAuth, useUser } from '@clerk/clerk-react'
import { fetchCurrentUser, setAuthTokenGetter } from '../api'
import type { CurrentUser } from '../api'
import { AuthContext } from './authContextValue'
import type { AuthContextValue } from './authContextValue'

const CLERK_JWT_TEMPLATE = import.meta.env.VITE_CLERK_JWT_TEMPLATE

function ClerkAuthBridge({ children }: { children: ReactNode }) {
  const { getToken, isLoaded, isSignedIn, signOut } = useAuth()
  const { user: clerkUser } = useUser()
  const [currentUser, setCurrentUser] = useState<CurrentUser | null>(null)
  const [authError, setAuthError] = useState<string | null>(null)
  const [isVerifyingApi, setIsVerifyingApi] = useState(false)

  useEffect(() => {
    setAuthTokenGetter(async () => {
      try {
        return await getToken(CLERK_JWT_TEMPLATE ? { template: CLERK_JWT_TEMPLATE } : undefined)
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
  useEffect(() => {
    setAuthTokenGetter(null)
  }, [])

  const value = useMemo<AuthContextValue>(() => ({
    isClerkEnabled: false,
    isSignedIn: false,
    isLoading: false,
    isVerifyingApi: false,
    currentUser: null,
    authError: null,
    refreshCurrentUser: async () => undefined,
  }), [])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function AuthProvider({ children, isClerkEnabled }: { children: ReactNode; isClerkEnabled: boolean }) {
  return isClerkEnabled ? <ClerkAuthBridge>{children}</ClerkAuthBridge> : <NoAuthBridge>{children}</NoAuthBridge>
}
