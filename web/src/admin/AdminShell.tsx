import { useRef, useState } from 'react'
import type { CurrentUser } from '../api'
import { AccountMenu } from '../components/AccountMenu'
import { BrandFooter, BrandLogo } from '../components/BrandChrome'
import { Button } from '../components/Button'
import { EnterpriseSettings } from '../components/EnterpriseSettings'
import { PilotFeedbackDialog } from '../components/PilotFeedbackDialog'
import { SeoManager } from '../components/SeoManager'
import { useAuthContext } from '../contexts/authContextValue'
import { useBrand } from '../contexts/brandContextValue'
import { submitPilotFeedback } from '../api'
import { adminPath, navigateTo, rememberMode, type AdminSection } from '../lib/appRoutes'
import { AdminGuideDialog } from './AdminGuideDialog'
import { AdminSectionContent } from './AdminSectionContent'
import './AdminShell.css'

type Props = {
  currentUser: CurrentUser
  sections: AdminSection[]
  active: AdminSection | null
  requested: string | null
  onDirtyChange: (dirty: boolean) => void
  confirmLeave: () => Promise<boolean>
  hidden?: boolean
}

const descriptions: Record<string, string> = {
  today: 'Who needs you right now',
  people: 'Everyone you coach, and invitations',
  groups: 'Dates, status and opening the challenge',
  coaching: 'Your assistant’s voice, teaching and tools',
  reports: 'Day 30, 60 and 90 reports',
  support: 'Problems and setup help to look at',
  settings: 'Program look, team and access',
}

// The Admin side: a sidebar on desktop, a section menu on phones. The household
// app is one tap away at the top, and nothing here looks like the participant tabs.
export function AdminShell({ currentUser, sections, active, requested, onDirtyChange, confirmLeave, hidden }: Props) {
  const auth = useAuthContext()
  const { brand } = useBrand()
  const [guideOpen, setGuideOpen] = useState(false)
  const [feedbackOpen, setFeedbackOpen] = useState(false)
  const [enterpriseOpen, setEnterpriseOpen] = useState(false)
  const accountRef = useRef<HTMLDetailsElement>(null)
  const workspaces = currentUser.coach_workspaces ?? []
  const showProgram = workspaces.length > 1 || (currentUser.is_admin && workspaces.length > 0)
  const activeWorkspaceId = auth.activeCoachWorkspaceId

  const linkClick = (path: string) => (event: React.MouseEvent<HTMLAnchorElement>) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    event.preventDefault()
    event.currentTarget.closest('details')?.removeAttribute('open')
    void (async () => {
      if (!(await confirmLeave())) return
      onDirtyChange(false)
      navigateTo(path)
    })()
  }
  const goHome = (event: React.MouseEvent) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    event.preventDefault()
    void (async () => {
      if (!(await confirmLeave())) return
      onDirtyChange(false)
      rememberMode(currentUser, { mode: 'app' })
      navigateTo('/')
    })()
  }
  const closeHelp = (close: () => void) => { close(); requestAnimationFrame(() => accountRef.current?.querySelector<HTMLElement>('summary')?.focus()) }

  const programPicker = showProgram && <label className="admin-program-picker">
    <span>Program</span>
    <select aria-label="Program" value={activeWorkspaceId ?? 'platform'} onChange={async event => {
      const chosen = event.target.value === 'platform' ? null : Number(event.target.value)
      if (!(await confirmLeave())) return
      onDirtyChange(false)
      auth.selectCoachWorkspace(chosen)
    }}>
      {currentUser.is_admin && <option value="platform">All programs</option>}
      {workspaces.map(workspace => <option key={workspace.id} value={workspace.id}>{workspace.name}</option>)}
    </select>
  </label>

  return <main className="app staff-app admin-app" hidden={hidden} inert={hidden}>
    <SeoManager section="Admin" />
    <aside className="admin-sidebar" aria-label="Admin">
      <div className="admin-sidebar-brand"><BrandLogo brand={brand} /><strong>{brand.short_name} Admin</strong></div>
      <a className="admin-home-link" href="/" onClick={goHome}>My household</a>
      <nav className="admin-sidebar-nav" aria-label="Admin sections">
        {sections.map(section => <a key={section.key} href={adminPath(section.key)} aria-current={active?.key === section.key ? 'page' : undefined} onClick={linkClick(adminPath(section.key))}>
          <strong>{section.label}</strong><small>{descriptions[section.key]}</small>
        </a>)}
      </nav>
    </aside>
    <div className="admin-main">
      <header className="admin-header">
        <a className="admin-home-link admin-home-link--phone" href="/" onClick={goHome}>My household</a>
        <AccountMenu menuRef={accountRef} participantLabel="Coach">
          <Button variant="ghost" size="compact" onClick={event => { event.currentTarget.closest('details')?.removeAttribute('open'); setGuideOpen(true) }}>Guide</Button>
          <Button variant="ghost" size="compact" onClick={event => { event.currentTarget.closest('details')?.removeAttribute('open'); setFeedbackOpen(true) }}>Report a problem</Button>
          {(currentUser.is_admin || currentUser.enterprise_access?.organizations.some(org => org.it_admin)) && <Button variant="ghost" size="compact" onClick={event => { event.currentTarget.closest('details')?.removeAttribute('open'); setEnterpriseOpen(true) }}>Organization access</Button>}
        </AccountMenu>
        <details className="admin-section-menu">
          <summary aria-label="Admin sections"><span>{active?.label ?? 'Admin'}</span><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m6 9 6 6 6-6" /></svg></summary>
          <nav aria-label="Admin sections">
            {sections.map(section => <a key={section.key} href={adminPath(section.key)} aria-current={active?.key === section.key ? 'page' : undefined} onClick={linkClick(adminPath(section.key))}>
              <strong>{section.label}</strong><small>{descriptions[section.key]}</small>
            </a>)}
          </nav>
        </details>
      </header>
      <div className="admin-program">{programPicker}</div>
      <div className="admin-content">
        {active
          ? <AdminSectionContent key={`${active.key}:${activeWorkspaceId ?? 'platform'}`} section={active} currentUser={currentUser} onDirtyChange={onDirtyChange} />
          : requested && <section className="panel admin-unavailable" role="alert">
              <h2 data-page-heading tabIndex={-1}>That section isn’t part of your role</h2>
              <p>Your sections are in the menu. If you need more, ask a program owner.</p>
              <a className="button button--secondary" href={adminPath(sections[0]?.key)} onClick={linkClick(adminPath(sections[0]?.key))}>Go to {sections[0]?.label}</a>
            </section>}
      </div>
      <BrandFooter />
    </div>
    {guideOpen && <AdminGuideDialog onClose={() => closeHelp(() => setGuideOpen(false))} />}
    {feedbackOpen && <PilotFeedbackDialog initialWorkflow="admin" onClose={() => closeHelp(() => setFeedbackOpen(false))} onSubmit={submitPilotFeedback} />}
    {enterpriseOpen && <EnterpriseSettings currentUser={currentUser} onClose={() => setEnterpriseOpen(false)} />}
  </main>
}
