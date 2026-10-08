import { useEffect, useRef, type ReactNode, type RefObject } from 'react'
import { useAuthContext } from '../contexts/authContextValue'
import { SignOutButton } from './AuthControls'

export function AccountMenu({ children, menuRef, onOpen }: { children?: ReactNode; menuRef?: RefObject<HTMLDetailsElement | null>; onOpen?: () => void }) {
  const auth = useAuthContext()
  const ownRef = useRef<HTMLDetailsElement>(null)
  const ref = menuRef ?? ownRef
  useEffect(() => {
    const dismiss = (event: PointerEvent) => {
      if (ref.current?.open && !ref.current.contains(event.target as Node)) ref.current.open = false
    }
    document.addEventListener('pointerdown', dismiss)
    return () => document.removeEventListener('pointerdown', dismiss)
  }, [ref])
  return <details ref={ref} className="shell-account-menu" onToggle={event => {
    if (event.currentTarget.open) onOpen?.()
  }} onKeyDown={event => {
    if (event.key === 'Escape' && !(event.target as HTMLElement).closest('dialog, [role="dialog"]')) {
      event.preventDefault()
      event.currentTarget.open = false
      event.currentTarget.querySelector<HTMLElement>('summary')?.focus({ preventScroll: true })
    }
  }} onBlur={event => {
    // Let a dialog launched from an account action manage its own focus.
    if (event.relatedTarget && !event.currentTarget.contains(event.relatedTarget as Node)) event.currentTarget.open = false
  }}>
    <summary aria-label="Account and help"><UsersIcon /><span>Account &amp; help</span></summary>
    <div className="shell-account-panel">
      {auth.currentUser && <div className="shell-account-identity">
        <strong>{auth.currentUser.full_name || 'Your account'}</strong>
        <span className="shell-account-role">{auth.currentUser.role}</span>
        {auth.currentUser.email && <span className="shell-account-email" title={auth.currentUser.email}>{auth.currentUser.email}</span>}
      </div>}
      {auth.isAuthEnabled && <SignOutButton />}
      {children}
    </div>
  </details>
}

function UsersIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M9.2 11.1a3.1 3.1 0 1 0 0-6.2 3.1 3.1 0 0 0 0 6.2ZM4.4 19.1c.55-3.1 2.2-4.65 4.8-4.65 2.58 0 4.22 1.55 4.78 4.65" className="icon-stroke" />
      <path d="M16.2 11.4a2.55 2.55 0 1 0 0-5.1M15.7 14.45c2.05.18 3.35 1.58 3.9 4.2" className="icon-stroke" />
    </svg>
  )
}
