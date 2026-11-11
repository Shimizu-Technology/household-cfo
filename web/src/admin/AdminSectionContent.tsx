import { useEffect, useState } from 'react'
import { fetchAdminPersonaAssignableCohorts } from '../api'
import type { AdminPersonaAssignableCohort, CurrentUser } from '../api'
import { useAuthContext } from '../contexts/authContextValue'
import type { AdminSection } from '../lib/appRoutes'
import { AdminConsole } from '../components/AdminConsole'
import { CoachChallengeDashboard } from '../components/CoachChallengeDashboard'
import { CoachProgramSettings } from '../components/CoachProgramSettings'
import { CoachStudio } from '../components/CoachStudio'
import { useCoachWorkspaceMutationLifecycle } from '../components/coachWorkspaceMutationLifecycle'
import { WorkspaceCollaborators } from '../components/WorkspaceCollaborators'

type Props = { section: AdminSection; currentUser: CurrentUser; onDirtyChange: (dirty: boolean) => void }

// Each section mounts the panels that already exist. Slice A2 reorganises what is
// inside them; this only decides where each one lives, so the layout and the
// routes stay put when the content changes.
export function AdminSectionContent({ section, currentUser, onDirtyChange }: Props) {
  switch (section.key) {
    case 'today': return <CoachStudio currentUser={currentUser} onDirtyChange={onDirtyChange} view="today" />
    case 'coaching': return <CoachStudio currentUser={currentUser} onDirtyChange={onDirtyChange} view="coaching" />
    case 'people': return <AdminConsole currentUser={currentUser} view="participants" onDirtyChange={onDirtyChange} />
    case 'groups': return <AdminConsole currentUser={currentUser} view="cohorts" onDirtyChange={onDirtyChange} />
    case 'support': return <AdminConsole currentUser={currentUser} view="feedback" onDirtyChange={onDirtyChange} />
    case 'reports': return <ReportsPanel currentUser={currentUser} />
    case 'settings': return <SettingsPanel currentUser={currentUser} onDirtyChange={onDirtyChange} />
  }
}

function ReportsPanel({ currentUser }: { currentUser: CurrentUser }) {
  const { activeCoachWorkspaceId } = useAuthContext()
  const [groups, setGroups] = useState<AdminPersonaAssignableCohort[] | null>(null)
  const [error, setError] = useState(false)
  useEffect(() => {
    // Platform administrators read the groups of every program; everyone else, their program's.
    if (activeCoachWorkspaceId === null && !currentUser.is_admin) return
    let live = true
    fetchAdminPersonaAssignableCohorts().then(next => { if (live) setGroups(next) }).catch(() => { if (live) setError(true) })
    return () => { live = false }
  }, [activeCoachWorkspaceId, currentUser.is_admin])
  return <section className="screen-grid admin-screen">
    <header className="screen-heading admin-heading"><h2 data-page-heading tabIndex={-1}>Reports</h2></header>
    {activeCoachWorkspaceId === null && !currentUser.is_admin ? <p className="admin-muted">Choose a program above to see its Day 30, 60 and 90 reports.</p>
      : error ? <p role="alert">We couldn’t load your groups. Reload to try again.</p>
      : groups === null ? <p role="status">Opening your reports…</p>
      : <CoachChallengeDashboard userId={currentUser.id} workspaceId={activeCoachWorkspaceId} cohorts={groups} reportsOnly />}
  </section>
}

function SettingsPanel({ currentUser, onDirtyChange }: { currentUser: CurrentUser; onDirtyChange: (dirty: boolean) => void }) {
  const { activeCoachWorkspaceId } = useAuthContext()
  const lifecycle = useCoachWorkspaceMutationLifecycle(activeCoachWorkspaceId)
  return <section className="screen-grid admin-screen">
    <header className="screen-heading admin-heading"><h2 data-page-heading tabIndex={-1}>Settings</h2></header>
    {activeCoachWorkspaceId === null && !currentUser.is_admin ? null : <CoachProgramSettings simple workspaceId={activeCoachWorkspaceId} currentUser={currentUser} mutationLifecycle={lifecycle} onDirtyChange={onDirtyChange} />}
    {activeCoachWorkspaceId !== null && <details className="coach-access-disclosure" open><summary>Your team</summary><WorkspaceCollaborators workspaceId={activeCoachWorkspaceId} mutationLifecycle={lifecycle} onDirtyChange={onDirtyChange} /></details>}
    {currentUser.is_admin && <><AdminConsole currentUser={currentUser} view="programs" /><AdminConsole currentUser={currentUser} view="health" /></>}
  </section>
}
