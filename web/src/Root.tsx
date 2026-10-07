import { ClerkProvider } from '@clerk/clerk-react'
import { useSyncExternalStore } from 'react'
import { captureAuthInvitation } from './lib/authInvitation'
import { authConfiguration } from './lib/authConfig'
import { captureBrowserAuthError, clearBrowserAuthCallbackParameters, restoreBrowserAuthNavigation } from './lib/browserAuthSession'
import { AuthAccessPanel } from './components/AuthAccessPanel'
import { AuthPopupComplete } from './components/AuthPopupComplete'
import { AuthLoginRoute } from './components/AuthLoginRoute'
import { EnterpriseAccessPage } from './components/EnterpriseAccessPage'
import App from './App'
import { AuthProvider } from './contexts/AuthContext'
import { PostHogProvider } from './providers/PostHogProvider'
import { BrandBootstrapState } from './components/BrandBootstrapState'
import { BrandDocument } from './components/BrandDocument'
import { IdentityBoundary } from './components/IdentityBoundary'
import { useBrand } from './contexts/brandContextValue'

const config = authConfiguration(import.meta.env, window.location.hostname)
const invitation = captureAuthInvitation()
clearBrowserAuthCallbackParameters(config.provider)
const callbackError = captureBrowserAuthError()
restoreBrowserAuthNavigation()
const navigationState = () => `${window.location.pathname}:${new URLSearchParams(window.location.search).get('enterprise') === '1'}`
function subscribeNavigation(callback: () => void) {
  window.addEventListener('hashchange', callback)
  window.addEventListener('popstate', callback)
  return () => { window.removeEventListener('hashchange', callback); window.removeEventListener('popstate', callback) }
}

function Root() {
  const route = useSyncExternalStore(subscribeNavigation, navigationState)
  const { brand, status } = useBrand()
  if (config.provider === 'workos' && route.startsWith('/login/complete:')) return <><BrandDocument /><AuthPopupComplete error={callbackError} /></>
  if (status !== 'ready') {
    return <><BrandDocument /><BrandBootstrapState /></>
  }

  if (config.error) return <><BrandDocument /><AuthAccessPanel title="Secure sign-in is unavailable." copy={config.error} /></>
  if (invitation.error) return <><BrandDocument /><AuthAccessPanel title="This invitation needs a fresh link." copy={invitation.error} /></>

  const app = (
    <AuthProvider provider={config.provider} invitationToken={invitation.token} clientId={config.clientId} callbackError={callbackError}>
      <PostHogProvider>
        <BrandDocument />
        <IdentityBoundary>{config.provider === 'workos' && route.startsWith('/login:') ? <AuthLoginRoute /> : route.startsWith('/organization-access:') || route.endsWith(':true') ? <EnterpriseAccessPage /> : <App />}</IdentityBoundary>
      </PostHogProvider>
    </AuthProvider>
  )

  if (config.provider === 'preview') return app
  if (config.provider === 'workos') return app

  return (
    <ClerkProvider
      publishableKey={config.clerkKey!}
      afterSignOutUrl="/"
      signInFallbackRedirectUrl="/"
      signUpFallbackRedirectUrl="/"
      appearance={{
        variables: {
          colorPrimary: brand.colors.primary,
          colorBackground: brand.colors.surface,
          colorText: brand.colors.text,
          colorTextSecondary: brand.colors.text_muted,
          fontFamily: 'var(--font-body)',
        },
      }}
    >
      {app}
    </ClerkProvider>
  )
}

export default Root
