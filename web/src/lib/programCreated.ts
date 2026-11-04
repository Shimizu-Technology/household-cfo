const key = (userId: number) => `hcfo.programCreated:${userId}`
export type CreatedProgram = { id: number; name: string; at: number }
export function rememberCreatedProgram(userId: number | undefined, workspace: { id: number; name: string }) {
  if (userId == null) return
  try { sessionStorage.setItem(key(userId), JSON.stringify({ ...workspace, at: Date.now() })) } catch { /* The selected program still confirms the saved outcome. */ }
}
export function readCreatedProgram(userId: number, workspaceId: number | null): CreatedProgram | null {
  try {
    const value = JSON.parse(sessionStorage.getItem(key(userId)) ?? 'null')
    return value?.id === workspaceId && typeof value.name === 'string' && Date.now() - value.at < 600_000 ? value : null
  } catch { return null }
}
