import { useEffect, useState, type ReactNode } from 'react'
import { useBrand } from '../contexts/brandContextValue'
import './WorkspaceOpening.css'

export function OpeningProgress({ status }: { status: string }) {
  return <p className="opening-progress" role="status"><span className="opening-progress-indicator" aria-hidden="true" /><span>{status}</span></p>
}

// Keep geometry and the main message steady while independent startup stages finish.
export function WorkspaceOpening({ status, error, onRetry, recovery, children }: {
  status: string; error?: string | null; onRetry?: () => void; recovery?: ReactNode; children?: ReactNode
}) {
  const { brand, status: brandStatus } = useBrand()
  const [slow, setSlow] = useState(false)
  useEffect(() => {
    const timer = window.setTimeout(() => setSlow(true), 8_000)
    return () => window.clearTimeout(timer)
  }, [])
  return <main className="workspace-opening">
    <section className="workspace-opening-panel" aria-label="Opening workspace" aria-busy={!error}>
      <p className="workspace-opening-brand" title={brandStatus === 'ready' ? brand.organization_name : undefined}>{brandStatus === 'ready' ? brand.organization_name : 'Secure workspace'}</p>
      <h1>Opening your workspace…</h1>
      {error ? <p className="workspace-opening-error" role="alert">{error}</p> : <OpeningProgress status={status} />}
      {(error || slow) && <div className="workspace-opening-recovery">
        {!error && <p>This is taking a little longer. You can keep waiting or try again.</p>}
        {onRetry && <button type="button" className="secondary-button" onClick={onRetry}>Try again</button>}
        {recovery}
      </div>}
      {children}
    </section>
  </main>
}
