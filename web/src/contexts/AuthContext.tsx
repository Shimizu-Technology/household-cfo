import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { useAuth } from '@clerk/clerk-react'
import { ApiRequestError, fetchCurrentUser, setActiveCoachWorkspaceId, setApiActorIdentity, setAuthTokenGetter } from '../api'
import type { CurrentUser } from '../api'
import { AuthContext } from './authContextValue'
import type { AuthContextValue } from './authContextValue'

export const AUTH_VERIFICATION_TIMEOUT_MS = 30_000

export type AuthSession = {
  userId: string | null | undefined
  isLoaded: boolean
  isSignedIn: boolean | undefined
  getToken: () => Promise<string | null>
  signOut: () => Promise<unknown>
}

function ClerkAuthBridge({ children }: { children: ReactNode }) {
  const session = useAuth()
  return <AuthVerificationBridge session={session}>{children}</AuthVerificationBridge>
}

// The session identity is sufficient for verification; a separate full-profile
// request must not keep a signed-in user waiting forever.
export function AuthVerificationBridge({ children, session }: { children: ReactNode; session: AuthSession }) {
  const { getToken, isLoaded, isSignedIn, signOut } = session
  const authIdentityId = session.userId ?? null
  const latestGetToken = useRef(getToken)
  const verificationAbort = useRef<AbortController | null>(null)
  const [verificationAttempt, setVerificationAttempt] = useState(0)
  const [authRecoveryRequired, setAuthRecoveryRequired] = useState(false)
  const latestAuthIdentityId = useRef(authIdentityId)
  const verificationRequest = useRef(0)
  const [apiCurrentUser, setApiCurrentUser] = useState<CurrentUser | null>(null)
  const [verifiedAuthIdentityId, setVerifiedAuthIdentityId] = useState<string | null>(null)
  const [activeCoachWorkspaceId, setActiveCoachWorkspaceState] = useState<number | null>(null)
  const [authError, setAuthError] = useState<string | null>(null)
  const [isVerifyingApi, setIsVerifyingApi] = useState(false)

  useLayoutEffect(() => {
    latestAuthIdentityId.current = authIdentityId
    setApiActorIdentity(authIdentityId)
  }, [authIdentityId])

  useLayoutEffect(() => { latestGetToken.current = getToken }, [getToken])

  useEffect(() => {
    setAuthTokenGetter(async () => {
      try {
        return await latestGetToken.current()
      } catch (error) {
        console.warn('Unable to load Clerk token', error)
        return null
      }
    })

    return () => setAuthTokenGetter(null)
  }, [])

  const refreshCurrentUser = useCallback(async () => {
    verificationAbort.current?.abort()
    setVerificationAttempt(attempt => attempt + 1)
    setAuthRecoveryRequired(false)
    setAuthError(null)
    if (!isLoaded || (isSignedIn && !authIdentityId)) return

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
      const controller = new AbortController()
      verificationAbort.current = controller
      const user = await fetchCurrentUser(controller.signal)
      if (requestId !== verificationRequest.current || latestAuthIdentityId.current !== requestedIdentityId) return
      if (user.clerk_id !== requestedIdentityId) {
        throw new Error('Unable to verify program access for this account')
      }
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
      setActiveCoachWorkspaceState(null)
      setActiveCoachWorkspaceId(null)
      setAuthRecoveryRequired(!(error instanceof ApiRequestError && error.status === 403))
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
      verificationRequest.current += 1
      verificationAbort.current?.abort()
    }
  }, [refreshCurrentUser])

  const hasVerifiedIdentity = Boolean(
    isLoaded && isSignedIn
    && authIdentityId
    && verifiedAuthIdentityId === authIdentityId
    && apiCurrentUser,
  )
  const currentUser = hasVerifiedIdentity ? apiCurrentUser : null
  const isApiIdentityPending = Boolean(isSignedIn) && !authError && (!authIdentityId || !hasVerifiedIdentity || isVerifyingApi)

  const verificationPending = !authError && (!isLoaded || Boolean(isSignedIn && (!hasVerifiedIdentity || isVerifyingApi)))
  useEffect(() => {
    if (!verificationPending) return
    const timer = window.setTimeout(() => {
      verificationRequest.current += 1
      verificationAbort.current?.abort()
      setApiCurrentUser(null)
      setVerifiedAuthIdentityId(null)
      setActiveCoachWorkspaceState(null)
      setActiveCoachWorkspaceId(null)
      setIsVerifyingApi(false)
      setAuthRecoveryRequired(true)
      setAuthError('The secure sign-in check took too long. Reload the page or try checking access again.')
    }, AUTH_VERIFICATION_TIMEOUT_MS)
    return () => window.clearTimeout(timer)
  }, [verificationPending, authIdentityId, verificationAttempt])

  const value = useMemo<AuthContextValue>(() => ({
    isClerkEnabled: true,
    authIdentityId,
    isSignedIn: Boolean(isSignedIn),
    isLoading: !isLoaded,
    isVerifyingApi: isApiIdentityPending,
    currentUser,
    activeCoachWorkspaceId: hasVerifiedIdentity ? activeCoachWorkspaceId : null,
    authError,
    authRecoveryRequired,
    refreshCurrentUser,
    selectCoachWorkspace,
    signOut: async () => { await signOut() },
  }), [activeCoachWorkspaceId, authError, authRecoveryRequired, authIdentityId, currentUser, hasVerifiedIdentity, isApiIdentityPending, isLoaded, isSignedIn, refreshCurrentUser, selectCoachWorkspace, signOut])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

