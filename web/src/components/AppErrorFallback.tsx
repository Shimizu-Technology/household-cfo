export function AppErrorFallback({ resetError }: { resetError: () => void }) {
  return (
    <main className="app">
      <section className="auth-state-panel" role="alert">
        <p className="eyebrow">Household CFO</p>
        <h1>This screen hit an unexpected problem.</h1>
        <p>Try this screen again, or reload if the problem continues. After reloading, verify any changes you made just before the error.</p>
        <button type="button" onClick={resetError}>Try again</button>
      </section>
    </main>
  )
}
