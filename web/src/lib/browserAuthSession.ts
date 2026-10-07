import { ApiRequestError } from '../api'
import { authReturnState, restoreAuthReturn as restoreNavigation, safeAuthReturnTo } from './authNavigation'
import type { AuthSignInOptions } from '../contexts/authContextValue'

export type BrowserAuthSession = {
  client_id: string
  user: { id: string; first_name: string | null; last_name: string | null; email: string }
  organization_id: string | null
  authentication_method: string | null
  access_token: string
  expires_at: string
}
export type EmailAuthStep =
  | { step: 'code'; challenge_id: string; email: string; expires_at: string; resend_after: number }
  | { step: 'complete'; return_to: string }
  | { step: 'redirect'; authorization_url: string }

const EMAIL_ERRORS: Record<string, string> = {
  email_code_invalid: 'That code did not work. Check the newest email and try again.',
  email_challenge_expired: 'This code has expired. Start again to receive a new one.',
  auth_rate_limited: 'Please wait before trying again.',
  program_access_denied: 'This account cannot open this program. Use the email your program invited.',
  auth_unavailable: 'Secure sign-in is temporarily unavailable. Try again in a moment.',
}

export type BrowserSessionSnapshot = { status: 'loading' | 'ready' | 'error'; session: BrowserAuthSession | null; error: ApiRequestError | null }
const ERROR_COPY = 'Secure sign-in is temporarily unavailable. Try again in a moment.'
const ACCOUNT_CHANGED_COPY = 'Your account or organization changed. Check the current account before signing out.'
const NAVIGATION_KEY = 'household-cfo:server-auth-navigation'
const CALLBACK_ERRORS: Record<string, string> = {
  retry: ERROR_COPY,
  invalid: 'This sign-in link could not be verified. Start sign-in again.',
  cancelled: 'Sign-in was canceled. You can try again when you’re ready.',
}

// Rails has already consumed the hosted callback before these app routes load.
// Remove leftover callback parameters without interpreting state or changing
// invitations, bank callback references, or the intended app destination.
export function clearBrowserAuthCallbackParameters(provider: string) {
  if (provider !== 'workos') return
  const url = new URL(window.location.href)
  if (!['/', '/login', '/login/complete', '/organization-access'].includes(url.pathname)) return
  if (!url.searchParams.has('code') && !url.searchParams.has('state')) return
  url.searchParams.delete('code')
  url.searchParams.delete('state')
  window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`)
}

export function captureBrowserAuthError(): string | null {
  const url = new URL(window.location.href)
  if (!url.searchParams.has('auth_error')) return null
  const value = url.searchParams.get('auth_error') ?? ''
  url.searchParams.delete('auth_error')
  window.history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`)
  return CALLBACK_ERRORS[value] ?? CALLBACK_ERRORS.invalid
}

// Retain only opaque bank callback navigation in the originating tab. No
// authentication token or credential is persisted here.
export function restoreBrowserAuthNavigation() {
  try {
    const raw = sessionStorage.getItem(NAVIGATION_KEY)
    if (!raw) return
    const saved = JSON.parse(raw)
    if (!saved || !Number.isFinite(saved.createdAt) || Date.now() - saved.createdAt > 30 * 60_000 || Date.now() < saved.createdAt) {
      sessionStorage.removeItem(NAVIGATION_KEY); return
    }
    const destination = safeAuthReturnTo(saved.state?.returnTo)
    if (safeAuthReturnTo(window.location.href) !== destination || window.location.pathname === '/login') return
    sessionStorage.removeItem(NAVIGATION_KEY)
    // The existing helper validates the one-use tab snapshot and bank session.
    restoreNavigation({ state: saved.state })
  } catch { sessionStorage.removeItem(NAVIGATION_KEY) }
}

function identity(session: BrowserAuthSession | null) {
  return session ? `${session.user.id}:${session.organization_id ?? ''}:${session.authentication_method ?? ''}` : null
}
function checkedSession(payload: unknown, clientId: string): BrowserAuthSession | null {
  if (!payload || typeof payload !== 'object') throw new ApiRequestError(ERROR_COPY, { status: 503 })
  const data = payload as Partial<BrowserAuthSession> & { refresh_token?: unknown }
  if (data.client_id !== clientId || 'refresh_token' in data) throw new ApiRequestError('Secure sign-in configuration could not be verified. Contact your program support team.', { status: 503 })
  if (data.user === null) return null
  if (!data.user || typeof data.user.id !== 'string' || !data.user.id || typeof data.user.email !== 'string'
    || typeof data.access_token !== 'string' || !data.access_token || typeof data.expires_at !== 'string'
    || !Number.isFinite(Date.parse(data.expires_at)) || Date.parse(data.expires_at) <= Date.now()
    || !(data.organization_id === null || typeof data.organization_id === 'string')
    || !(data.authentication_method === null || typeof data.authentication_method === 'string')) {
    throw new ApiRequestError(ERROR_COPY, { status: 503 })
  }
  return data as BrowserAuthSession
}

