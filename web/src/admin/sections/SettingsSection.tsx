import { useEffect, useState, type ReactNode } from 'react'
import type { CurrentUser } from '../../api'
import { CoachProgramSettings } from '../../components/CoachProgramSettings'
import { EnterpriseSettings } from '../../components/EnterpriseSettings'
import { ProgramCreatedNotice } from '../../components/ProgramCreatedNotice'
import { WorkspaceCollaborators } from '../../components/WorkspaceCollaborators'
import { useCoachWorkspaceMutationLifecycle } from '../../components/coachWorkspaceMutationLifecycle'
import { Button } from '../../components/Button'
import { useAuthContext } from '../../contexts/authContextValue'
import { useAdminRoster } from '../useAdminRoster'
import { Activity } from './Activity'
import { BankHealth } from './BankHealth'
import './sections.css'

function Row({ title, hint, children }: { title: string; hint: string; children: ReactNode }) {
  return <details className="admin-accordion"><summary><strong>{title}</strong><small>{hint}</small></summary><div className="admin-accordion-body">{children}</div></details>
}

// Branding and team for everyone who manages a program; programs, bank health, access and activity for admins.
export function SettingsSection({ currentUser, onDirtyChange }: { currentUser: CurrentUser; onDirtyChange: (dirty: boolean) => void }) {
  const { activeCoachWorkspaceId } = useAuthContext()
  const lifecycle = useCoachWorkspaceMutationLifecycle(activeCoachWorkspaceId)
  const { details: groups, loading, error, reload } = useAdminRoster(currentUser)
  const [organizationOpen, setOrganizationOpen] = useState(false)
  // Two forms can be edited at once; leaving is only free when neither has unsaved changes.
  const [programDirty, setProgramDirty] = useState(false)
  const [teamDirty, setTeamDirty] = useState(false)
  useEffect(() => { onDirtyChange(programDirty || teamDirty) }, [programDirty, teamDirty, onDirtyChange])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])
  const platform = activeCoachWorkspaceId === null
  const organizationAccess = currentUser.is_admin || currentUser.enterprise_access?.organizations.some(org => org.it_admin)
  return <section className="admin-section">
    <ProgramCreatedNotice userId={currentUser.id} workspaceId={activeCoachWorkspaceId} />
    <header className="admin-section-head"><div><h2 data-page-heading tabIndex={-1}>Settings</h2><p>{platform ? 'Choose a program at the top to change its look or team.' : 'How your program looks, and who helps run it.'}</p></div></header>
    <div className="admin-accordion-list">
      {(!platform || currentUser.is_admin) && <Row title={platform ? 'Programs' : 'Name and look'} hint={platform ? 'Start a new program' : 'Program name, coach profile and welcome screen'}>
        <CoachProgramSettings workspaceId={activeCoachWorkspaceId} currentUser={currentUser} mutationLifecycle={lifecycle} onDirtyChange={setProgramDirty} />
      </Row>}
      {!platform && <Row title="Your team" hint="Who can help run this program"><WorkspaceCollaborators workspaceId={activeCoachWorkspaceId} mutationLifecycle={lifecycle} onDirtyChange={setTeamDirty} /></Row>}
      {currentUser.is_admin && <Row title="Who can do what" hint="What admins, coaches and participants can do">
        <ul className="admin-rules">
          <li><strong>Admin</strong> Runs everything, across every program and group.</li>
          <li><strong>Coach</strong> Helps the groups they belong to. Coaches can invite participants but can’t manage other staff.</li>
          <li><strong>Participant</strong> Uses the household app and Mia. Needs to be in a group.</li>
        </ul>
      </Row>}
      {currentUser.is_admin && <Row title="Bank connections" hint="Which connections are working"><BankHealth /></Row>}
      {organizationAccess && <Row title="Organization access" hint="Sponsor and organization sign-in"><Button variant="secondary" onClick={() => setOrganizationOpen(true)}>Open organization access</Button></Row>}
      {currentUser.is_admin && <Row title="Activity" hint="When challenges were opened or paused">{loading ? <p role="status" className="admin-muted">Opening the activity…</p>
        : error ? <p className="admin-alert error" role="alert">{error} <Button variant="secondary" size="compact" onClick={() => void reload()}>Try again</Button></p>
        : <Activity groups={groups} />}</Row>}
    </div>
    {organizationOpen && <EnterpriseSettings currentUser={currentUser} onClose={() => setOrganizationOpen(false)} />}
  </section>
}
