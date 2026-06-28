import { useEffect, useRef, type ReactNode } from 'react'
import { identifyAnalyticsUser, initializeAnalytics, resetAnalytics } from '../lib/analytics'
import { useAuthContext } from '../contexts/authContextValue'

export function PostHogProvider({ children }: { children: ReactNode }) {
  const auth = useAuthContext()
  const identifiedUserIdRef = useRef<number | null>(null)

  useEffect(() => {
    initializeAnalytics()
  }, [])

  useEffect(() => {
    if (auth.isLoading || auth.isVerifyingApi) return

    if (auth.currentUser) {
      if (identifiedUserIdRef.current !== auth.currentUser.id) {
        identifyAnalyticsUser(auth.currentUser)
        identifiedUserIdRef.current = auth.currentUser.id
      }
      return
    }

    if (identifiedUserIdRef.current !== null) {
      resetAnalytics()
      identifiedUserIdRef.current = null
    }
  }, [auth.currentUser, auth.isLoading, auth.isVerifyingApi])

  return <>{children}</>
}
