export function AppErrorFallback({ resetError }: { resetError: () => void }) {
  return (
    <main className="app">
      <section className="auth-state-panel" role="alert">
        <p className="eyebrow">Household CFO</p>
        <h1>This screen hit an unexpected problem.</h1>
        <p>Your approved household numbers were not changed. Try the screen again, or reload if the problem continues.</p>
        <button type="button" onClick={resetError}>Try again</button>
      </section>
    </main>
  )
}
