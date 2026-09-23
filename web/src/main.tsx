import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import * as Sentry from '@sentry/react'
import './index.css'
import Root from './Root'
import { captureAnalyticsEvent } from './lib/analytics'

const sentryDsn = import.meta.env.VITE_SENTRY_DSN
if (sentryDsn) {
  Sentry.init({
    dsn: sentryDsn,
    enabled: import.meta.env.PROD,
    environment: import.meta.env.MODE,
    sendDefaultPii: false,
    sampleRate: 1,
    tracesSampleRate: 0.1,
    beforeSend(event) {
      if (event.request) event.request.data = undefined
      event.breadcrumbs = event.breadcrumbs?.map((breadcrumb) => ({ ...breadcrumb, data: undefined }))
      return event
    },
  })
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Sentry.ErrorBoundary fallback={({ resetError }) => (
      <main className="app">
        <section className="auth-state-panel" role="alert">
          <p className="eyebrow">Household CFO</p>
          <h1>This screen hit an unexpected problem.</h1>
          <p>Your approved household numbers were not changed. Try the screen again, or reload if the problem continues.</p>
          <button type="button" onClick={resetError}>Try again</button>
        </section>
      </main>
    )}>
      <Root />
    </Sentry.ErrorBoundary>
  </StrictMode>,
)

if ('serviceWorker' in navigator && import.meta.env.PROD) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => undefined)
  })
}

window.addEventListener('beforeinstallprompt', () => {
  captureAnalyticsEvent('pwa_install_prompt_available')
})

window.addEventListener('appinstalled', () => {
  captureAnalyticsEvent('pwa_installed')
})
