import { useEffect, useState } from 'react'
import { Button } from './Button'
import './NewVersionNotice.css'

declare const __APP_BUILD_ID__: string
const BUILD_ID = typeof __APP_BUILD_ID__ === 'string' ? __APP_BUILD_ID__ : ''
const reloadPage = () => window.location.reload()

/** Checks only a tiny public file. A deploy never navigates or replaces a form. */
export function NewVersionNotice({ currentVersion = BUILD_ID, reload = reloadPage }: { currentVersion?: string; reload?: () => void }) {
  const [ready, setReady] = useState(false)
  const [waiting, setWaiting] = useState(false)
  useEffect(() => {
    if (!currentVersion) return
    const controller = new AbortController()
    let checking = false
    async function check() {
      if (document.visibilityState === 'hidden' || checking || controller.signal.aborted) return
      checking = true
      try {
        const response = await fetch('/version.json', { cache: 'no-store', signal: controller.signal })
        if (!response.ok) return
        const payload: unknown = await response.json()
        if (!controller.signal.aborted && payload && typeof payload === 'object' && 'version' in payload && typeof payload.version === 'string' && payload.version && payload.version !== currentVersion) setReady(true)
      } catch { /* Offline and older deployments quietly try again later. */ }
      finally { checking = false }
    }
    void check()
    const interval = window.setInterval(() => { void check() }, 5 * 60_000)
    window.addEventListener('focus', check)
    document.addEventListener('visibilitychange', check)
    return () => {
      controller.abort()
      window.clearInterval(interval)
      window.removeEventListener('focus', check)
      document.removeEventListener('visibilitychange', check)
    }
  }, [currentVersion])
  if (!ready) return null
  return <div className="app-version-notice" role="status">
    <div>
    <p className="app-version-title">A newer version is ready.</p>
    {waiting && <p>Save or cancel your open changes, then reload.</p>}
    </div>
    <Button onClick={() => {
      // Ask the same guards used by closing/reloading the tab, without leaving it
      // or opening a browser dialog. Any unsaved form can veto this reload.
      if (document.querySelector('[role="dialog"], [role="alertdialog"], dialog[open]') || !window.dispatchEvent(new Event('beforeunload', { cancelable: true }))) return setWaiting(true)
      reload()
    }}>Reload</Button>
  </div>
}
