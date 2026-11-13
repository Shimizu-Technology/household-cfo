import { WorkspaceOpening } from './WorkspaceOpening'
import { PublicBrandMark } from './PublicBrandMark'
import { useBrand } from '../contexts/brandContextValue'

export function BrandBootstrapState() {
  const { brand, error, retry, status } = useBrand()
  const loading = status === 'loading'

  if (loading) return <WorkspaceOpening status="Checking your program…" onRetry={retry} />

  return (
    <main className="brand-bootstrap-state public-state">
      <PublicBrandMark />
      <section className="brand-bootstrap-panel ui-card" aria-busy={loading} aria-live="polite">
        <h1>{loading ? 'Loading your coaching workspace…' : status === 'error' ? 'Your program could not load' : brand.welcome_heading}</h1>
        <p role={error ? 'alert' : undefined}>
          {loading ? 'Confirming this program link before sign-in.' : error ?? brand.welcome_description}
        </p>
        {!loading && <button type="button" className="ui-btn ui-btn--primary" onClick={retry}>Try again</button>}
      </section>
    </main>
  )
}
