import { useCallback, useMemo, useRef, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { AuthVerificationBridge, type AuthSession } from '../contexts/AuthContext'
import { useAuthContext } from '../contexts/authContextValue'
import { BrandContext, NEUTRAL_BRAND } from '../contexts/brandContextValue'
import { AccountMenu } from '../components/AccountMenu'
import { Button } from '../components/Button'
import { AuthAccessPanel } from '../components/AuthAccessPanel'
import { EarlierMiaConversations } from '../components/EarlierMiaConversations'
import '../index.css'
import '../App.css'
import '../dialogViewport.css'

type SessionMode = 'ready' | 'sdk-pending' | 'identity-pending' | 'token-pending' | 'signed-out'
const modes: SessionMode[] = ['ready', 'sdk-pending', 'identity-pending', 'token-pending', 'signed-out']
const params = new URLSearchParams(window.location.search)
const initialMode = params.get('mode') as SessionMode | null
const qaIdentity = 'qa_auth_recovery_user'
const provider = params.get('provider') === 'workos' ? 'workos' : 'clerk'
const fictionalUser = {
  id: 901, clerk_id: qaIdentity, auth_provider: provider, auth_subject: qaIdentity, email: 'auth-recovery@pilot.test', first_name: 'Fictional',
  last_name: 'Participant', full_name: 'Fictional Participant', role: 'participant',
  is_admin: false, is_coach: false, is_participant: true, is_staff: false,
}

// Only this separate, development-only entry installs a synthetic response for
// native UI QA. Browser regression tests use the actual transport with routes.
if (import.meta.env.DEV && import.meta.env.VITE_E2E_AUTH === 'true' && params.get('native_fake_api') === 'true') {
  const originalFetch = window.fetch.bind(window)
  window.fetch = async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input), window.location.href)
    if (url.pathname === '/api/v1/mia/messages' && url.searchParams.get('picture') === 'history' && params.get('history_demo') === 'true') {
      if (init?.signal?.aborted) throw new DOMException('Request aborted', 'AbortError')
      return Response.json({
        messages: [
          { id: 11, author: 'YOU', content: 'These were my fictional practice numbers. My old monthly income was $4,200 and my practice card balance was $3,400.' },
          { id: 12, author: 'MIA', content: 'This earlier conversation is retained only for reference. Your new financial picture starts with unknown numbers until you confirm them. Earlier messages do not supply your active coaching context. You can close this private history and continue your fresh conversation.', financial_restart: { available: true }, presentation: { actions: [{ label: 'Old action must not appear' }] } },
        ],
        oldest_message_id: 11, older_message_count: 0, has_older_messages: false,
        historical_message_count: 2, picture: 'history', read_only: true, quick_prompts: [], disclaimer: null,
      })
    }
    if (url.pathname !== '/api/v1/auth/me') return originalFetch(input, init)
    if (init?.signal?.aborted) throw new DOMException('Request aborted', 'AbortError')
    return Response.json({ user: fictionalUser })
  }
}

function VerificationSurface({ onHistory }: { onHistory?: () => void }) {
  const auth = useAuthContext()
  if (auth.authRecoveryRequired && auth.authError) {
    return <AuthAccessPanel title={auth.authErrorStatus === 503 ? 'Secure access is temporarily unavailable.' : auth.authErrorStatus === 401 ? 'Sign in again to continue.' : 'We couldn’t finish checking your access.'} copy={auth.authError} recovering
      onRetry={!auth.isLoading && auth.authIdentityId && auth.authErrorStatus !== 401 ? auth.refreshCurrentUser : undefined}
      onSignIn={auth.authErrorStatus === 401 ? auth.signIn : undefined}
      onSignOut={!auth.isLoading && auth.isSignedIn ? auth.signOut : undefined} />
  }
  if (auth.isLoading || auth.isVerifyingApi) {
    return <AuthAccessPanel title="Verifying your Household CFO access" copy="Checking your secure program invitation before opening the workspace."
      onSignOut={!auth.isLoading && auth.isSignedIn ? auth.signOut : undefined} />
  }
  if (auth.authError) {
    return <AuthAccessPanel title="Your account does not have program access." copy={auth.authError} recovering
      onRetry={auth.refreshCurrentUser} onSignOut={auth.signOut} />
  }
  if (!auth.currentUser) return <main className="app"><h1>Signed out</h1></main>
  return <main className="app" data-testid="verified-workspace">
    {provider === 'workos' && <header className="shell-header"><div className="shell-brand"><div className="shell-brand-copy"><h1>Household CFO</h1></div></div><div className="shell-actions"><AccountMenu><Button variant="ghost" size="compact">Guide</Button><Button variant="ghost" size="compact">Report a problem</Button></AccountMenu></div></header>}
    <h1>Verified workspace</h1>
    <p>{auth.currentUser.full_name}</p><p>Verified session: {auth.authIdentityId}</p>
    <p>This fixture never requests a full Clerk profile.</p>

    {onHistory && <button type="button" onClick={onHistory}>Earlier conversations</button>}</main>
}

export function AuthRecoveryQa() {
  const [mode, setMode] = useState<SessionMode>(modes.includes(initialMode as SessionMode) ? initialMode! : 'ready')
  const [historyOpen, setHistoryOpen] = useState(false)
  const pendingToken = useRef<((token: string) => void) | null>(null)
  const getToken = useCallback(() => mode === 'token-pending'
    ? new Promise<string>(resolve => { pendingToken.current = resolve })
    : Promise.resolve('fictional-qa-session-token'), [mode])
  const signOut = useCallback(async () => { setMode('signed-out') }, [])
  const session = useMemo<AuthSession>(() => ({
    provider, signIn: async () => setMode('ready'),
    userId: mode === 'identity-pending' || mode === 'signed-out' ? null : qaIdentity,
    isLoaded: mode !== 'sdk-pending', isSignedIn: mode !== 'signed-out', getToken, signOut,
  }), [getToken, mode, signOut])
  const brand = useMemo(() => ({
    brand: { ...NEUTRAL_BRAND, product_name: 'Household CFO', organization_name: 'Household CFO Method powered by VERA' },
    assistantName: 'Mia', hostname: 'localhost', source: 'qa', status: 'ready' as const,
    error: null, retry: () => undefined, isRuntimeBrand: false,
  }), [])

  return <BrandContext.Provider value={brand}>
    <aside aria-label="Fictional auth QA controls" style={{ padding: '16px', display: 'flex', flexWrap: 'wrap', gap: '12px' }}>
      <strong>Development QA · fictional account</strong>
      <label>Session state <select aria-label="Session state" value={mode} onChange={event => setMode(event.target.value as SessionMode)}>
        {modes.map(value => <option key={value}>{value}</option>)}
      </select></label>
      <button type="button" onClick={() => pendingToken.current?.('fictional-late-token')}>Release late token</button>
    </aside>
    <AuthVerificationBridge session={session}>
      <VerificationSurface onHistory={params.get('history_demo') === 'true' ? () => setHistoryOpen(true) : undefined} />
      {historyOpen && <EarlierMiaConversations onClose={() => setHistoryOpen(false)} />}
    </AuthVerificationBridge>
  </BrandContext.Provider>
}

if (import.meta.env.DEV && import.meta.env.VITE_E2E_AUTH === 'true') {
  createRoot(document.getElementById('root')!).render(<AuthRecoveryQa />)
}
