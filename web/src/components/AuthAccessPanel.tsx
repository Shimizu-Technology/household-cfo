import { useState, type ReactNode } from 'react'
import { useBrand } from '../contexts/brandContextValue'

export function AuthAccessPanel({ title, copy, recovering = false, onRetry, onSignOut, footer }: {
  title: string; copy: string; recovering?: boolean; onRetry?: () => Promise<void>;
  onSignOut?: () => Promise<void>; footer?: ReactNode
}) {
  const { brand } = useBrand()
  const [failedLogo, setFailedLogo] = useState<string | null>(null)
  const byline = brand.powered_by_placement === 'header' && brand.powered_by_name ? `${brand.organization_name} powered by ${brand.powered_by_name}` : brand.organization_name
  return <main className="app loading-state auth-state">
    <section className="hero-panel auth-panel">
      {brand.logo_url && failedLogo !== brand.logo_url && <img className="shell-brand-logo" src={brand.logo_url} alt="" referrerPolicy="no-referrer" onError={() => setFailedLogo(brand.logo_url)} />}
      <p className="eyebrow">{byline}</p>
      <h1>{title}</h1>
      <p role={recovering ? 'alert' : 'status'}>{copy}</p>
      <p>Your workspace stays closed until your account access is verified.</p>
      <div className="auth-actions">
        {recovering && onRetry && <button type="button" onClick={() => void onRetry().catch(() => undefined)}>Check access again</button>}
        <button type="button" onClick={() => window.location.reload()}>Reload page</button>
        {onSignOut && <button type="button" onClick={() => void onSignOut().catch(() => undefined)}>Sign out</button>}
      </div>
    </section>
    {footer}
  </main>
}
