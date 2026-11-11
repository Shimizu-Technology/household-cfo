import { useCallback, useEffect, useLayoutEffect, useState } from 'react'
import { AuthAccessPanel } from '../components/AuthAccessPanel'
import { AuthLanding } from '../components/AuthLanding'
import { BrandFooter } from '../components/BrandChrome'
import { SignOutButton } from '../components/AuthControls'
import { WorkspaceOpening } from '../components/WorkspaceOpening'
import { useAuthContext } from '../contexts/authContextValue'
import { useBrand } from '../contexts/brandContextValue'
import { adminPath, adminSectionsOf, navigateTo, parseAdminRoute, rememberMode, restoredMode, useLocationPath } from '../lib/appRoutes'
import { confirmDiscard } from '../lib/confirmAction'
import { setActiveParticipantCohortId } from '../api'
import { AdminShell } from './AdminShell'

// /admin/<section>. Everything the person may open comes from the server's
// `admin_sections`; anyone without sections gets one plain page and a way home.
export function AdminApp() {
  const auth = useAuthContext()
  const { brand } = useBrand()
  const path = useLocationPath()
  const route = parseAdminRoute(path)
  const user = auth.currentUser
  const sections = adminSectionsOf(user)
  const [dirty, setDirty] = useState(false)
  const ready = !auth.isVerifyingApi && !auth.isLoading && !auth.authError && (!auth.isAuthEnabled || auth.isSignedIn) && Boolean(user)
  const requested = route?.section ?? null
  const allowed = sections.find(section => section.key === requested)
  // /admin alone opens where the person last was, or their first section.
  const landing = (() => {
    const remembered = restoredMode(user)
    const rememberedKey = remembered.mode === 'admin' ? remembered.section : null
    return sections.find(section => section.key === rememberedKey) ?? sections[0]
  })()

  // The household app never carries a group from the Admin side, and the other way round.
  useLayoutEffect(() => { setActiveParticipantCohortId(null) }, [])
  useEffect(() => {
    if (!ready || !route) return
    if (!requested && landing) navigateTo(adminPath(landing.key), { replace: true })
    else if (allowed && user) rememberMode(user, { mode: 'admin', section: allowed.key })
  }, [allowed, landing, ready, requested, route, user])

  // Leaving with unsaved changes asks first; both in-app links and the address bar.
  const confirmLeave = useCallback(async () => !dirty || confirmDiscard('Discard your unsaved changes and leave this screen?'), [dirty])
  useEffect(() => {
    if (!dirty) return
    const leave = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
    window.addEventListener('beforeunload', leave)
    // Browser Back and Forward: an extra history entry on this same address takes the first
    // Back, so the question can be asked without the page underneath changing.
    if (!window.history.state?.adminLeaveGuard) window.history.pushState({ ...window.history.state, adminLeaveGuard: true }, '')
    const onBack = () => {
      void confirmDiscard('Discard your unsaved changes and leave this screen?').then(discard => {
        if (discard) { setDirty(false); window.history.back() }
        else window.history.pushState({ ...window.history.state, adminLeaveGuard: true }, '')
      })
    }
    window.addEventListener('popstate', onBack)
    return () => {
      window.removeEventListener('beforeunload', leave)
      window.removeEventListener('popstate', onBack)
      // Still on the guard entry means the changes ended here (saved, or discarded in place):
      // step back over it so the next Back goes where the person expects.
      if (window.history.state?.adminLeaveGuard) window.history.back()
    }
  }, [dirty])

  if (auth.isAuthEnabled && auth.authRecoveryRequired && auth.authError) return <AuthAccessPanel title={auth.authErrorStatus === 503 ? 'Secure access is temporarily unavailable.' : auth.authErrorStatus === 401 ? 'Sign in again to continue.' : 'We couldn’t finish checking your access.'} copy={auth.authError} recovering onRetry={!auth.isLoading && auth.authErrorStatus !== 401 && (auth.authIdentityId || auth.authProvider === 'workos' && (auth.authErrorStatus === 503 || auth.authErrorStatus === 409)) ? auth.refreshCurrentUser : undefined} onSignIn={auth.authErrorStatus === 401 ? auth.signIn : undefined} onSignOut={!auth.isLoading && auth.isSignedIn ? auth.signOut : undefined} footer={<BrandFooter />} />
  // Keep the same verified account's Admin side mounted while its name refreshes.
  if (auth.isLoading || (auth.isVerifyingApi && !user)) return <WorkspaceOpening status="Signing you in securely…" onRetry={() => window.location.reload()} recovery={!auth.isLoading && auth.isSignedIn ? <SignOutButton /> : undefined} />
  if (auth.isAuthEnabled && !auth.isSignedIn) return <AuthLanding />
  if (auth.authError || !user) return <AuthAccessPanel title="We couldn’t open this page." copy={auth.authError ?? 'Sign in again to continue.'} onSignOut={auth.isSignedIn ? auth.signOut : undefined} footer={<BrandFooter />} />

  if (sections.length === 0) return <main className="app staff-app admin-denied">
    <section className="hero-panel auth-panel">
      <h1>This page is for coaches and program staff</h1>
      <p>Your {brand.short_name} account opens on your own home page.</p>
      <div className="auth-actions"><a className="button button--primary" href="/" onClick={event => { if (event.button !== 0 || event.metaKey || event.ctrlKey) return; event.preventDefault(); rememberMode(user, { mode: 'app' }); navigateTo('/') }}>Go to {brand.short_name}</a></div>
    </section>
    <BrandFooter />
  </main>

  return <>
    {auth.isVerifyingApi && <WorkspaceOpening status="Checking your program access…" onRetry={() => window.location.reload()} />}
    <AdminShell currentUser={user} sections={sections} active={allowed ?? null} requested={requested} onDirtyChange={setDirty} confirmLeave={confirmLeave} hidden={auth.isVerifyingApi} />
  </>
}