function NoAuthBridge({ children }: { children: ReactNode }) {
  const pilotE2ERole = e2eAuthRole()
  const includeCoachWorkspaces = e2eCoachWorkspacesEnabled()
  const seedUser = useMemo(
    () => pilotE2ERole === 'admin' || pilotE2ERole === 'coach' || pilotE2ERole === 'participant'
      ? e2eCurrentUser(pilotE2ERole, includeCoachWorkspaces)
      : null,
    [includeCoachWorkspaces, pilotE2ERole],
  )

  const liveApi = import.meta.env.DEV && import.meta.env.VITE_E2E_AUTH === 'true' && new URLSearchParams(window.location.search).get('pilot_e2e_live_api') === 'true'
  const liveRequest = useRef(0)
  const liveMounted = useRef(true)
  const [apiUser, setApiUser] = useState<CurrentUser | null>(null)
  const [authError, setAuthError] = useState<string | null>(null)
  const [refreshing, setRefreshing] = useState(false)
  const currentUser = liveApi ? apiUser : seedUser
  const pilotE2EToken = seedUser && pilotE2ERole
    ? `test_token:${seedUser.clerk_id}:${seedUser.email}:${seedUser.first_name ?? ''}:${seedUser.last_name ?? ''}`
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
    setApiActorIdentity(seedUser?.clerk_id ?? null)
  }, [seedUser?.clerk_id])

  useLayoutEffect(() => {
    if (!includeCoachWorkspaces && !liveApi) return

    setActiveCoachWorkspaceId(activeCoachWorkspaceId)
  }, [activeCoachWorkspaceId, includeCoachWorkspaces, liveApi])

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

  const refreshCurrentUser = useCallback(async () => {
    if (!liveApi || !isTokenReady || !seedUser) return
    const request = ++liveRequest.current
    setRefreshing(true)
    setAuthError(null)
    try {
      const user = await fetchCurrentUser()
      if (!liveMounted.current || request !== liveRequest.current) return
      if (user.clerk_id !== seedUser.clerk_id) throw new Error('QA account identity did not match the API')
      const workspaceId = user.active_coach_workspace?.id ?? null
      setActiveCoachWorkspaceState(workspaceId)
      setActiveCoachWorkspaceId(workspaceId)
      setApiUser(user)
    } catch (error) {
      if (!liveMounted.current || request !== liveRequest.current) return
      setApiUser(null)
      setActiveCoachWorkspaceState(null)
      setActiveCoachWorkspaceId(null)
      setAuthError(error instanceof Error ? error.message : 'Unable to verify QA program access')
    } finally {
      if (liveMounted.current && request === liveRequest.current) setRefreshing(false)
    }
  }, [isTokenReady, liveApi, seedUser])

  useEffect(() => {
    let cancelled = false
    liveMounted.current = true
    queueMicrotask(() => { if (!cancelled && liveApi && isTokenReady) void refreshCurrentUser() })
    return () => { cancelled = true; liveMounted.current = false; liveRequest.current += 1 }
  }, [isTokenReady, liveApi, refreshCurrentUser])

  const value = useMemo<AuthContextValue>(() => ({
    isClerkEnabled: false,
    authIdentityId: seedUser?.clerk_id ?? null,
    isSignedIn: Boolean(seedUser),
    isLoading: false,
    isVerifyingApi: Boolean(pilotE2EToken && (!isTokenReady || (liveApi && (!apiUser && !authError || refreshing)))),
    currentUser,
    activeCoachWorkspaceId,
    authError,
    refreshCurrentUser,
    selectCoachWorkspace,
  }), [activeCoachWorkspaceId, apiUser, authError, currentUser, isTokenReady, liveApi, pilotE2EToken, refreshCurrentUser, refreshing, seedUser, selectCoachWorkspace])

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

function DelayedParticipantE2EAuthBridge({ children }: { children: ReactNode }) {
  const [currentUser, setCurrentUser] = useState<CurrentUser | null>(null)

  useLayoutEffect(() => {
    setApiActorIdentity(currentUser?.clerk_id ?? null)
  }, [currentUser?.clerk_id])

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
