// Pending prompts and attachments belong only to the verified actor/program view.
export function miaWorkspaceStorageKey(prefix: string, userId?: number, coachWorkspaceId?: number | null, householdId?: number | null, cohortId?: number | null): string {
  if (!userId) return `${prefix}:preview`
  return `${prefix}:${userId ? `user-${userId}` : 'preview'}:${coachWorkspaceId ?? 'participant'}:${householdId ?? 'unverified'}:${cohortId ?? 'unverified'}`
}
