import { PublicBrandMark } from './PublicBrandMark'
import { useBrand } from '../contexts/brandContextValue'

export function AppErrorFallback({ resetError }: { resetError: () => void }) {
  const { brand } = useBrand()
  return (
    <main className="app public-state">
      <PublicBrandMark subtitle={brand.product_name} />
      <section className="auth-state-panel ui-card" role="alert">
        <h1>This screen hit an unexpected problem.</h1>
        <p>Try this screen again, or reload if the problem continues. After reloading, verify any changes you made just before the error.</p>
        <button type="button" className="ui-btn ui-btn--primary" onClick={resetError}>Try again</button>
      </section>
    </main>
  )
}
