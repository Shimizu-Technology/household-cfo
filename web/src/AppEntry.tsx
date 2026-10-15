import { useEffect, useState, type ComponentType } from 'react'
import { AuthLanding } from './components/AuthLanding'
import { WorkspaceOpening } from './components/WorkspaceOpening'
import { useAuthContext } from './contexts/authContextValue'

// Loaded with plain state rather than React.lazy/Suspense: Suspense reveals content
// on a timer, which stalls when a page (or test) pauses the clock.
let loadedApp: ComponentType | null = null
const loadApp = () => import('./App').then((module) => {
  loadedApp = module.default
  return module.default
})

// Signed-out visitors (every new participant opening an invite link) see the
// landing immediately; the workspace bundle downloads in the background so it
// is ready by the time sign-in finishes.
export function AppEntry() {
  const auth = useAuthContext()
  const signedOut = auth.isAuthEnabled && !auth.isLoading && !auth.isSignedIn && !(auth.authRecoveryRequired && auth.authError)
  const [App, setApp] = useState<ComponentType | null>(() => loadedApp)
  const [loadFailed, setLoadFailed] = useState(false)

  useEffect(() => {
    if (App) return
    let live = true
    const load = () => {
      loadApp()
        .then((component) => { if (live) setApp(() => component) })
        .catch(() => { if (live && !signedOut) setLoadFailed(true) })
    }
    if (!signedOut) {
      load()
      return () => { live = false }
    }
    // Warm the workspace while the landing is idle.
    if (typeof window.requestIdleCallback === 'function') {
      const handle = window.requestIdleCallback(load, { timeout: 3000 })
      return () => { live = false; window.cancelIdleCallback(handle) }
    }
    const timer = setTimeout(load, 1500)
    return () => { live = false; clearTimeout(timer) }
  }, [App, signedOut])

  if (signedOut) return <AuthLanding />
  if (App) return <App />
  // A failed chunk download usually means a newer version was deployed; reloading fetches it.
  // Match the status the workspace shows next, so the panel doesn't change wording mid-load.
  const status = auth.isAuthEnabled && (auth.isLoading || auth.isVerifyingApi) ? 'Signing you in securely…' : 'Opening your workspace…'
  return <WorkspaceOpening
    status={status}
    error={loadFailed ? 'Part of the app didn’t finish downloading. Reload to get the latest version.' : null}
    onRetry={() => window.location.reload()}
  />
}
