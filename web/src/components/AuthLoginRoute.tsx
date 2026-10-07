import { useEffect, useRef, useState } from 'react'
import { useAuthContext } from '../contexts/authContextValue'
import { AuthAccessPanel } from './AuthAccessPanel'
export function AuthLoginRoute() {
  const auth = useAuthContext()
  const { isLoading, signIn, authError } = auth
  const started = useRef(false)
  const [error, setError] = useState(false)
  useEffect(() => {
    if (authError || isLoading || started.current || !signIn) return
    started.current = true
    void signIn().catch(() => setError(true))
  }, [authError, isLoading, signIn])
  if (auth.authError) return <AuthAccessPanel title="Sign-in could not finish." copy={auth.authError} recovering
    onRetry={!auth.isLoading && auth.signIn ? auth.signIn : undefined} />
  return <AuthAccessPanel title={error ? 'Sign-in could not start.' : 'Sign in to your workspace'} copy={error ? 'Check your connection and try again.' : 'Use the sign-in dialog to continue. You can reopen it below if you closed it.'} recovering
    onRetry={auth.signIn ? async () => { setError(false); try { await auth.signIn!() } catch { setError(true) } } : undefined} />
}
