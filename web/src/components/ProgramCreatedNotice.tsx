import { useEffect, useState } from 'react'
import { clearCreatedProgram, readCreatedProgram } from '../lib/programCreated'

export function ProgramCreatedNotice({ userId, workspaceId }: { userId: number; workspaceId: number | null }) {
  const [created] = useState(() => readCreatedProgram(userId, workspaceId))
  useEffect(() => { if (created) clearCreatedProgram(userId) }, [created, userId])
  return created ? <p role="status" className="coach-studio-alert is-success">{created.name} was created and selected. You can now set up its assistant, appearance and groups.{created.invitation === 'sent' ? ' The owner invitation was emailed.' : created.invitation === 'skipped' ? ' No email was sent; share their sign-in link yourself.' : created.invitation === 'failed' ? ' The owner invitation email did not send; share their sign-in link yourself.' : ''}</p> : null
}
