import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import Root from './Root'
import { captureAnalyticsEvent } from './lib/analytics'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Root />
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
