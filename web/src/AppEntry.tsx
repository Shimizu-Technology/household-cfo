import { lazy, Suspense, useEffect } from 'react'
import { AuthLanding } from './components/AuthLanding'
import { WorkspaceOpening } from './components/WorkspaceOpening'
import { useAuthContext } from './contexts/authContextValue'

const loadApp = () => import('./App')
const App = lazy(loadApp)

// Signed-out visitors (every new participant opening an invite link) see the
// landing immediately; the workspace bundle downloads in the background so it
// is ready by the time sign-in finishes.
export function AppEntry() {
  const auth = useAuthContext()
  const signedOut = auth.isAuthEnabled && !auth.isLoading && !auth.isSignedIn && !(auth.authRecoveryRequired && auth.authError)

  useEffect(() => {
    if (!signedOut) return
    const warm = () => { void loadApp().catch(() => undefined) }
    if (typeof window.requestIdleCallback === 'function') {
      const handle = window.requestIdleCallback(warm, { timeout: 3000 })
      return () => window.cancelIdleCallback(handle)
    }
    const timer = setTimeout(warm, 1500)
    return () => clearTimeout(timer)
  }, [signedOut])

  if (signedOut) return <AuthLanding />
  return (
    <Suspense fallback={<WorkspaceOpening status="Opening your workspace…" />}>
      <App />
    </Suspense>
  )
}
