import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { useAuth, useUser } from '@clerk/clerk-react'
import { fetchCurrentUser, setActiveCoachWorkspaceId, setAuthTokenGetter } from '../api'
import type { CurrentUser } from '../api'
import { AuthContext } from './authContextValue'
import type { AuthContextValue } from './authContextValue'

function ClerkAuthBridge({ children }: { children: ReactNode }) {
  const { getToken, isLoaded, isSignedIn, signOut } = useAuth()
  const { user: clerkUser } = useUser()
  const authIdentityId = clerkUser?.id ?? null
  const latestAuthIdentityId = useRef(authIdentityId)
  const verificationRequest = useRef(0)
  const [apiCurrentUser, setApiCurrentUser] = useState<CurrentUser | null>(null)
  const [verifiedAuthIdentityId, setVerifiedAuthIdentityId] = useState<string | null>(null)
  const [activeCoachWorkspaceId, setActiveCoachWorkspaceState] = useState<number | null>(null)
  const [authError, setAuthError] = useState<string | null>(null)
  const [isVerifyingApi, setIsVerifyingApi] = useState(false)

  useLayoutEffect(() => {
    latestAuthIdentityId.current = authIdentityId
  }, [authIdentityId])

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

    const requestId = ++verificationRequest.current
    const requestedIdentityId = authIdentityId
    if (!isSignedIn || !requestedIdentityId) {
      setApiCurrentUser(null)
      setVerifiedAuthIdentityId(null)
      setActiveCoachWorkspaceState(null)
      setActiveCoachWorkspaceId(null)
      setAuthError(null)
      setIsVerifyingApi(false)
      return
    }

    setIsVerifyingApi(true)
    setAuthError(null)
    try {
      const user = await fetchCurrentUser()
      if (requestId !== verificationRequest.current || latestAuthIdentityId.current !== requestedIdentityId) return
      const workspaceId = user.active_coach_workspace?.id ?? null
      setActiveCoachWorkspaceState(workspaceId)
      setActiveCoachWorkspaceId(workspaceId)
      setApiCurrentUser(user)
      setVerifiedAuthIdentityId(requestedIdentityId)
      setAuthError(null)
    } catch (error) {
      if (requestId !== verificationRequest.current || latestAuthIdentityId.current !== requestedIdentityId) return
      setApiCurrentUser(null)
      setVerifiedAuthIdentityId(null)
      setAuthError(error instanceof Error ? error.message : 'Unable to verify program access')
    } finally {
      if (requestId === verificationRequest.current && latestAuthIdentityId.current === requestedIdentityId) {
        setIsVerifyingApi(false)
      }
    }
  }, [authIdentityId, isLoaded, isSignedIn])

  const selectCoachWorkspace = useCallback((workspaceId: number | null) => {
    setActiveCoachWorkspaceState(workspaceId)
    setActiveCoachWorkspaceId(workspaceId)
  }, [])

  useEffect(() => {
    let cancelled = false

    queueMicrotask(() => {
      if (!cancelled) void refreshCurrentUser()
    })

    return () => {
      cancelled = true
    }
  }, [refreshCurrentUser])

  const hasVerifiedIdentity = Boolean(
    isSignedIn
    && authIdentityId
    && verifiedAuthIdentityId === authIdentityId
    && apiCurrentUser,
  )
  const currentUser = hasVerifiedIdentity ? apiCurrentUser : null
  const isApiIdentityPending = Boolean(isSignedIn) && (!authIdentityId || !hasVerifiedIdentity || isVerifyingApi)

  const value = useMemo<AuthContextValue>(() => ({
    isClerkEnabled: true,
    authIdentityId,
    isSignedIn: Boolean(isSignedIn),
    isLoading: !isLoaded,
    isVerifyingApi: isApiIdentityPending,
    currentUser,
    activeCoachWorkspaceId: hasVerifiedIdentity ? activeCoachWorkspaceId : null,
    authError,
    refreshCurrentUser,
    selectCoachWorkspace,
    signOut: () => signOut(),
  }), [activeCoachWorkspaceId, authError, authIdentityId, currentUser, hasVerifiedIdentity, isApiIdentityPending, isLoaded, isSignedIn, refreshCurrentUser, selectCoachWorkspace, signOut])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

