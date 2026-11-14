import { useEffect, useRef, useState } from 'react'
import type { CurrentUser } from '../api'
import { AccountMenu } from '../components/AccountMenu'
import { BrandFooter, BrandWordmark } from '../components/BrandChrome'
import { Button } from '../components/Button'
import { useWorkspaceMutationInFlight } from '../components/coachWorkspaceMutationLifecycle'
import { EnterpriseSettings } from '../components/EnterpriseSettings'
import { PilotFeedbackDialog } from '../components/PilotFeedbackDialog'
import { SeoManager } from '../components/SeoManager'
import { useAuthContext } from '../contexts/authContextValue'
import { useBrand } from '../contexts/brandContextValue'
import { submitPilotFeedback } from '../api'
import { adminPath, navigateTo, rememberMode, type AdminSection } from '../lib/appRoutes'
import { AdminGuideDialog } from './AdminGuideDialog'
import { AdminSectionContent } from './AdminSectionContent'
import { useShellSidebar } from '../lib/useShellSidebar'
import { useShellTextEntryNavigation } from '../lib/textEntry'
import { AdminMoreSheet } from './AdminMoreSheet'
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
  groups: 'Dates, tools and opening the challenge',
  coaching: 'Your coach’s voice and teaching',
  reports: 'Day 30, 60 and 90 reports',
  support: 'Problems and setup help to look at',
  settings: 'Program look, team and access',
}

