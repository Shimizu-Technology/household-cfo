import type { CurrentUser } from '../api'
import { useAuthContext } from '../contexts/authContextValue'

export function AdminScope({ currentUser }: { currentUser: CurrentUser }) {
  const { activeCoachWorkspaceId } = useAuthContext()
  const name = currentUser.coach_workspaces?.find(workspace => workspace.id === activeCoachWorkspaceId)?.name
  return name ? <p className="admin-page-scope">{name}</p> : null
}
