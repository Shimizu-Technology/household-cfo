import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react'
import type { ReactNode } from 'react'
import { useAuth } from '@clerk/clerk-react'
import { WorkosSignInDialog } from '../components/WorkosSignInDialog'
import { navigateAuthPopup, openAuthPopup, watchAuthPopup } from '../lib/authPopup'
import { safeAuthReturnTo } from '../lib/authNavigation'
import { BrowserSessionClient, restoreBrowserAuthNavigation } from '../lib/browserAuthSession'
import type { AuthProviderName } from '../lib/authConfig'
import { authIdentityKey, matchesAuthIdentity } from '../lib/authIdentity'
import { ApiRequestError, fetchCurrentUser, setActiveCoachWorkspaceId, setApiActorIdentity, setAuthTokenGetter } from '../api'
import type { CurrentUser } from '../api'
import { AuthContext } from './authContextValue'
import type { AuthContextValue, AuthSignInOptions } from './authContextValue'

export const AUTH_VERIFICATION_TIMEOUT_MS = 30_000

export type AuthSession = {
  provider?: AuthProviderName
  sessionScope?: string | null
  sessionError?: string | null
  sessionErrorStatus?: number | null
  reloadSession?: () => Promise<unknown>
  signIn?: (options?: AuthSignInOptions) => Promise<void>
  signUp?: (options?: AuthSignInOptions) => Promise<void>
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

function WorkOSAuthBridge({ children, invitationToken, clientId, callbackError }: { children: ReactNode; invitationToken?: string | null; clientId: string; callbackError?: string | null }) {
  const client = useMemo(() => new BrowserSessionClient(clientId), [clientId])
  const state = useSyncExternalStore(client.subscribe, client.getSnapshot)
  const [callbackFailure, setCallbackFailure] = useState(callbackError ?? null)
  const [dialog, setDialog] = useState<{ screen: 'sign-in' | 'sign-up'; options: AuthSignInOptions } | null>(null)
  const [externalError, setExternalError] = useState<string | null>(null)
  const externalAttempt = useRef<AbortController | null>(null)
  useEffect(() => {
    void client.load().catch(() => undefined)
    const expire = () => client.invalidate(new ApiRequestError('Your secure session expired. Sign in again to continue.', { status: 401 }))
    const check = () => { if (document.visibilityState === 'visible') void client.load().catch(() => undefined) }
    window.addEventListener('household-cfo:auth-expired', expire)
    window.addEventListener('focus', check)
    document.addEventListener('visibilitychange', check)
    return () => { externalAttempt.current?.abort(); client.dispose(); window.removeEventListener('household-cfo:auth-expired', expire); window.removeEventListener('focus', check); document.removeEventListener('visibilitychange', check) }
  }, [client])
  const start = useCallback(async (screen: 'sign-in' | 'sign-up', options: AuthSignInOptions = {}) => {
    externalAttempt.current?.abort()
    setExternalError(null)
    setDialog({ screen, options: { ...options, invitationToken: options.invitationToken ?? invitationToken ?? undefined,
      returnTo: options.returnTo ?? safeAuthReturnTo(window.location.pathname === '/login' ? new URLSearchParams(window.location.search).get('returnTo') : window.location.href) } })
  }, [invitationToken])
  const signIn = useCallback((options?: AuthSignInOptions) => start('sign-in', options), [start])
  const signUp = useCallback((options?: AuthSignInOptions) => start('sign-up', options), [start])
  const authenticated = async (returnTo: string) => {
    setCallbackFailure(null)
    setDialog(null)
    client.invalidate()
    await client.load()
    const destination = new URL(safeAuthReturnTo(returnTo))
    if (window.location.pathname !== destination.pathname) window.location.assign(destination.href)
    else if (window.location.hash !== destination.hash) {
      // Preserve a pending bank OAuth reference in the same tab.
      window.history.replaceState(window.history.state, '', `${window.location.pathname}${window.location.search}${destination.hash}`)
      window.dispatchEvent(new HashChangeEvent('hashchange'))
    }
    restoreBrowserAuthNavigation()
  }
  const externalSignIn = async (method: 'google' | 'sso', authorizationUrl?: string) => {
    if (!dialog) return
    setExternalError(null)
    // A pending policy flow already owns its browser-bound hosted attempt.
    if (authorizationUrl) { window.location.assign(authorizationUrl); return }
    const popup = openAuthPopup()
    const controller = new AbortController()
    externalAttempt.current?.abort()
    externalAttempt.current = controller
    const previousToken = client.getSnapshot().session?.access_token
    try {
      const redirect = await client.login(dialog.screen, { ...dialog.options, ...(method === 'google' ? { authenticationMethod: 'google' as const } : {}), popup: Boolean(popup) })
      if (controller.signal.aborted) { popup?.close(); return }
      if (!popup) { window.location.assign(redirect); return }
      const completion = watchAuthPopup(popup, () => { client.invalidate(); return client.load() }, previousToken, controller.signal)
      try { navigateAuthPopup(popup, redirect) } catch { controller.abort() }
      await completion
      if (!controller.signal.aborted) await authenticated(dialog.options.returnTo ?? window.location.origin)
    } catch (error) {
      popup?.close()
      if (!controller.signal.aborted) setExternalError(error instanceof Error && ['Sign-in was canceled. You can try again or continue with email.', 'Sign-in took too long. Please try again.'].includes(error.message) ? error.message : 'Sign-in could not finish. You can try again or continue with email.')
      throw error
    } finally { if (externalAttempt.current === controller) externalAttempt.current = null }
  }
  const signOut = useCallback(async () => { window.location.assign(await client.logout()) }, [client])
  const reloadSession = useCallback(async () => { setCallbackFailure(null); await client.load() }, [client])
  const session: AuthSession = {
    provider: 'workos', userId: state.session?.user.id, isLoaded: state.status !== 'loading', isSignedIn: Boolean(state.session),
    getToken: client.getAccessToken, signOut, signIn, signUp, reloadSession,
    sessionScope: `${state.session?.organization_id ?? ''}:${state.session?.authentication_method ?? ''}`,
    sessionError: callbackFailure ?? state.error?.message ?? null,
    sessionErrorStatus: callbackFailure ? 401 : state.error?.status ?? null,
  }
  return <AuthVerificationBridge session={session}>{children}{dialog && <WorkosSignInDialog
    client={client} screen={dialog.screen} options={dialog.options} externalError={externalError}
    onClose={() => { externalAttempt.current?.abort(); setDialog(null); setExternalError(null) }}
    onAuthenticated={authenticated} onExternalSignIn={externalSignIn} />}</AuthVerificationBridge>
}

// The session identity is sufficient for verification; a separate full-profile
// request must not keep a signed-in user waiting forever.
export function AuthVerificationBridge({ children, session }: { children: ReactNode; session: AuthSession }) {
  const { getToken, isLoaded, isSignedIn, signOut } = session
  const provider = session.provider ?? 'clerk'
  const authIdentityId = session.userId ?? null
  const subjectKey = authIdentityKey(provider, authIdentityId)
  const sessionKey = subjectKey && session.sessionScope ? `${subjectKey}:${session.sessionScope}` : subjectKey
  const sessionError = session.sessionError ?? null
  const latestGetToken = useRef(getToken)
  const latestProvider = useRef(provider)
  const verificationAbort = useRef<AbortController | null>(null)
  const [verificationAttempt, setVerificationAttempt] = useState(0)
  const [authRecoveryRequired, setAuthRecoveryRequired] = useState(false)
  const latestAuthIdentityId = useRef(sessionKey)
  const verificationRequest = useRef(0)
  const [apiCurrentUser, setApiCurrentUser] = useState<CurrentUser | null>(null)
  const [verifiedAuthIdentityId, setVerifiedAuthIdentityId] = useState<string | null>(null)
  const [activeCoachWorkspaceId, setActiveCoachWorkspaceState] = useState<number | null>(null)
  const [authErrorStatus, setAuthErrorStatus] = useState<number | null>(null)
  const [authError, setAuthError] = useState<string | null>(null)
  const [isVerifyingApi, setIsVerifyingApi] = useState(false)

  useLayoutEffect(() => {
    latestAuthIdentityId.current = sessionError ? null : sessionKey
    setApiActorIdentity(sessionError ? null : sessionKey)
  }, [sessionKey, sessionError])

  useLayoutEffect(() => { latestGetToken.current = getToken; latestProvider.current = provider }, [getToken, provider])

  useEffect(() => {
    setAuthTokenGetter(async () => {
      try {
        return await latestGetToken.current()
      } catch (error) {
        if (error instanceof ApiRequestError) throw error
        if (latestProvider.current === 'workos' && (error instanceof TypeError || error instanceof DOMException)) {
          throw new ApiRequestError('Secure sign-in is temporarily unavailable. Try again in a moment.', { status: 503 })
        }
        if (latestProvider.current === 'workos') window.dispatchEvent(new Event('household-cfo:auth-expired'))
        if (import.meta.env.DEV) console.warn('Unable to load secure sign-in token', error)
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
    setAuthErrorStatus(null)
    if (sessionError) return
    if (!isLoaded || (isSignedIn && !authIdentityId)) return

    const requestId = ++verificationRequest.current
    const requestedIdentityId = sessionKey
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
      if (!matchesAuthIdentity(user, provider, authIdentityId)) {
        throw new Error('Unable to verify program access for this account')
      }
      setApiActorIdentity(`${authIdentityKey(provider, authIdentityId, user.id)}:${session.sessionScope ?? ''}`)
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
      const status = error instanceof ApiRequestError ? error.status : null
      setAuthErrorStatus(status)
      setAuthRecoveryRequired(status !== 403)
      setAuthError(status === 401 ? 'Your secure session expired. Sign in again to continue.' : error instanceof Error ? error.message : 'Unable to verify program access')
    } finally {
      if (requestId === verificationRequest.current && latestAuthIdentityId.current === requestedIdentityId) {
        setIsVerifyingApi(false)
      }
    }
  }, [authIdentityId, isLoaded, isSignedIn, provider, sessionKey, sessionError, session.sessionScope])

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
    && !sessionError
    && verifiedAuthIdentityId === sessionKey
    && apiCurrentUser,
  )
  const currentUser = hasVerifiedIdentity ? apiCurrentUser : null
  const effectiveError = sessionError ?? authError
  const isApiIdentityPending = Boolean(isSignedIn) && !effectiveError && (!authIdentityId || !hasVerifiedIdentity || isVerifyingApi)

  const verificationPending = !effectiveError && (!isLoaded || Boolean(isSignedIn && (!hasVerifiedIdentity || isVerifyingApi)))
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
    isClerkEnabled: provider === 'clerk',
    isAuthEnabled: true,
    authProvider: provider,
    signIn: session.signIn,
    signUp: session.signUp,
    authErrorStatus: sessionError ? session.sessionErrorStatus ?? 401 : authErrorStatus,
    authIdentityId,
    isSignedIn: Boolean(isSignedIn),
    isLoading: !isLoaded,
    isVerifyingApi: isApiIdentityPending,
    currentUser,
    activeCoachWorkspaceId: hasVerifiedIdentity ? activeCoachWorkspaceId : null,
    authError: effectiveError,
    authRecoveryRequired: Boolean(sessionError) || authRecoveryRequired,
    refreshCurrentUser: sessionError && session.reloadSession ? async () => { await session.reloadSession!() } : refreshCurrentUser,
    selectCoachWorkspace,
    signOut: async () => { await signOut() },
  }), [activeCoachWorkspaceId, authErrorStatus, effectiveError, sessionError, provider, session.signIn, session.signUp, session.reloadSession, session.sessionErrorStatus, authRecoveryRequired, authIdentityId, currentUser, hasVerifiedIdentity, isApiIdentityPending, isLoaded, isSignedIn, refreshCurrentUser, selectCoachWorkspace, signOut])

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

export function AuthProvider({ children, isClerkEnabled = false, provider, invitationToken, clientId, callbackError }: { children: ReactNode; isClerkEnabled?: boolean; provider?: AuthProviderName | 'preview'; invitationToken?: string | null; clientId?: string; callbackError?: string | null }) {
  if (provider === 'workos') return <WorkOSAuthBridge invitationToken={invitationToken} clientId={clientId ?? import.meta.env.VITE_WORKOS_CLIENT_ID} callbackError={callbackError}>{children}</WorkOSAuthBridge>
  isClerkEnabled = provider === 'clerk' || isClerkEnabled
  if (!isClerkEnabled && e2eAuthRole() === 'delayed_participant') {
    return <DelayedParticipantE2EAuthBridge>{children}</DelayedParticipantE2EAuthBridge>
  }
  return isClerkEnabled ? <ClerkAuthBridge>{children}</ClerkAuthBridge> : <NoAuthBridge>{children}</NoAuthBridge>
}
