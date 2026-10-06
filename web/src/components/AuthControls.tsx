import { cloneElement, useEffect, useRef, useState, type ReactElement } from 'react'
import { SignInButton as ClerkSignInButton, SignUpButton as ClerkSignUpButton, UserButton as ClerkUserButton } from '@clerk/clerk-react'
import { useAuthContext } from '../contexts/authContextValue'

function HostedAuthButton({ children, signUp = false }: { children: ReactElement<{ onClick?: () => void; disabled?: boolean }>; signUp?: boolean }) {
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
  return <>{cloneElement(children, { disabled: pending, onClick: () => void start() })}{error && <p role="alert">{error}</p>}</>
}
export function SignInButton({ children, mode = 'modal' }: { children: ReactElement<{ onClick?: () => void; disabled?: boolean }>; mode?: 'modal' | 'redirect' }) {
  const auth = useAuthContext()
  return auth.authProvider === 'workos' ? <HostedAuthButton>{children}</HostedAuthButton> : <ClerkSignInButton mode={mode}>{children}</ClerkSignInButton>
}
export function SignUpButton({ children, mode = 'modal' }: { children: ReactElement<{ onClick?: () => void; disabled?: boolean }>; mode?: 'modal' | 'redirect' }) {
  const auth = useAuthContext()
  return auth.authProvider === 'workos' ? <HostedAuthButton signUp>{children}</HostedAuthButton> : <ClerkSignUpButton mode={mode}>{children}</ClerkSignUpButton>
}
export function UserButton({ afterSignOutUrl = '/' }: { afterSignOutUrl?: string }) {
  const auth = useAuthContext()
  const [open, setOpen] = useState(false)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const container = useRef<HTMLDivElement>(null)
  const trigger = useRef<HTMLButtonElement>(null)
  useEffect(() => {
    if (!open) return
    const dismiss = (event: PointerEvent) => { if (!container.current?.contains(event.target as Node)) setOpen(false) }
    document.addEventListener('pointerdown', dismiss)
    return () => document.removeEventListener('pointerdown', dismiss)
  }, [open])
  if (auth.authProvider !== 'workos') return <ClerkUserButton afterSignOutUrl={afterSignOutUrl} />
  const user = auth.currentUser
  return <div className="auth-account-control" ref={container} onKeyDown={event => {
    if (event.key === 'Escape') { setOpen(false); trigger.current?.focus() }
  }}>
    <button type="button" className="auth-account-trigger" aria-label="Account" aria-expanded={open} aria-controls="auth-account-panel" ref={trigger} onClick={() => setOpen(value => !value)}>
      <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><circle cx="12" cy="8" r="4" fill="none" stroke="currentColor" strokeWidth="1.7" /><path d="M4 21a8 8 0 0 1 16 0" fill="none" stroke="currentColor" strokeWidth="1.7" /></svg>
    </button>
    {open && <div id="auth-account-panel" className="auth-account-panel">
      <strong>{user?.full_name || 'Your account'}</strong>{user?.email && <p>{user.email}</p>}
      <button type="button" disabled={pending} onClick={async () => {
        setPending(true); setError(null)
        try { await auth.signOut?.() } catch { setError('Sign-out could not finish. Try again.') } finally { setPending(false) }
      }}>{pending ? 'Signing out…' : 'Sign out'}</button>
      {error && <p role="alert">{error}</p>}
    </div>}
  </div>
}
