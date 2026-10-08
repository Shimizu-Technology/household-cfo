import { useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { ProgramStartupGate } from '../Root'
import { BrandProvider } from '../contexts/BrandContext'
import { useBrand, NEUTRAL_BRAND } from '../contexts/brandContextValue'
import { AuthProvider } from '../contexts/AuthContext'
import { useAuthContext } from '../contexts/authContextValue'
import { IdentityBoundary } from '../components/IdentityBoundary'
import { BrandDocument } from '../components/BrandDocument'
import { WorkspaceOpening } from '../components/WorkspaceOpening'
import { AuthAccessPanel } from '../components/AuthAccessPanel'
import { SignInButton } from '../components/AuthControls'
import '../index.css'
import '../App.css'
import '../dialogViewport.css'

// This isolated DEV entry exercises the actual program/session/actor gates. Its
// final workspace is fictional, not the application or a financial-data test.
const params = new URLSearchParams(window.location.search)
const qaEnabled = import.meta.env.DEV && import.meta.env.VITE_E2E_AUTH === 'true'
if (qaEnabled && params.get('native_fake_api') === 'true') {
  const originalFetch = window.fetch.bind(window)
  let brandAttempts = 0
  window.fetch = async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input), window.location.href)
    const delay = url.pathname === '/api/public/brand' ? 1600 : url.pathname === '/api/auth/session' ? 700 : url.pathname === '/api/v1/auth/me' ? 800 : 700
    if (!['/api/public/brand', '/api/auth/session', '/api/v1/auth/me', '/api/v1/startup-qa/workspace'].includes(url.pathname)) return originalFetch(input, init)
    await new Promise<void>((resolve, reject) => {
      if (init?.signal?.aborted) { reject(new DOMException('Aborted', 'AbortError')); return }
      const abort = () => { window.clearTimeout(timer); reject(new DOMException('Aborted', 'AbortError')) }
      const timer = window.setTimeout(() => { init?.signal?.removeEventListener('abort', abort); resolve() }, delay)
      init?.signal?.addEventListener('abort', abort, { once: true })
    })
    if (url.pathname === '/api/public/brand') {
      if (params.get('brand_fail_once') === 'true' && ++brandAttempts === 1) return Response.json({}, { status: 503 })
      return Response.json({ brand: { ...NEUTRAL_BRAND, organization_name: 'Fictional startup QA' }, source: 'qa', available: true })
    }
    if (url.pathname === '/api/auth/session') return Response.json({ client_id: 'client_FICTIONAL1', user: { id: 'user_FICTIONAL1', email: 'fictional@pilot.test', first_name: 'Fictional', last_name: 'Participant' }, organization_id: 'org_FICTIONAL1', authentication_method: 'GoogleOAuth', access_token: 'fictional-short-lived', expires_at: new Date(Date.now() + 120000).toISOString() })
    if (url.pathname === '/api/v1/auth/me') return Response.json({ user: { id: 901, auth_provider: 'workos', auth_subject: 'user_FICTIONAL1', full_name: 'Fictional Participant', email: 'fictional@pilot.test', role: 'participant', is_participant: true, is_admin: false, is_coach: false, is_staff: false } })
    return Response.json({ ready: true })
  }
}

function FictionalWorkspace() {
  const [ready, setReady] = useState(false)
  const [failed, setFailed] = useState(false)
  useEffect(() => {
    const controller = new AbortController()
    void fetch('/api/v1/startup-qa/workspace', { signal: controller.signal })
      .then(response => { if (!response.ok) throw new Error('Unavailable'); if (!controller.signal.aborted) setReady(true) })
      .catch(() => { if (!controller.signal.aborted) setFailed(true) })
    return () => controller.abort()
  }, [])
  if (failed) return <WorkspaceOpening status="Getting your plan ready…" error="The fictional workspace could not load." onRetry={() => window.location.reload()} />
  if (!ready) return <WorkspaceOpening status="Getting your plan ready…" onRetry={() => window.location.reload()} />
  return <main className="app" data-testid="startup-verified-workspace"><h1>Verified workspace</h1><p>Fictional startup QA only. No household or financial information is loaded here.</p></main>
}

function StartupSurface() {
  const auth = useAuthContext()
  if (auth.authError) return <AuthAccessPanel title="We couldn’t finish checking your access." copy={auth.authError} recovering onRetry={auth.refreshCurrentUser} />
  if (auth.isLoading || auth.isVerifyingApi) return <WorkspaceOpening status="Signing you in securely…" onRetry={() => window.location.reload()} />
  if (!auth.currentUser) return <main className="app"><h1>Fictional sign-in</h1><SignInButton><button type="button">Sign in</button></SignInButton></main>
  return <FictionalWorkspace />
}

export function StartupQa() {
  const { status } = useBrand()
  return <AuthProvider provider="workos" clientId="client_FICTIONAL1" verificationEnabled={status === 'ready'}><BrandDocument /><ProgramStartupGate><IdentityBoundary><StartupSurface /></IdentityBoundary></ProgramStartupGate></AuthProvider>
}

if (qaEnabled) createRoot(document.getElementById('root')!).render(<BrandProvider><StartupQa /></BrandProvider>)
