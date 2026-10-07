import type { CurrentUser } from '../api'
import type { AuthProviderName } from './authConfig'

export function matchesAuthIdentity(user: CurrentUser, provider: AuthProviderName, subject: string | null): boolean {
  if (!subject || !Number.isSafeInteger(user.id) || user.id <= 0) return false
  // Older Clerk responses remain compatible only while Clerk is selected.
  return provider === 'clerk' && !user.auth_provider && !user.auth_subject
    ? user.clerk_id === subject
    : user.auth_provider === provider && user.auth_subject === subject
}
export function authIdentityKey(provider: string, subject: string | null, userId?: number): string | null {
  return subject ? `${provider}:${subject}:${userId ?? 'pending'}` : null
}
