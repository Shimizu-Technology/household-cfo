// A group created from "All programs" opens once the switch into its program
// has remounted Groups. The handoff is for that one remount: the same person,
// the same program, within a few seconds, and only the next Groups to mount.
type Handoff = { groupId: number; workspaceId: number; userId: number; at: number }

const WINDOW_MS = 5_000
let pending: Handoff | null = null

export function handOffGroupOpen(groupId: number, workspaceId: number, userId: number, now = Date.now()) {
  pending = { groupId, workspaceId, userId, at: now }
}

export function takeGroupOpen(userId: number, workspaceId: number | null, now = Date.now()): number | null {
  const handoff = pending
  pending = null
  if (!handoff || handoff.userId !== userId || handoff.workspaceId !== workspaceId || now - handoff.at > WINDOW_MS) return null
  return handoff.groupId
}

export function cancelGroupOpen(groupId: number) {
  if (pending?.groupId === groupId) pending = null
}
