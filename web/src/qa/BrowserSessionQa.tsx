import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { AuthProvider } from '../contexts/AuthContext'
import { useAuthContext } from '../contexts/authContextValue'
import { BrandContext, NEUTRAL_BRAND } from '../contexts/brandContextValue'
import { IdentityBoundary } from '../components/IdentityBoundary'
import { AuthAccessPanel } from '../components/AuthAccessPanel'
import { UserButton } from '../components/AuthControls'
import { captureBrowserAuthError } from '../lib/browserAuthSession'
import '../index.css'
import '../App.css'
import '../dialogViewport.css'
const callbackError = import.meta.env.DEV && import.meta.env.VITE_E2E_AUTH === 'true' ? captureBrowserAuthError() : null
export function BrowserSessionQa() {
  const auth = useAuthContext()
  const [draft, setDraft] = useState('')
  if (auth.authError) return <AuthAccessPanel title={auth.authErrorStatus === 401 ? 'Sign in again to continue.' : 'Secure access is temporarily unavailable.'} copy={auth.authError} recovering
    onRetry={auth.authErrorStatus !== 401 ? auth.refreshCurrentUser : undefined} onSignIn={auth.authErrorStatus === 401 ? auth.signIn : undefined} onSignOut={auth.isSignedIn ? auth.signOut : undefined} />
  if (auth.isLoading || auth.isVerifyingApi) return <AuthAccessPanel title="Verifying server-managed access" copy="Checking the secure session and approved program access." />
  if (!auth.currentUser) return <main className="app"><h1>Signed out</h1><button onClick={() => void auth.signIn?.()}>Sign in</button></main>
  return <main className="app" data-testid="server-verified-workspace"><h1>Verified server-session workspace</h1><p>{auth.currentUser.full_name}</p>
    <label>Unsaved private draft<input value={draft} onChange={event => setDraft(event.target.value)} /></label>
    <div style={{ display: 'flex', justifyContent: 'flex-end' }}><UserButton /></div>
  </main>
}
if (import.meta.env.DEV && import.meta.env.VITE_E2E_AUTH === 'true') {
  const brand = { brand: { ...NEUTRAL_BRAND, product_name: 'Household CFO', organization_name: 'Fictional server session QA' }, assistantName: 'Mia', hostname: 'localhost', source: 'qa', status: 'ready' as const, error: null, retry: () => undefined, isRuntimeBrand: false }
  createRoot(document.getElementById('root')!).render(<BrandContext.Provider value={brand}><AuthProvider provider="workos" clientId="client_FICTIONAL1" callbackError={callbackError}><IdentityBoundary><BrowserSessionQa /></IdentityBoundary></AuthProvider></BrandContext.Provider>)
}
