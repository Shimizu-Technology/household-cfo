// AuthKit state appears in redirect URLs. Carry navigation only, never arbitrary
// query parameters, free-text hashes, credentials, or financial records.
const sections = new Set(['Home', 'Review', 'Activity', 'Ask Mia', 'My Money', 'Budget', 'My Profile', 'Wealth', 'CFO Filter', 'Optionality', 'Statements', 'Coach Studio', 'Admin'])
export function safeAuthReturnTo(value: unknown, origin = window.location.origin): string {
  if (typeof value !== 'string' || value.length > 2048) return `${origin}/`
  try {
    const url = new URL(value, origin)
    if (url.origin !== origin || !['/', '/login', '/organization-access'].includes(url.pathname) || url.username || url.password) return `${origin}/`
    if (url.pathname === '/organization-access' || url.searchParams.get('enterprise') === '1') return `${origin}/organization-access`
    const destination = new URL('/', origin)
    const section = decodeURIComponent(url.hash.slice(1))
    if (sections.has(section)) destination.hash = encodeURIComponent(section)
    return destination.href
  } catch { return `${origin}/` }
}
const navigationPrefix = 'household-cfo:auth-navigation:'
const oauthStatePattern = /^[A-Za-z0-9_-]{1,256}$/
export function authReturnState(): { returnTo: string; navigationKey?: string } {
  const params = new URLSearchParams(window.location.search)
  const returnTo = safeAuthReturnTo(window.location.pathname === '/login' ? params.get('returnTo') : window.location.href)
  const oauthState = params.get('oauth_state_id')
  if (!oauthState || !oauthStatePattern.test(oauthState) || window.location.pathname !== '/') return { returnTo }
  // Keep the bank callback identifier in this tab, outside plaintext OAuth state.
  // The existing Plaid session remains bound to the verified permanent user ID.
  try {
    const navigationKey = crypto.randomUUID()
    window.sessionStorage.setItem(`${navigationPrefix}${navigationKey}`, JSON.stringify({ returnTo, oauthState, createdAt: Date.now() }))
    return { returnTo, navigationKey }
  } catch { return { returnTo } }
}
export function restoreAuthReturn({ state }: { state?: unknown }) {
  const values = state && typeof state === 'object' ? state as Record<string, unknown> : {}
  const destination = new URL(safeAuthReturnTo(values.returnTo))
  if (typeof values.navigationKey === 'string' && /^[a-f0-9-]{36}$/i.test(values.navigationKey)) {
    try {
      const key = `${navigationPrefix}${values.navigationKey}`
      const stored = window.sessionStorage.getItem(key)
      window.sessionStorage.removeItem(key)
      const navigation = stored ? JSON.parse(stored) : null
      if (navigation && navigation.returnTo === destination.href && typeof navigation.oauthState === 'string' && oauthStatePattern.test(navigation.oauthState)
        && Number.isFinite(navigation.createdAt) && Date.now() - navigation.createdAt >= 0 && Date.now() - navigation.createdAt <= 30 * 60_000) {
        destination.searchParams.set('oauth_state_id', navigation.oauthState)
      }
    } catch { /* A missing or expired tab snapshot falls back to safe app navigation. */ }
  }
  window.history.replaceState(null, '', destination.href)
  window.dispatchEvent(new HashChangeEvent('hashchange'))
}
