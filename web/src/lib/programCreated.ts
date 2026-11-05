const key = (userId: number) => `hcfo.programCreated:${userId}`
export type CreatedProgram = { id: number; name: string; at: number; invitation?: 'sent' | 'skipped' | 'failed' }
export function rememberCreatedProgram(userId: number | undefined, workspace: { id: number; name: string; owner_invitation?: { delivery?: { sent?: boolean; status?: string } } | null }) {
  if (userId == null) return
  try { sessionStorage.setItem(key(userId), JSON.stringify({ id: workspace.id, name: workspace.name, at: Date.now(), invitation: workspace.owner_invitation ? workspace.owner_invitation.delivery?.sent ? 'sent' : workspace.owner_invitation.delivery?.status === 'skipped' ? 'skipped' : 'failed' : undefined })) } catch { /* The selected program still confirms the saved outcome. */ }
}
export function readCreatedProgram(userId: number, workspaceId: number | null): CreatedProgram | null {
  try {
    const value = JSON.parse(sessionStorage.getItem(key(userId)) ?? 'null')
    return value?.id === workspaceId && typeof value.name === 'string' && Date.now() - value.at < 600_000 ? value : null
  } catch { return null }
}

export function clearCreatedProgram(userId: number) {
  try { sessionStorage.removeItem(key(userId)) } catch { /* Storage may be unavailable. */ }
}
