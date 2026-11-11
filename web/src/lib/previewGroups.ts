import { useSyncExternalStore } from 'react'
import type { CurrentUser } from '../api'

// The groups a coach or admin may use the app as. /auth/me supplies them; joining
// or leaving a group returns the fresh list, which is kept here so the menu and
// the shell agree without signing the person in again.
export type PreviewGroup = {
  cohort_id: number
  name: string
  status: 'draft' | 'enrolling' | 'active' | 'completed' | 'archived'
  program_name: string
  seated: boolean
  challenge: boolean
  challenge_joined: boolean
}

let override: { userId: number; groups: PreviewGroup[] } | null = null
const listeners = new Set<() => void>()

export function setPreviewGroups(userId: number, groups: PreviewGroup[]) {
  override = { userId, groups }
  listeners.forEach(listener => listener())
}

export function clearPreviewGroups() {
  override = null
  listeners.forEach(listener => listener())
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  return () => { listeners.delete(listener) }
}

export function previewGroupsOf(user: CurrentUser | null | undefined): PreviewGroup[] {
  if (!user) return []
  if (override?.userId === user.id) return override.groups
  return Array.isArray(user.preview_groups) ? user.preview_groups : []
}

export function usePreviewGroups(user: CurrentUser | null | undefined): PreviewGroup[] {
  useSyncExternalStore(subscribe, () => override)
  return previewGroupsOf(user)
}
