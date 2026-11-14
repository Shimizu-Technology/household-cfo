import { useEffect, useRef, type ReactNode, type RefObject } from 'react'
import { useAuthContext } from '../contexts/authContextValue'
import { restoreAccountFocus } from '../lib/accountFocus'
import { SignOutButton } from './AuthControls'

export function AccountMenu({ children, menuRef, onOpen, onClose, participantLabel = 'Household member' }: { participantLabel?: string; children?: ReactNode; menuRef?: RefObject<HTMLDetailsElement | null>; onOpen?: () => void; onClose?: () => void }) {
  const auth = useAuthContext()
  const ownRef = useRef<HTMLDetailsElement>(null)
  const ref = menuRef ?? ownRef
  useEffect(() => {
    const reposition = () => positionAccountPanel(ref.current)
    window.addEventListener('resize', reposition)
    document.addEventListener('scroll', reposition, true)
    const dismiss = (event: PointerEvent) => {
      if (ref.current?.open && !ref.current.contains(event.target as Node)) ref.current.open = false
    }
    document.addEventListener('pointerdown', dismiss)
    return () => {
      document.removeEventListener('pointerdown', dismiss)
      window.removeEventListener('resize', reposition)
      document.removeEventListener('scroll', reposition, true)
    }
  }, [ref])
  return <details ref={ref} className="shell-account-menu" onToggle={event => {
    if (event.currentTarget.open) { positionAccountPanel(event.currentTarget); onOpen?.() }
    else onClose?.()
  }} onKeyDown={event => {
    if (event.key === 'Escape' && !(event.target as HTMLElement).closest('dialog, [role="dialog"]')) {
      event.preventDefault()
      event.currentTarget.open = false
      restoreAccountFocus(event.currentTarget)
    }
  }} onBlur={event => {
    // Let a dialog launched from an account action manage its own focus.
    const boundary = event.currentTarget.closest('.admin-account-sheet')?.closest('[role="dialog"]') ?? event.currentTarget
    if (event.relatedTarget && !boundary.contains(event.relatedTarget as Node)) event.currentTarget.open = false
  }}>
    <summary aria-label="Account and help"><span className="shell-account-initial" aria-hidden="true">{Array.from(auth.currentUser?.full_name?.trim() || 'A')[0]}</span><span className="shell-account-name">{auth.currentUser?.full_name || 'Account & help'}</span></summary>
    <div className="shell-account-panel">
      {auth.currentUser && <div className="shell-account-identity">
        <strong>{auth.currentUser.full_name || 'Your account'}</strong>
        <span className="shell-account-role">{auth.currentUser.is_admin ? 'Administrator' : auth.currentUser.is_coach ? 'Coach' : participantLabel}</span>
        {auth.currentUser.email && <span className="shell-account-email" title={auth.currentUser.email}>{auth.currentUser.email}</span>}
      </div>}
      {auth.isAuthEnabled && <SignOutButton />}
      {children}
    </div>
  </details>
}

// Anchor to the visible avatar, or above the actual trigger in a scrolled sidebar.
function positionAccountPanel(menu: HTMLDetailsElement | null) {
  if (!menu?.open) return
  const summary = menu.querySelector('summary')?.getBoundingClientRect()
  if (!summary) return
  if (!menu.closest('.sidebar-account')) {
    menu.style.setProperty('--shell-account-top', `${Math.max(64, Math.min(summary.bottom + 8, 96))}px`)
    return
  }
  menu.style.setProperty('--shell-account-bottom', `${window.innerHeight - summary.top + 8}px`)
}