function NoAuthBridge({ children }: { children: ReactNode }) {
  const pilotE2ERole = e2eAuthRole()
  const includeCoachWorkspaces = e2eCoachWorkspacesEnabled()
  const currentUser = useMemo(
    () => pilotE2ERole === 'admin' || pilotE2ERole === 'coach' || pilotE2ERole === 'participant'
      ? e2eCurrentUser(pilotE2ERole, includeCoachWorkspaces)
      : null,
    [includeCoachWorkspaces, pilotE2ERole],
  )

  const pilotE2EToken = currentUser && pilotE2ERole
    ? `test_token:${currentUser.clerk_id}:${currentUser.email}:${currentUser.first_name ?? ''}:${currentUser.last_name ?? ''}`
    : null
  const [isTokenReady, setIsTokenReady] = useState(!pilotE2EToken)
  const [activeCoachWorkspaceId, setActiveCoachWorkspaceState] = useState<number | null>(
    currentUser?.active_coach_workspace?.id ?? null,
  )

  const selectCoachWorkspace = useCallback((workspaceId: number | null) => {
    setActiveCoachWorkspaceState(workspaceId)
    setActiveCoachWorkspaceId(workspaceId)
  }, [])

  useLayoutEffect(() => {
    if (!includeCoachWorkspaces) return

    setActiveCoachWorkspaceId(activeCoachWorkspaceId)
  }, [activeCoachWorkspaceId, includeCoachWorkspaces])

  useEffect(() => {
    let cancelled = false
    setAuthTokenGetter(pilotE2EToken ? async () => pilotE2EToken : null)
    queueMicrotask(() => {
      if (!cancelled) setIsTokenReady(true)
    })
    return () => {
      cancelled = true
      setAuthTokenGetter(null)
    }
  }, [pilotE2EToken])

  const value = useMemo<AuthContextValue>(() => ({
    isClerkEnabled: false,
    authIdentityId: currentUser?.clerk_id ?? null,
    isSignedIn: Boolean(currentUser),
    isLoading: false,
    isVerifyingApi: Boolean(pilotE2EToken && !isTokenReady),
    currentUser,
    activeCoachWorkspaceId,
    authError: null,
    refreshCurrentUser: async () => undefined,
    selectCoachWorkspace,
  }), [activeCoachWorkspaceId, currentUser, isTokenReady, pilotE2EToken, selectCoachWorkspace])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

function DelayedParticipantE2EAuthBridge({ children }: { children: ReactNode }) {
  const [currentUser, setCurrentUser] = useState<CurrentUser | null>(null)

  useEffect(() => {
    const timer = window.setTimeout(() => setCurrentUser(e2eCurrentUser('participant')), 250)
    return () => window.clearTimeout(timer)
  }, [])

  const value = useMemo<AuthContextValue>(() => ({
    isClerkEnabled: !currentUser,
    authIdentityId: currentUser?.clerk_id ?? null,
    isSignedIn: true,
    isLoading: false,
    isVerifyingApi: !currentUser,
    currentUser,
    activeCoachWorkspaceId: null,
    authError: null,
    refreshCurrentUser: async () => undefined,
    selectCoachWorkspace: () => undefined,
    signOut: async () => undefined,
  }), [currentUser])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

function e2eAuthRole() {
  return import.meta.env.DEV && import.meta.env.VITE_E2E_AUTH === 'true'
    ? new URLSearchParams(window.location.search).get('pilot_e2e_role')
    : null
}

function e2eCoachWorkspacesEnabled() {
  return import.meta.env.DEV
    && import.meta.env.VITE_E2E_AUTH === 'true'
    && new URLSearchParams(window.location.search).get('pilot_e2e_coach_workspaces') === 'true'
}

function e2eCurrentUser(role: 'admin' | 'coach' | 'participant', includeCoachWorkspaces = false): CurrentUser {
  const isAdmin = role === 'admin'
  const isCoach = role === 'coach'
  const firstName = isAdmin ? 'Pilot' : isCoach ? 'Coach' : 'Test'
  const lastName = isAdmin ? 'Admin' : isCoach ? 'Mendiola' : 'Participant'
  const user: CurrentUser = {
    id: isAdmin ? 900 : isCoach ? 902 : 901,
    clerk_id: `e2e_${role}`,
    email: `${role}@pilot.test`,
    first_name: firstName,
    last_name: lastName,
    full_name: `${firstName} ${lastName}`,
    role,
    invitation_status: 'accepted',
    invited_at: '2026-07-01T00:00:00Z',
    accepted_at: '2026-07-02T00:00:00Z',
    last_sign_in_at: '2026-07-17T00:00:00Z',
    created_at: '2026-07-01T00:00:00Z',
    is_admin: isAdmin,
    is_coach: isCoach,
    is_participant: role === 'participant',
    is_staff: isAdmin || isCoach,
  }
  if (includeCoachWorkspaces && user.is_staff) {
    user.coach_workspaces = [
      {
        id: 1,
        name: 'Mrs. Mel coaching workspace',
        slug: 'mrs-mel-coaching-workspace',
        membership_role: isAdmin ? 'platform_admin' : 'owner',
        coach_profile: { display_name: 'Mrs. Mel', title: 'Financial coach', bio: '' },
      },
      {
        id: 2,
        name: 'Partner coaching workspace',
        slug: 'partner-coaching-workspace',
        membership_role: isAdmin ? 'platform_admin' : 'reviewer',
        coach_profile: { display_name: 'Coach Ana', title: 'Financial coach', bio: '' },
      },
    ]
    user.active_coach_workspace = isAdmin ? null : user.coach_workspaces[0]
  }
  return user
}

export function AuthProvider({ children, isClerkEnabled }: { children: ReactNode; isClerkEnabled: boolean }) {
  if (!isClerkEnabled && e2eAuthRole() === 'delayed_participant') {
    return <DelayedParticipantE2EAuthBridge>{children}</DelayedParticipantE2EAuthBridge>
  }
  return isClerkEnabled ? <ClerkAuthBridge>{children}</ClerkAuthBridge> : <NoAuthBridge>{children}</NoAuthBridge>
}
