import type { CurrentUser } from '../api'

const key = (user: CurrentUser) => `household-cfo:admin-program:${user.auth_provider ?? 'test'}:${user.auth_subject ?? user.clerk_id}:${user.id}`

export function restoredAdminProgram(user: CurrentUser): number | null {
  const fallback = user.active_coach_workspace?.id ?? null
  if (!user.is_admin) return fallback
  try {
    const saved = localStorage.getItem(key(user))
    if (saved === 'all') return null
    const id = Number(saved)
    if (user.coach_workspaces?.some(workspace => workspace.id === id)) return id
    localStorage.removeItem(key(user))
  } catch { /* Storage is optional; server access is authoritative. */ }
  return fallback
}

export function rememberAdminProgram(user: CurrentUser | null, id: number | null): void {
  if (!user?.is_admin) return
  // A just-created program may not be in this callback's older user snapshot.
  // This is only a preference; restoration checks the fresh server access list.
  try { localStorage.setItem(key(user), id === null ? 'all' : String(id)) } catch { /* Selection still works without persistence. */ }
}
