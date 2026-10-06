import { useAuthContext } from '../contexts/authContextValue'
import { AuthAccessPanel } from './AuthAccessPanel'
import { SignInButton } from './AuthControls'
import { Button } from './Button'
import { EnterpriseSettings } from './EnterpriseSettings'
import { useDialogViewport } from '../lib/useDialogViewport'

// IT contacts can reach configuration without loading a household or joining a cohort.
export function EnterpriseAccessPage() {
  useDialogViewport()
  const auth = useAuthContext()
  if (!auth.isSignedIn && !auth.isLoading) return <AuthAccessPanel title="Organization sign-in & provisioning" copy="Sign in with your designated IT administrator account to manage your company connection." footer={<div className="auth-actions"><SignInButton><Button>Sign in</Button></SignInButton></div>} />
  if (auth.isLoading || auth.isVerifyingApi) return <AuthAccessPanel title="Checking organization access." copy="Verifying your secure sign-in and configuration permissions." />
  if (!auth.currentUser || auth.authError) return <AuthAccessPanel title="Organization access could not be verified." copy={auth.authError ?? 'Your account has not been approved for company configuration.'} recovering onRetry={auth.refreshCurrentUser} onSignOut={auth.signOut} onSignIn={auth.signIn} />
  if (!auth.currentUser.is_admin && !auth.currentUser.enterprise_access?.organizations.some(org => org.it_admin)) return <AuthAccessPanel title="IT configuration access is required." copy="Ask your app administrator to designate you as an IT contact for your organization." onSignOut={auth.signOut} />
  return <EnterpriseSettings key={`${auth.authProvider}:${auth.authIdentityId}:${auth.currentUser.id}`} currentUser={auth.currentUser} onClose={() => window.location.assign('/')} />
}
