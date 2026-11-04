import { useState } from 'react'
import { readCreatedProgram } from '../lib/programCreated'

export function ProgramCreatedNotice({ userId, workspaceId }: { userId: number; workspaceId: number | null }) {
  const [created] = useState(() => readCreatedProgram(userId, workspaceId))
  return created ? <p role="status" className="coach-studio-alert is-success">{created.name} was created and selected. You can now set up its assistant, appearance and groups.</p> : null
}
