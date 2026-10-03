import { useBrand } from '../contexts/brandContextValue'

export function BrandBootstrapState() {
  const { brand, error, retry, status } = useBrand()
  const loading = status === 'loading'

  return (
    <main className="brand-bootstrap-state">
      <section className="brand-bootstrap-panel" aria-busy={loading} aria-live="polite">
        <span className="brand-bootstrap-mark" aria-hidden="true">V</span>
        <p className="eyebrow">{loading ? 'Opening your secure program' : brand.organization_name}</p>
        <h1>{loading ? 'Loading your coaching workspace…' : brand.welcome_heading}</h1>
        <p role={error ? 'alert' : undefined}>
          {loading ? 'Confirming this program link before sign-in.' : error ?? brand.welcome_description}
        </p>
        {!loading && <button type="button" onClick={retry}>Try again</button>}
      </section>
    </main>
  )
}
