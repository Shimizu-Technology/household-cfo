const PLAID_OAUTH_SESSION_KEY = 'household-cfo:plaid-oauth:v1'
const PLAID_OAUTH_SESSION_TTL_MS = 30 * 60 * 1000

export type PlaidOAuthSession = {
  userId: string
  linkToken: string
  updateItemId: number | null
  createdAt: number
}

type SessionStorage = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>

function browserStorage(): SessionStorage | null {
  if (typeof window === 'undefined') return null
  return window.localStorage
}

export function savePlaidOAuthSession(
  values: Omit<PlaidOAuthSession, 'createdAt'>,
  storage: SessionStorage | null = browserStorage(),
  now = Date.now(),
) {
  if (!storage) return
  storage.setItem(PLAID_OAUTH_SESSION_KEY, JSON.stringify({ ...values, createdAt: now }))
}

export function readPlaidOAuthSession(
  userId: string,
  storage: SessionStorage | null = browserStorage(),
  now = Date.now(),
): PlaidOAuthSession | null {
  if (!storage) return null

  try {
    const raw = storage.getItem(PLAID_OAUTH_SESSION_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw) as Partial<PlaidOAuthSession>
    const valid = parsed.userId === userId
      && typeof parsed.linkToken === 'string'
      && parsed.linkToken.startsWith('link-')
      && (parsed.updateItemId === null || typeof parsed.updateItemId === 'number')
      && typeof parsed.createdAt === 'number'
      && now - parsed.createdAt <= PLAID_OAUTH_SESSION_TTL_MS
      && parsed.createdAt <= now + 60_000
    if (valid) return parsed as PlaidOAuthSession
  } catch {
    // Treat malformed or unavailable browser storage as an expired session.
  }

  storage.removeItem(PLAID_OAUTH_SESSION_KEY)
  return null
}

export function clearPlaidOAuthSession(userId: string, storage: SessionStorage | null = browserStorage()) {
  if (!storage) return
  const session = readPlaidOAuthSession(userId, storage)
  if (session) storage.removeItem(PLAID_OAUTH_SESSION_KEY)
}

export function isPlaidOAuthReturn(href: string) {
  return new URL(href).searchParams.has('oauth_state_id')
}

export function completedPlaidOAuthUrl(href: string) {
  const url = new URL(href)
  url.searchParams.delete('oauth_state_id')
  url.hash = encodeURIComponent('My Profile')
  return `${url.pathname}${url.search}${url.hash}`
}