// Sections and their order come only from the server; both shells share the visual vocabulary.
export function AdminShell({ currentUser, sections, active, requested, onDirtyChange, confirmLeave, hidden }: Props) {
  const auth = useAuthContext()
  const sidebar = useShellSidebar()
  const shellRef = useRef<HTMLDivElement>(null)
  const moreButtonRef = useRef<HTMLButtonElement>(null)
  useShellTextEntryNavigation(shellRef, '.admin-app')
  const [moreOpen, setMoreOpen] = useState(false)
  const [accountOpen, setAccountOpen] = useState(false)
  useEffect(() => {
    if (!sidebar && !hidden) return
    const frame = requestAnimationFrame(() => { setMoreOpen(false); setAccountOpen(false) })
    return () => cancelAnimationFrame(frame)
  }, [sidebar, hidden])
  const { brand } = useBrand()
  const [guideOpen, setGuideOpen] = useState(false)
  const [feedbackOpen, setFeedbackOpen] = useState(false)
  const [enterpriseOpen, setEnterpriseOpen] = useState(false)
  const accountRef = useRef<HTMLDetailsElement>(null)
  useEffect(() => {
    if (accountOpen && !sidebar && accountRef.current) accountRef.current.open = true
  }, [accountOpen, sidebar])
  const saving = useWorkspaceMutationInFlight()
  const workspaces = currentUser.coach_workspaces ?? []
  const showProgram = workspaces.length > 1
  const activeWorkspaceId = auth.activeCoachWorkspaceId
  const activeKey = active?.key ?? requested
  // A single program needs no picker. Resolve it through the auth context so
  // subsequent sections still come from the server for that program.
  const onlyWorkspaceId = workspaces.length === 1 ? workspaces[0].id : null
  useEffect(() => {
    if (onlyWorkspaceId !== null && activeWorkspaceId === null && !saving) auth.selectCoachWorkspace(onlyWorkspaceId)
  }, [onlyWorkspaceId, activeWorkspaceId, saving, auth])

  // Choosing another section moves focus to its heading, as the household app does for its
  // screens, so a keyboard or screen-reader user lands on the new content. Not on first load.
  const sectionShown = useRef(activeKey)
  useEffect(() => {
    if (sectionShown.current === activeKey) return
    sectionShown.current = activeKey
    let frame = 0
    let attempts = 0
    const focusHeading = () => {
      // The section may still be opening; wait a moment for its heading.
      const heading = document.querySelector<HTMLElement>('.admin-content [data-page-heading]')
      if (heading) heading.focus({ preventScroll: true })
      else if (attempts++ < 30) frame = window.requestAnimationFrame(focusHeading)
    }
    frame = window.requestAnimationFrame(focusHeading)
    return () => window.cancelAnimationFrame(frame)
  }, [activeKey])

  const linkClick = (path: string) => (event: React.MouseEvent<HTMLAnchorElement>) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    event.preventDefault()
    event.currentTarget.closest('details')?.removeAttribute('open')
    setMoreOpen(false)
    void (async () => {
      if (!(await confirmLeave())) return
      onDirtyChange(false)
      navigateTo(path)
    })()
  }
  const goHome = (event: React.MouseEvent) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    event.preventDefault()
    setMoreOpen(false)
    void (async () => {
      if (!(await confirmLeave())) return
      onDirtyChange(false)
      rememberMode(currentUser, { mode: 'app' })
      navigateTo('/')
    })()
  }
  const closeHelp = (close: () => void) => { close(); requestAnimationFrame(() => (accountRef.current?.querySelector<HTMLElement>('summary') ?? moreButtonRef.current)?.focus({ preventScroll: true })) }

  const closeMoreSurface = (account = false) => {
    if (account) setAccountOpen(false)
    else setMoreOpen(false)
    requestAnimationFrame(() => moreButtonRef.current?.focus({ preventScroll: true }))
  }

  const programPicker = showProgram && <label className="admin-program-picker">
    <span>Program</span>
    <select aria-label="Program" value={activeWorkspaceId ?? 'platform'} disabled={saving} onChange={async event => {
      const chosen = event.target.value === 'platform' ? null : Number(event.target.value)
      if (!(await confirmLeave())) return
      onDirtyChange(false)
      setMoreOpen(false)
      auth.selectCoachWorkspace(chosen)
    }}>
      {currentUser.is_admin && <option value="platform">All programs</option>}
      {workspaces.map(workspace => <option key={workspace.id} value={workspace.id}>{workspace.name}</option>)}
    </select>
  </label>

  const account = <AccountMenu menuRef={accountRef} participantLabel="Coach">
          <Button variant="ghost" size="compact" onClick={event => { event.currentTarget.closest('details')?.removeAttribute('open'); setAccountOpen(false); setGuideOpen(true) }}>Guide</Button>
          <Button variant="ghost" size="compact" onClick={event => { event.currentTarget.closest('details')?.removeAttribute('open'); setAccountOpen(false); setFeedbackOpen(true) }}>Report a problem</Button>
          {/* Settings holds Organization access for anyone who has it; this is only for an organization IT admin who does not. */}
          {!sections.some(section => section.key === 'settings') && (currentUser.is_admin || currentUser.enterprise_access?.organizations.some(org => org.it_admin)) && <Button variant="ghost" size="compact" onClick={event => { event.currentTarget.closest('details')?.removeAttribute('open'); setAccountOpen(false); setEnterpriseOpen(true) }}>Organization access</Button>}
        </AccountMenu>
  const primary = sections.slice(0, 4)
  const secondary = sections.slice(4)
  const scope = workspaces.find(workspace => workspace.id === activeWorkspaceId)?.name ?? `${currentUser.full_name} · ${currentUser.is_admin ? 'Administrator' : 'Coach'}`
  const sectionLink = (section: AdminSection, compact = false) => <a key={section.key} className={compact ? (active?.key === section.key ? 'active' : '') : 'shell-sidebar-link'} href={adminPath(section.key)} aria-current={active?.key === section.key ? 'page' : undefined} aria-label={`${section.label} ${descriptions[section.key]}`} onClick={linkClick(adminPath(section.key))}>
    <AdminIcon section={section.key} /><span>{section.label}</span><small className="sr-only">{descriptions[section.key]}</small>
  </a>

  return <div ref={shellRef} className="app staff-app admin-app" hidden={hidden} inert={hidden}>
    <SeoManager section="Admin" />
    <a className="shell-skip-link" href="#admin-main">Skip to content</a>
    <nav className="admin-sidebar shell-sidebar" aria-label="Admin">
      <div className="admin-sidebar-brand"><BrandWordmark brand={brand} /><p className="sidebar-scope" title={scope}>{scope}</p></div>
      <div className="admin-sidebar-nav">{sections.map(section => sectionLink(section))}</div>
      <a className="admin-home-link shell-sidebar-link" href="/" onClick={goHome}><AdminIcon section="household" />My household</a>
      {sidebar && <div className="sidebar-account">{account}</div>}
    </nav>
    <div className="tabs-ground" aria-hidden="true" />
    {!sidebar && <div className="tabs-shell admin-tabs-shell"><nav className="tabs" aria-label="Admin sections">
      {primary.map(section => sectionLink(section, true))}
      <button ref={moreButtonRef} type="button" className={`tabs-more-toggle${secondary.some(section => section.key === active?.key) ? ' active' : ''}`} aria-label="More" aria-expanded={moreOpen} aria-controls="admin-more-sections" onClick={() => setMoreOpen(open => !open)}><AdminIcon section="more" /><span>More</span></button>
    </nav></div>}
    <div className="admin-main">
      <header className="admin-header">{!sidebar && <BrandWordmark brand={brand} />}{sidebar && programPicker}</header>
      <main className="admin-content" id="admin-main" tabIndex={-1}>
        {active
          ? <AdminSectionContent key={`${active.key}:${activeWorkspaceId ?? 'platform'}`} section={active} currentUser={currentUser} onDirtyChange={onDirtyChange} />
          : requested && <section className="panel admin-unavailable" role="alert">
              <h2 data-page-heading tabIndex={-1}>That section isn’t part of your role</h2>
              <p>Your sections are in the menu. If you need more, ask a program owner.</p>
              <a className="button button--secondary" href={adminPath(sections[0]?.key)} onClick={linkClick(adminPath(sections[0]?.key))}>Go to {sections[0]?.label}</a>
            </section>}
      </main>
      <BrandFooter />
    </div>
    {!hidden && !sidebar && moreOpen && <AdminMoreSheet onClose={() => closeMoreSurface()}>
      {programPicker}
      {secondary.map(section => sectionLink(section))}
      <a className="admin-home-link" href="/" onClick={goHome}><AdminIcon section="household" /><span>My household</span></a>
      <button type="button" className="tabs-account-row ui-row" onClick={() => { setMoreOpen(false); setAccountOpen(true) }}>Account and help<span aria-hidden="true">›</span></button>
    </AdminMoreSheet>}
    {!hidden && !sidebar && accountOpen && <AdminMoreSheet title="Account and help" onClose={() => closeMoreSurface(true)}><div className="admin-account-sheet">{account}</div></AdminMoreSheet>}
    {guideOpen && <AdminGuideDialog onClose={() => closeHelp(() => setGuideOpen(false))} />}
    {feedbackOpen && <PilotFeedbackDialog initialWorkflow="admin" onClose={() => closeHelp(() => setFeedbackOpen(false))} onSubmit={submitPilotFeedback} />}
    {enterpriseOpen && <EnterpriseSettings currentUser={currentUser} onClose={() => closeHelp(() => setEnterpriseOpen(false))} />}
  </div>
}

const iconPaths: Record<string, string> = {
  today: 'M4 11l8-7 8 7v9h-6v-6h-4v6H4z',
  people: 'M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7M3 21v-2a6 6 0 0 1 12 0v2M17 4a3.5 3.5 0 0 1 0 7M18 15a5 5 0 0 1 3 6',
  groups: 'M4 5h16v5H4zM4 14h16v5H4z',
  coaching: 'M4 5h16v12H9l-5 4z',
  reports: 'M5 20V12M12 20V4M19 20V9',
  support: 'M5 18 3 21l1-6a9 9 0 1 1 4 5z',
  settings: 'M3 6h18M3 12h18M3 18h18M8 4v4M16 10v4M10 16v4',
  household: 'M4 5h16v14H4zM4 10h16',
  more: 'M5 5h5v5H5zM14 5h5v5h-5zM5 14h5v5H5zM14 14h5v5h-5z',
}
function AdminIcon({ section }: { section: string }) { return <svg className="tabs-icon" viewBox="0 0 24 24" aria-hidden="true"><path d={iconPaths[section] ?? iconPaths.more} /></svg> }
