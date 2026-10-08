import { cloneElement, useRef, useState, type ReactElement, type MouseEvent } from 'react'
import { SignInButton as ClerkSignInButton, SignUpButton as ClerkSignUpButton } from '@clerk/clerk-react'
import { Button } from './Button'
import { useAuthContext } from '../contexts/authContextValue'

function HostedAuthButton({ children, signUp = false }: { children: ReactElement<{ onClick?: (event: MouseEvent<HTMLElement>) => void; disabled?: boolean }>; signUp?: boolean }) {
  const auth = useAuthContext()
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const start = async () => {
    setPending(true)
    setError(null)
    try {
      const action = signUp ? auth.signUp : auth.signIn
      if (!action) throw new Error('Secure sign-in is unavailable')
      await action()
    } catch {
      setError('Sign-in could not start. Check your connection and try again.')
    } finally { setPending(false) }
  }
  return <>{cloneElement(children, { disabled: pending, onClick: (event: MouseEvent<HTMLElement>) => { event.currentTarget.focus({ preventScroll: true }); void start() } })}{error && <p role="alert">{error}</p>}</>
}
export function SignInButton({ children, mode = 'modal' }: { children: ReactElement<{ onClick?: (event: MouseEvent<HTMLElement>) => void; disabled?: boolean }>; mode?: 'modal' | 'redirect' }) {
  const auth = useAuthContext()
  return auth.authProvider === 'workos' ? <HostedAuthButton>{children}</HostedAuthButton> : <ClerkSignInButton mode={mode}>{children}</ClerkSignInButton>
}
export function SignUpButton({ children, mode = 'modal' }: { children: ReactElement<{ onClick?: (event: MouseEvent<HTMLElement>) => void; disabled?: boolean }>; mode?: 'modal' | 'redirect' }) {
  const auth = useAuthContext()
  return auth.authProvider === 'workos' ? <HostedAuthButton signUp>{children}</HostedAuthButton> : <ClerkSignUpButton mode={mode}>{children}</ClerkSignUpButton>
}
export function SignOutButton({ onSignOut }: { onSignOut?: () => Promise<void> }) {
  const auth = useAuthContext()
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const inFlight = useRef(false)
  const signOut = async () => {
    if (inFlight.current) return
    inFlight.current = true
    setPending(true)
    setError(null)
    try {
      const action = onSignOut ?? auth.signOut
      if (!action) throw new Error('Secure sign-out is unavailable')
      await action()
    } catch {
      setError('Sign-out could not finish. Check your connection and try again.')
    } finally {
      inFlight.current = false
      setPending(false)
    }
  }
  return <div className="account-sign-out">
    <Button variant="secondary" size="compact" disabled={pending} onClick={() => void signOut()}>{pending ? 'Signing out…' : 'Sign out'}</Button>
    {error && <p role="alert">{error}</p>}
  </div>
}
