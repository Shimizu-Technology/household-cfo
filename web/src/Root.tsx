import { ClerkProvider } from '@clerk/clerk-react'
import App from './App'
import { AuthProvider } from './contexts/AuthContext'
import { PostHogProvider } from './providers/PostHogProvider'

const clerkPublishableKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY
const placeholderClerkKeys = new Set(['pk_test_xxx', 'pk_test_dummy', 'your_clerk_publishable_key', 'YOUR_PUBLISHABLE_KEY'])
const isClerkEnabled = Boolean(clerkPublishableKey && !placeholderClerkKeys.has(clerkPublishableKey))

if (!isClerkEnabled) {
  console.warn('Clerk is not configured. Household CFO is running in local preview mode without authentication.')
}

function Root() {
  const app = (
    <AuthProvider isClerkEnabled={isClerkEnabled}>
      <PostHogProvider>
        <App />
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
    >
      {app}
    </ClerkProvider>
  )
}

export default Root
