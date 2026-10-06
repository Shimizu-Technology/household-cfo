import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { AuthKitProvider } from '@workos-inc/authkit-react'
import { AuthProvider } from '../contexts/AuthContext'
import { useAuthContext } from '../contexts/authContextValue'
import { captureAuthInvitation } from '../lib/authInvitation'
import '../index.css'
import '../App.css'
const invitation = captureAuthInvitation()
export function AuthInvitationQa() {
  const auth = useAuthContext()
  const [error, setError] = useState<string | null>(null)
  if (invitation.error) return <main className="app"><h1>This invitation needs a fresh link.</h1><p role="alert">{invitation.error}</p></main>
  const options = { organizationId: 'org_FICTIONAL1', returnTo: '/organization-access?income=4000' }
  return <main className="app"><h1>Development QA · fictional hosted invitation</h1><p>The invitation credential has been removed from this page’s URL.</p>
    <button disabled={auth.isLoading} onClick={() => void auth.signIn?.(options).catch(() => setError('Fictional sign-in could not start.'))}>Continue company sign-in</button>
    <button disabled={auth.isLoading} onClick={() => void auth.signUp?.(options).catch(() => setError('Fictional sign-up could not start.'))}>Create invited account</button>
    {error && <p role="alert">{error}</p>}
  </main>
}
if (import.meta.env.DEV && import.meta.env.VITE_E2E_AUTH === 'true') {
  createRoot(document.getElementById('root')!).render(<AuthKitProvider clientId="client_FICTIONAL1" apiHostname="auth-provider.test" redirectUri={`${window.location.origin}/auth/callback`} devMode={true}>
    <AuthProvider provider="workos" invitationToken={invitation.token}><AuthInvitationQa /></AuthProvider>
  </AuthKitProvider>)
}
