import { useEffect } from 'react'
import { AUTH_POPUP_MESSAGE } from '../lib/authPopup'
import { AuthAccessPanel } from './AuthAccessPanel'

export function AuthPopupComplete({ error }: { error?: string | null }) {
  useEffect(() => {
    try {
      if (window.opener) {
        window.opener.postMessage({ type: AUTH_POPUP_MESSAGE, ...(error ? { error: error.startsWith('Sign-in was canceled.') ? 'cancelled' : 'invalid' } : {}) }, window.location.origin)
        window.close()
      }
    } catch { /* A provider-isolated window still offers a normal app return. */ }
  }, [error])
  return <AuthAccessPanel title={error ? 'Sign-in could not finish.' : 'Return to your workspace'}
    copy={error ?? 'Your sign-in window is ready. Return to Household CFO to finish checking your program access.'}
    footer={<a className="button" href="/">Return to Household CFO</a>} />
}
