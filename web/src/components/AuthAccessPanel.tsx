import { useState, type ReactNode } from 'react'
import { PublicBrandMark } from './PublicBrandMark'

export function AuthAccessPanel({ title, copy, recovering = false, onRetry, onSignOut, onSignIn, footer, footerHasPrimaryAction = false }: {
  title: string; copy: string; recovering?: boolean; onRetry?: () => Promise<void>;
  onSignOut?: () => Promise<void>; onSignIn?: () => Promise<void>; footer?: ReactNode; footerHasPrimaryAction?: boolean
}) {
  const [actionError, setActionError] = useState<string | null>(null)
  return <main className="app loading-state auth-state public-state">
    <PublicBrandMark />
    <section className="hero-panel auth-panel ui-card">
      <h1>{title}</h1>
      <p role={recovering ? 'alert' : 'status'}>{copy}</p>
      <p>Your workspace stays closed until your account access is verified.</p>
      {actionError && <p role="alert">{actionError}</p>}
      <div className="auth-actions">
        {onSignIn && <button type="button" className="ui-btn ui-btn--primary" onClick={() => void onSignIn().catch(() => setActionError('Sign-in could not start. Check your connection and try again.'))}>Sign in again</button>}
        {recovering && onRetry && <button type="button" className={`ui-btn ${onSignIn ? 'ui-btn--tonal' : 'ui-btn--primary'}`} onClick={() => void onRetry().catch(() => undefined)}>Check access again</button>}
        <button type="button" className={`ui-btn ${onSignIn || (recovering && onRetry) || footerHasPrimaryAction ? 'ui-btn--tonal' : 'ui-btn--primary'}`} onClick={() => window.location.reload()}>Reload page</button>
        {onSignOut && <button type="button" className="ui-btn ui-btn--tonal" onClick={() => void onSignOut().catch(() => setActionError('Sign-out could not finish. Try again.'))}>Sign out</button>}
      </div>
      {footer}
    </section>
  </main>
}
