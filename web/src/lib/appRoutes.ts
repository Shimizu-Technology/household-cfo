import { useSyncExternalStore } from 'react'
import type { CurrentUser } from '../api'
import { pushHistoryEntry } from './browserHistory'

// The app lives at "/" and the Admin side at "/admin/<section>". Sections come
// from the server (`admin_sections` on /auth/me); the client never works out
// roles itself.
export const ADMIN_BASE = '/admin'
export const ADMIN_SECTION_KEYS = ['today', 'people', 'groups', 'coaching', 'reports', 'support', 'settings'] as const
export type AdminSectionKey = typeof ADMIN_SECTION_KEYS[number]
export type AdminSectionAccess = 'full' | 'read_only'
export type AdminSection = { key: AdminSectionKey; label: string; access: AdminSectionAccess }

const NAVIGATE_EVENT = 'household-cfo:navigate'

export function adminPath(section: string = 'today') {
  return `${ADMIN_BASE}/${section}`
}

export type AdminRoute = { section: string | null }

/** `/admin` and `/admin/people` are Admin routes; anything else is the app. */
export function parseAdminRoute(pathname: string): AdminRoute | null {
  const match = /^\/admin(?:\/([^/]*))?\/?$/.exec(pathname)
  if (!match) return null
  const section = match[1] ? decodeURIComponent(match[1]) : null
  return { section }
}

// Local browser QA signs in through the address (`pilot_e2e_*`); keep those
// parameters when moving between the app and the Admin side.
function withLocalQaParams(path: string) {
  if (!import.meta.env.DEV || import.meta.env.VITE_E2E_AUTH !== 'true') return path
  const carried = [...new URLSearchParams(window.location.search)].filter(([name]) => name.startsWith('pilot_e2e_'))
  if (carried.length === 0) return path
  const url = new URL(path, window.location.origin)
  for (const [name, value] of carried) if (!url.searchParams.has(name)) url.searchParams.set(name, value)
  return `${url.pathname}${url.search}${url.hash}`
}

export function navigateTo(rawPath: string, { replace = false }: { replace?: boolean } = {}) {
  const path = withLocalQaParams(rawPath)
  // The Admin side's unsaved-changes marker belongs to the entry that set it, not to where we go next.
  const state = { ...(window.history.state ?? {}) } as Record<string, unknown>
  delete state.adminLeaveGuard
  if (replace) window.history.replaceState(state, '', path)
  else pushHistoryEntry(state, path)
  window.dispatchEvent(new Event(NAVIGATE_EVENT))
}

function subscribe(callback: () => void) {
  window.addEventListener('popstate', callback)
  window.addEventListener(NAVIGATE_EVENT, callback)
  return () => { window.removeEventListener('popstate', callback); window.removeEventListener(NAVIGATE_EVENT, callback) }
}

/** The current path, kept in step with back, forward and in-app navigation. */
export function useLocationPath() {
  return useSyncExternalStore(subscribe, () => window.location.pathname)
}

// Old hash links keep working. `#Admin` and `#Coach Studio` were screens inside
// one shell; they are now sections of the Admin side.
export function legacyStaffRedirect(location: Pick<Location, 'hash' | 'search'>): string | null {
  const hash = decodedHash(location.hash)
  if (hash === 'Admin') return `${adminPath('people')}${location.search}`
  if (hash !== 'Coach Studio') return null
  const params = new URLSearchParams(location.search)
  const area = params.get('coach_area')
  const target = area === 'assistant' || area === 'live' ? 'coaching' : 'today'
  return `${adminPath(target)}${location.search}`
}

function decodedHash(value: string) {
  try { return decodeURIComponent(value.replace(/^#/, '')) } catch { return '' }
}

const MODE_KEY = 'household-cfo:mode:v1:'
type RememberedMode = { mode: 'app' } | { mode: 'admin'; section: string }

function modeKey(user: Pick<CurrentUser, 'id'>) { return `${MODE_KEY}${user.id}` }

/** Remember where a signed-in person last was, so opening the site again returns them there. */
export function rememberMode(user: Pick<CurrentUser, 'id'> | null | undefined, mode: RememberedMode) {
  if (!user) return
  try { window.localStorage.setItem(modeKey(user), JSON.stringify(mode)) } catch { /* A remembered mode is a convenience only. */ }
}

export function restoredMode(user: Pick<CurrentUser, 'id'> | null | undefined): RememberedMode {
  if (!user) return { mode: 'app' }
  try {
    const value = JSON.parse(window.localStorage.getItem(modeKey(user)) ?? 'null')
    if (value?.mode === 'admin' && typeof value.section === 'string' && value.section) return { mode: 'admin', section: value.section }
  } catch { /* Fall back to the app. */ }
  return { mode: 'app' }
}

export function adminSectionsOf(user: CurrentUser | null | undefined): AdminSection[] {
  const sections = user?.admin_sections
  return Array.isArray(sections) ? sections : []
}
