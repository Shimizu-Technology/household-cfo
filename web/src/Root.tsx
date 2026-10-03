import { ClerkProvider } from '@clerk/clerk-react'
import App from './App'
import { AuthProvider } from './contexts/AuthContext'
import { PostHogProvider } from './providers/PostHogProvider'
import { BrandBootstrapState } from './components/BrandBootstrapState'
import { BrandDocument } from './components/BrandDocument'
import { IdentityBoundary } from './components/IdentityBoundary'
import { useBrand } from './contexts/brandContextValue'

const clerkPublishableKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY
const placeholderClerkKeys = new Set(['pk_test_xxx', 'pk_test_dummy', 'your_clerk_publishable_key', 'YOUR_PUBLISHABLE_KEY'])
const isClerkEnabled = Boolean(clerkPublishableKey && !placeholderClerkKeys.has(clerkPublishableKey))

if (!isClerkEnabled) {
  console.warn('Clerk is not configured. The coaching workspace is running in local preview mode without authentication.')
}

function Root() {
  const { brand, status } = useBrand()
  if (status !== 'ready') {
    return <><BrandDocument /><BrandBootstrapState /></>
  }

  const app = (
    <AuthProvider isClerkEnabled={isClerkEnabled}>
      <PostHogProvider>
        <BrandDocument />
        <IdentityBoundary><App /></IdentityBoundary>
      </PostHogProvider>
    </AuthProvider>
  )

  if (!isClerkEnabled) return app

  return (
    <ClerkProvider
      publishableKey={clerkPublishableKey}
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