export function checkedBrowserAuthRedirect(value: unknown, kind: 'login' | 'logout'): string {
  if (typeof value !== 'string') throw new ApiRequestError('The secure sign-in link could not be verified.', { status: 503 })
  let url: URL
  try { url = new URL(value) } catch { throw new ApiRequestError('The secure sign-in link could not be verified.', { status: 503 }) }
  if (kind === 'logout' && url.origin === window.location.origin && url.pathname === '/' && !url.search && !url.hash && !url.username && !url.password) return url.href
  const path = kind === 'login' ? '/user_management/authorize' : '/user_management/sessions/logout'
  if (url.origin !== 'https://api.workos.com' || url.pathname !== path || url.username || url.password) {
    throw new ApiRequestError('The secure sign-in link could not be verified. Contact your program support team.', { status: 503 })
  }
  if (kind === 'logout') {
    const returnTo = url.searchParams.get('return_to')
    if (returnTo !== window.location.origin && returnTo !== `${window.location.origin}/`) throw new ApiRequestError('The secure sign-out link could not be verified.', { status: 503 })
  }
  return url.href
}

// One client belongs to one mounted provider. All credentials returned by the
// session endpoint stay in this object; refresh credentials never enter JS.
export class BrowserSessionClient {
  private snapshot: BrowserSessionSnapshot = { status: 'loading', session: null, error: null }
  private listeners = new Set<() => void>()
  private request: Promise<BrowserAuthSession | null> | null = null
  private controller: AbortController | null = null
  private generation = 0
  private clientId: string
  constructor(clientId: string) { this.clientId = clientId }
  getSnapshot = () => this.snapshot
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener) } }
  private publish(snapshot: BrowserSessionSnapshot) { this.snapshot = snapshot; this.listeners.forEach(listener => listener()) }
  private async endpoint(path: string, body?: unknown, signal?: AbortSignal) {
    let response: Response
    try {
      response = await fetch(`/api/auth/${path}`, {
        method: body === undefined ? 'GET' : 'POST', credentials: 'same-origin', cache: 'no-store',
        headers: { 'X-Frontend-Origin': window.location.origin, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal,
      })
    } catch { throw new ApiRequestError(ERROR_COPY, { status: 503 }) }
    if (!response.ok) {
      const status = response.status === 401 ? 401 : response.status
      if (path.startsWith('email/')) {
        let code = 'auth_unavailable'
        let retryAfter: number | undefined
        try {
          const data = await response.json()
          if (typeof data.code === 'string' && Object.hasOwn(EMAIL_ERRORS, data.code)) code = data.code
          if (code === 'auth_rate_limited' && Number.isInteger(data.retry_after_sec) && data.retry_after_sec > 0 && data.retry_after_sec <= 3600) retryAfter = data.retry_after_sec
        } catch { /* Never expose provider errors. */ }
        throw new ApiRequestError(EMAIL_ERRORS[code], { status, code, payload: retryAfter === undefined ? {} : { retry_after_sec: retryAfter } })
      }
      if (status === 409) throw new ApiRequestError(ACCOUNT_CHANGED_COPY, { status, code: 'account_changed' })
      throw new ApiRequestError(status === 401 ? 'Your secure session expired. Sign in again to continue.' : ERROR_COPY, { status })
    }
    try { return await response.json() } catch { throw new ApiRequestError(ERROR_COPY, { status: 503 }) }
  }
  load = (): Promise<BrowserAuthSession | null> => {
    if (this.request) return this.request
    const generation = this.generation
    const controller = new AbortController(); this.controller = controller
    const timer = window.setTimeout(() => controller.abort(), 25_000)
    const request = (async () => {
      try {
        const session = checkedSession(await this.endpoint('session', undefined, controller.signal), this.clientId)
        if (generation !== this.generation) throw new ApiRequestError('Your account changed. Check access again.', { status: 409 })
        this.publish({ status: 'ready', session, error: null })
        return session
      } catch (caught) {
        const error = caught instanceof ApiRequestError ? caught : new ApiRequestError(ERROR_COPY, { status: 503 })
        if (generation === this.generation) this.publish({ status: 'error', session: error.status === 401 ? null : this.snapshot.session, error })
        throw error
      } finally {
        window.clearTimeout(timer)
        if (this.controller === controller) this.request = null
      }
    })()
    this.request = request
    return request
  }
  getAccessToken = async (): Promise<string | null> => {
    const expected = identity(this.snapshot.session)
    // Check the authoritative same-origin cookie on every logical operation;
    // concurrent callers share one read and cannot double-consume a refresh.
    const session = await this.load()
    if (expected && identity(session) !== expected) throw new ApiRequestError('Your account or organization changed. Reopen the current workspace.', { status: 409 })
    return session?.access_token ?? null
  }
  login = async (screenHint: 'sign-in' | 'sign-up', options: AuthSignInOptions & { authenticationMethod?: 'google'; popup?: boolean } = {}) => {
    if (options.organizationId && !/^org_[A-Za-z0-9]+$/.test(options.organizationId)) throw new ApiRequestError('The organization sign-in link could not be verified.', { status: 400 })
    const state = authReturnState()
    if (options.returnTo) state.returnTo = safeAuthReturnTo(options.returnTo)
    if (state.navigationKey) {
      try { sessionStorage.setItem(NAVIGATION_KEY, JSON.stringify({ state, createdAt: Date.now() })) } catch { /* Plain safe app navigation remains available. */ }
    }
    const response = await this.boundedAuth('login', { screen_hint: screenHint, return_to: state.returnTo,
      ...(options.organizationId ? { organization_id: options.organizationId } : {}),
      ...(options.invitationToken ? { invitation_token: options.invitationToken } : {}),
      ...(options.authenticationMethod ? { authentication_method: options.authenticationMethod } : {}),
      ...(options.popup ? { popup: true } : {}),
    })
    const redirect = checkedBrowserAuthRedirect(response.authorization_url, 'login')
    const url = new URL(redirect)
    if (url.searchParams.get('client_id') !== this.clientId || url.searchParams.get('redirect_uri') !== `${window.location.origin}/api/auth/callback`) throw new ApiRequestError('Secure sign-in configuration could not be verified.', { status: 503 })
    return redirect
  }
  private loginState(authorizationUrl: string): string {
    const url = new URL(checkedBrowserAuthRedirect(authorizationUrl, 'login'))
    const state = url.searchParams.get('state')
    if (url.searchParams.get('client_id') !== this.clientId || url.searchParams.get('redirect_uri') !== `${window.location.origin}/api/auth/callback`
      || !state || !/^[A-Za-z0-9_-]{43}$/.test(state)) throw new ApiRequestError(ERROR_COPY, { status: 503 })
    return state
  }
  loginStatus = async (authorizationUrl: string): Promise<{ status: 'pending' | 'cancelled' | 'complete' | 'account_changed' }> => {
    const response = await this.boundedAuth('login/status', { state: this.loginState(authorizationUrl) })
    if (!['pending', 'cancelled', 'complete', 'account_changed'].includes(response?.status)) throw new ApiRequestError(ERROR_COPY, { status: 503 })
    return { status: response.status }
  }
  cancelLogin = async (authorizationUrl: string): Promise<{ status: 'cancelled' | 'complete' | 'account_changed' }> => {
    const response = await this.boundedAuth('login/cancel', { state: this.loginState(authorizationUrl) })
    if (!['cancelled', 'complete', 'account_changed'].includes(response?.status)) throw new ApiRequestError(ERROR_COPY, { status: 503 })
    return { status: response.status }
  }
  private async boundedAuth(path: string, body?: unknown) {
    const controller = new AbortController()
    const timer = window.setTimeout(() => controller.abort(), 25_000)
    try { return await this.endpoint(path, body, controller.signal) } finally { window.clearTimeout(timer) }
  }
  authOptions = async (): Promise<{ google_enabled: boolean }> => {
    const response = await this.boundedAuth('options')
    if (typeof response?.google_enabled !== 'boolean') throw new ApiRequestError(ERROR_COPY, { status: 503 })
    return { google_enabled: response.google_enabled }
  }
  private checkedEmailStep(response: unknown): EmailAuthStep {
    const data = response && typeof response === 'object' ? response as Record<string, unknown> : {}
    if (data.step === 'code' && typeof data.challenge_id === 'string' && /^[A-Za-z0-9_-]{43}$/.test(data.challenge_id)
      && typeof data.email === 'string' && data.email.length <= 254 && typeof data.expires_at === 'string'
      && Number.isFinite(Date.parse(data.expires_at)) && typeof data.resend_after === 'number'
      && Number.isFinite(data.resend_after) && data.resend_after >= 0 && data.resend_after <= 600) {
      return { step: 'code', challenge_id: data.challenge_id, email: data.email, expires_at: data.expires_at, resend_after: data.resend_after }
    }
    if (data.step === 'complete' && typeof data.return_to === 'string') return { step: 'complete', return_to: safeAuthReturnTo(data.return_to) }
    if (data.step === 'redirect') {
      const authorization_url = checkedBrowserAuthRedirect(data.authorization_url, 'login')
      const url = new URL(authorization_url)
      if (url.searchParams.get('client_id') !== this.clientId || url.searchParams.get('redirect_uri') !== `${window.location.origin}/api/auth/callback`) throw new ApiRequestError(ERROR_COPY, { status: 503 })
      return { step: 'redirect', authorization_url }
    }
    throw new ApiRequestError(ERROR_COPY, { status: 503 })
  }
  startEmail = async ({ email, ...options }: AuthSignInOptions & { email: string }): Promise<EmailAuthStep> => {
    const returnTo = safeAuthReturnTo(options.returnTo ?? window.location.href)
    const normalized = email.trim().toLowerCase()
    const response = this.checkedEmailStep(await this.boundedAuth('email/start', { email: normalized, return_to: returnTo,
      ...(options.invitationToken ? { invitation_token: options.invitationToken } : {}),
      ...(options.organizationId ? { organization_id: options.organizationId } : {}),
    }))
    if (response.step === 'code' && response.email !== normalized) throw new ApiRequestError(ERROR_COPY, { status: 503 })
    return response
  }
  verifyEmail = async (challengeId: string, code: string): Promise<EmailAuthStep> => {
    if (!/^[A-Za-z0-9_-]{43}$/.test(challengeId) || !/^\d{6}$/.test(code)) throw new ApiRequestError(EMAIL_ERRORS.email_code_invalid, { status: 400, code: 'email_code_invalid' })
    return this.checkedEmailStep(await this.boundedAuth('email/verify', { challenge_id: challengeId, code }))
  }
  resendEmail = async (challengeId: string): Promise<EmailAuthStep> => {
    if (!/^[A-Za-z0-9_-]{43}$/.test(challengeId)) throw new ApiRequestError(EMAIL_ERRORS.email_challenge_expired, { status: 410, code: 'email_challenge_expired' })
    return this.checkedEmailStep(await this.boundedAuth('email/resend', { challenge_id: challengeId }))
  }
  cancelEmail = async (challengeId: string): Promise<void> => {
    if (!/^[A-Za-z0-9_-]{43}$/.test(challengeId)) return
    // Cancellation may return 204; unlike session reads it has no JSON payload.
    const controller = new AbortController()
    const timer = window.setTimeout(() => controller.abort(), 10_000)
    try { await fetch('/api/auth/email/cancel', { method: 'POST', credentials: 'same-origin', cache: 'no-store',
      headers: { 'X-Frontend-Origin': window.location.origin, 'Content-Type': 'application/json' },
      body: JSON.stringify({ challenge_id: challengeId }), signal: controller.signal }) } finally { window.clearTimeout(timer) }
  }
  logout = async () => {
    const expected = identity(this.snapshot.session)
    const current = await this.load()
    if (current && expected && identity(current) !== expected) throw new ApiRequestError(ACCOUNT_CHANGED_COPY, { status: 409, code: 'account_changed' })
    let response
    try {
      response = await this.endpoint('logout', current ? {
        expected_subject: current.user.id,
        expected_organization_id: current.organization_id,
      } : {})
    } catch (error) {
      if (error instanceof ApiRequestError && error.status === 409) this.invalidate(error)
      throw error
    }
    const redirect = checkedBrowserAuthRedirect(response.redirect_url, 'logout')
    this.invalidate()
    return redirect
  }
  invalidate = (error?: ApiRequestError) => {
    this.generation += 1; this.controller?.abort(); this.request = null
    this.publish({ status: error ? 'error' : 'ready', session: null, error: error ?? null })
  }
  dispose = () => { this.generation += 1; this.controller?.abort(); this.request = null }
}
