import { checkedBrowserAuthRedirect, type BrowserAuthSession } from './browserAuthSession'

export const AUTH_POPUP_MESSAGE = 'household-cfo:auth-complete'
const CANCELLED = 'Sign-in was canceled. You can try again or continue with email.'
const UNAVAILABLE = 'Sign-in could not finish. You can try again or continue with email.'

export function openAuthPopup(): Window | null {
  // Touch-first devices keep the provider's normal top-level browser flow.
  if (!window.matchMedia('(min-width: 768px) and (pointer: fine)').matches) return null
  try { return window.open('about:blank', '_blank', 'popup=yes,width=520,height=720') } catch { return null }
}

export function watchAuthPopup(popup: Window, readSession: () => Promise<BrowserAuthSession | null>, previousToken: string | undefined,
  signal: AbortSignal): Promise<BrowserAuthSession> {
  return new Promise((resolve, reject) => {
    let finished = false
    let checking = false
    let confirmationPending = false
    const finish = (error?: Error, session?: BrowserAuthSession) => {
      if (finished) return
      finished = true
      window.removeEventListener('message', message)
      window.removeEventListener('focus', focused)
      document.removeEventListener('visibilitychange', focused)
      signal.removeEventListener('abort', aborted)
      window.clearInterval(timer)
      window.clearTimeout(expiry)
      try { popup.close() } catch { /* Provider may isolate its window. */ }
      if (error) reject(error)
      else resolve(session!)
    }
    const check = async (confirmed: boolean) => {
      if (confirmed) confirmationPending = true
      if (finished || checking) return
      checking = true
      try {
        const session = await readSession()
        if (finished) return
        if (session && (confirmationPending || session.access_token !== previousToken)) finish(undefined, session)
        else if (confirmationPending) finish(new Error(UNAVAILABLE))
      } catch { if (confirmationPending && !finished) finish(new Error(UNAVAILABLE)) }
      finally { checking = false }
    }
    const message = (event: MessageEvent) => {
      if (event.origin !== window.location.origin || event.source !== popup || event.data?.type !== AUTH_POPUP_MESSAGE) return
      if (event.data.error) finish(new Error(event.data.error === 'cancelled' ? CANCELLED : UNAVAILABLE))
      else void check(true)
    }
    const focused = () => { if (document.visibilityState === 'visible') void check(false) }
    const aborted = () => finish(new Error(CANCELLED))
    window.addEventListener('message', message)
    window.addEventListener('focus', focused)
    document.addEventListener('visibilitychange', focused)
    signal.addEventListener('abort', aborted, { once: true })
    const expiry = window.setTimeout(() => finish(new Error('Sign-in took too long. Please try again.')), 10 * 60_000)
    const timer = window.setInterval(() => {
      if (document.visibilityState !== 'visible') return
      // COOP can sever the window relationship. Check the authoritative cookie
      // before interpreting a closed handle as cancellation.
      try {
        if (!checking && popup.closed) void check(false).finally(() => { if (!finished) finish(new Error(CANCELLED)) })
      } catch { /* Cross-origin windows may restrict window state. */ }
    }, 1000)
    if (signal.aborted) aborted()
  })
}

export function navigateAuthPopup(popup: Window, authorizationUrl: string) {
  popup.location.href = checkedBrowserAuthRedirect(authorizationUrl, 'login')
}
