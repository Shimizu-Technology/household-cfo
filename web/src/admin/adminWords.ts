import type { AdminCohort, AdminUser, UserRole } from '../api'

// The words a coach reads on the Admin side. One place, so a group is always a "group".

export type InviteState = 'joined' | 'invited' | 'bounced' | 'removed'

export const inviteStateLabel: Record<InviteState, string> = { joined: 'Joined', invited: 'Invited', bounced: 'Email didn’t arrive', removed: 'Removed' }

export function inviteStateOf(user: AdminUser): InviteState {
  if (user.invitation_status === 'revoked') return 'removed'
  if (user.invitation_status === 'accepted') return 'joined'
  return user.invite_email.status === 'failed' ? 'bounced' : 'invited'
}

export const roleLabel: Record<UserRole, string> = { participant: 'Participant', coach: 'Coach', admin: 'Admin' }

export function setupWords(user: AdminUser): string {
  if (user.role !== 'participant' || user.invitation_status !== 'accepted') return '—'
  const status = user.workspace.setup_status
  return status === 'complete' ? 'Setup done' : status === 'started' ? 'Setup started' : 'Not started'
}

export function lastActiveAt(user: AdminUser): string | null {
  return user.workspace.last_safe_activity_at ?? user.last_sign_in_at ?? null
}

const dayFormat = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' })
const dayYearFormat = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' })

export function shortDay(value: string | null | undefined) {
  if (!value) return ''
  const date = new Date(value.length === 10 ? `${value}T00:00:00` : value)
  if (Number.isNaN(date.getTime())) return ''
  return date.getFullYear() === new Date().getFullYear() ? dayFormat.format(date) : dayYearFormat.format(date)
}

export function lastActiveWords(value: string | null, now = new Date()) {
  if (!value) return 'Not yet'
  const then = new Date(value)
  if (Number.isNaN(then.getTime())) return 'Not yet'
  const days = Math.floor((startOfDay(now) - startOfDay(then)) / 86_400_000)
  if (days <= 0) return 'Today'
  if (days === 1) return 'Yesterday'
  if (days < 7) return `${days} days ago`
  return shortDay(value)
}
const startOfDay = (date: Date) => new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime()

export const groupStatusLabel: Record<AdminCohort['status'], string> = { draft: 'Not started', enrolling: 'Signing up', active: 'Running', completed: 'Finished', archived: 'Archived' }

export function groupNames(user: AdminUser): string {
  return user.cohorts.map(item => item.cohort.name).join(', ')
}

/** "Bank of Guam 90 day savings · opens Nov 18 · 6 of 30 joined" */
export function groupLine(group: AdminCohort, joined: number, now = new Date()): string {
  const parts: string[] = []
  const challenge = group.savings_challenge?.enabled ? group.savings_challenge : undefined
  const starts = group.starts_on ? new Date(`${group.starts_on}T00:00:00`) : null
  if (challenge) {
    if (challenge.state === 'open') parts.push(starts && starts > now ? `opens ${shortDay(group.starts_on)}` : 'challenge open')
    else if (challenge.state === 'paused') parts.push('challenge paused')
    else if (starts && starts > now) parts.push(`starts ${shortDay(group.starts_on)}`)
    else parts.push(challenge.state === 'ready' ? 'ready to open' : 'challenge not open yet')
  } else if (group.status === 'completed' || group.status === 'archived') parts.push(groupStatusLabel[group.status].toLowerCase())
  else if (starts && starts > now) parts.push(`starts ${shortDay(group.starts_on)}`)
  else if (group.status === 'draft') parts.push('not started')
  else parts.push(groupStatusLabel[group.status].toLowerCase())
  parts.push(challenge ? `${joined} of ${challenge.capacity} joined` : `${joined} joined`)
  return [group.name, ...parts].join(' · ')
}
