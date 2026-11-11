import { historyPosition, pushHistoryEntry } from '../lib/browserHistory'
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createAdminPersona, fetchAdminPersonas, fetchAdminPersona, fetchAdminPersonaAssignableCohorts, type AdminPersonaDetail, type AdminPersonaAssignableCohort, type CurrentUser } from '../api'
import { useAuthContext } from '../contexts/authContextValue'
import { Button } from './Button'
import { CoachStudioAdvanced, type CoachFormProposal } from './CoachStudioAdvanced'
import { CoachTeachingWorkspace } from './CoachTeaching'
import { PersonaSetupChat } from './PersonaSetupChat'
import { ProgramCreatedNotice } from './ProgramCreatedNotice'
import { CoachGoLive } from './CoachGoLive'
import { useCoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
import './CoachStudio.css'
import { confirmDiscard } from '../lib/confirmAction'
import { adminPath, navigateTo } from '../lib/appRoutes'

// Coaching is two steps: describe your coach, then preview and go live. History sits at the end.
type Area = 'assistant' | 'live'
type Task = 'voice' | 'teaching'

type ProposedState = CoachFormProposal

const AREA_LABELS: Record<Area, string> = { assistant: '1 · Your coach’s voice', live: '2 · Preview and go live' }

export function CoachStudio({ currentUser, onDirtyChange }: { currentUser: CurrentUser; onDirtyChange: (dirty: boolean) => void }) {
  const { activeCoachWorkspaceId } = useAuthContext()
  const modeKey = `hcfo.coachStudio.mode:${currentUser.id}`
  const [advanced, setAdvanced] = useState<{ proposal?: ProposedState; section?: 'assistants' } | null>(() => {
    try { return window.sessionStorage.getItem(modeKey) === 'advanced' ? {} : null } catch { return null }
  })
  const [advancedDirty, setAdvancedDirty] = useState(false)
  const [advancedBusy, setAdvancedBusy] = useState(false)
  const trackAdvancedDirty = useCallback((value: boolean) => { setAdvancedDirty(value); onDirtyChange(value) }, [onDirtyChange])
  if (advanced) return <><Button variant="secondary" disabled={advancedBusy} onClick={async () => {
    if (advancedDirty && !(await confirmDiscard('Your changes will be lost.'))) return
    try { window.sessionStorage.removeItem(modeKey) } catch { /* A mode preference never blocks authoring. */ }
    onDirtyChange(false); setAdvanced(null)
  }}>Back to Coaching</Button><CoachStudioAdvanced currentUser={currentUser} onDirtyChange={trackAdvancedDirty} onPendingChange={setAdvancedBusy} initialSection={advanced.section} proposedState={advanced.proposal} /></>
  // The detailed editor already owns workspace transitions. Simple authoring is
  // remounted per program so private local drafts cannot cross programs.
  return <StudioProgram key={activeCoachWorkspaceId ?? 'platform'} currentUser={currentUser} workspaceId={activeCoachWorkspaceId} onDirtyChange={onDirtyChange} onAdvanced={(proposal) => { try { window.sessionStorage.setItem(modeKey, 'advanced') } catch { /* Optional UI preference only. */ } setAdvanced({ proposal, section: 'assistants' }) }} />
}

function StudioProgram({ currentUser, workspaceId, onDirtyChange, onAdvanced }: { currentUser: CurrentUser; workspaceId: number | null; onDirtyChange: (dirty: boolean) => void; onAdvanced: (proposal?: ProposedState) => void }) {
  const viewKey = `hcfo.coachStudio.view:${currentUser.id}:${workspaceId}`
  const [area, updateArea] = useState<Area>(() => readUrlView() ?? readView(viewKey).area)
  const [task, updateTask] = useState<Task>(() => readUrlTask() ?? readView(viewKey).task)
  useEffect(() => { try { window.sessionStorage.setItem(viewKey, JSON.stringify({ area, task })) } catch { /* Optional UI preference. */ } }, [viewKey, area, task])
  const [persona, setPersona] = useState<AdminPersonaDetail | null>(null)
  const [cohorts, setCohorts] = useState<AdminPersonaAssignableCohort[]>([])
  const [name, setName] = useState('Mia')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const assistantHeading = useRef<HTMLHeadingElement>(null)
  const focusAssistant = useRef(false)
  useLayoutEffect(() => {
    if (area === 'assistant' && focusAssistant.current) {
      assistantHeading.current?.focus()
      focusAssistant.current = false
    }
  }, [area])
  const [previewOnOpen, setPreviewOnOpen] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)
  const lifecycle = useCoachWorkspaceMutationLifecycle(workspaceId)
  const mounted = useRef(true)
  const workspace = currentUser.coach_workspaces?.find((item) => item.id === workspaceId)
  const trackDirty = useCallback((value: boolean) => { setDirty(value); onDirtyChange(value) }, [onDirtyChange])
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])
  useLayoutEffect(() => () => onDirtyChange(false), [onDirtyChange])
  useEffect(() => {
    let cancelled = false
    async function load() {
      setLoading(true)
      setError(null)
      try {
        const [groups, assistants] = await Promise.all([fetchAdminPersonaAssignableCohorts(), fetchAdminPersonas()])
        if (cancelled) return
        setCohorts(groups)
        const assistant = assistants.find((item) => item.status !== 'archived')
        if (assistant) {
          const detail = await fetchAdminPersona(assistant.id)
          if (!cancelled) setPersona(detail)
        }
      } catch {
        if (!cancelled) setError('Your program could not load. Try again.')
      } finally { if (!cancelled) setLoading(false) }
    }
    if (workspaceId !== null) void load()
    else queueMicrotask(() => setLoading(false))
    return () => { cancelled = true }
  }, [workspaceId, attempt])

  async function leave(action: () => void) {
    if (busy || lifecycle.pending) return
    if (dirty && !(await confirmDiscard('Your changes will be lost.'))) return
    trackDirty(false)
    setName('Mia')
    action()
  }
  const historyIndex = useRef<number>(historyPosition())
  const restoringHistory = useRef<number | null>(null)
  function navigate(nextArea: Area, nextTask: Task = task) {
    writeView(nextArea, nextTask)
    historyIndex.current = historyPosition()
    if (nextArea !== 'live') setPreviewOnOpen(false)
    updateArea(nextArea); updateTask(nextTask)
  }
  function setArea(next: Area) { navigate(next) }
  function setTask(next: Task) { navigate(area, next) }
  useEffect(() => {
    writeView(area, task, true)
    const follow = () => {
      const restoredIndex = historyPosition()
      if (restoringHistory.current === restoredIndex) { restoringHistory.current = null; return }
      restoringHistory.current = null
      if (!window.location.pathname.startsWith('/admin')) return
      const nextArea = readUrlView() ?? 'assistant'
      const nextTask = readUrlTask() ?? 'voice'
      const nextIndex = historyPosition()
      const restore = () => {
        const delta = historyIndex.current - nextIndex
        if (delta) { restoringHistory.current = historyIndex.current; window.history.go(delta) }
      }
      if (nextArea === area && nextTask === task) { historyIndex.current = nextIndex; return }
      if (busy || lifecycle.pending) { restore(); return }
      const accept = () => {
        historyIndex.current = nextIndex
        trackDirty(false); setName('Mia'); setPreviewOnOpen(false)
        updateArea(nextArea); updateTask(nextTask)
      }
      if (dirty) {
        void confirmDiscard('Your changes will be lost.').then(discard => {
          if (!mounted.current) return
          if (discard) accept()
          else restore()
        })
      } else accept()
    }
    window.addEventListener('popstate', follow)
    return () => window.removeEventListener('popstate', follow)
  }, [area, task, busy, lifecycle.pending, dirty, trackDirty])

  async function create() {
    if (!name.trim() || busy || lifecycle.pending || !workspaceId) return
    const ticket = lifecycle.begin()
    setBusy(true); setError(null)
    try {
      const result = await createAdminPersona({ name: name.trim(), description: '' })
      if (mounted.current && lifecycle.isCurrent(ticket)) { setPersona(result); trackDirty(false) }
    } catch { if (mounted.current && lifecycle.isCurrent(ticket)) setError('Your assistant could not be created. Try again.') }
    finally { if (mounted.current) setBusy(false); lifecycle.finish(ticket) }
  }

  return <><ProgramCreatedNotice userId={currentUser.id} workspaceId={workspaceId}/><section className="screen-grid coach-studio-screen coach-simple" aria-busy={loading || busy}>
    <header className="coach-simple-heading"><div><h2 data-page-heading tabIndex={-1}>Coaching</h2><p>{workspace ? `The voice and teaching your people hear in ${workspace.name}.` : 'The voice and teaching your people hear.'}</p></div></header>
    <nav className="coach-studio-section-tabs" aria-label="Coaching steps">
      {(['assistant', 'live'] as const).map(id => <button type="button" key={id} aria-current={area === id ? 'page' : undefined} disabled={busy || lifecycle.pending} onClick={() => leave(() => setArea(id))}>{AREA_LABELS[id]}</button>)}
    </nav>
    {error && <p role="alert">{error} <Button variant="secondary" onClick={() => setAttempt((value) => value + 1)}>Try again</Button></p>}
    {workspaceId === null ? <article className="panel"><h3>Choose a program</h3><p>Your coach’s voice belongs to a program. Choose one at the top of the page, or start one in Settings.</p><Button variant="secondary" onClick={() => navigateTo(adminPath('settings'))}>Open Settings</Button></article>
      : loading ? <p role="status">Opening your coaching…</p>
      : area === 'assistant' ? <>
        <h3 className="sr-only" ref={assistantHeading} tabIndex={-1}>Your coach’s voice</h3>
        {persona && <nav className="admin-chips coach-simple-tasks" aria-label="Voice or teaching">{([['voice', 'Voice'], ['teaching', 'Teaching']] as const).map(([id, label]) => <button type="button" key={id} aria-pressed={task === id} disabled={busy || lifecycle.pending} onClick={() => leave(() => setTask(id))}>{label}</button>)}</nav>}
        {task === 'teaching' ? <CoachTeachingWorkspace persona={persona} currentUser={currentUser} lifecycle={lifecycle} onDirtyChange={trackDirty} onPersonaChange={setPersona} onPreview={() => { setPreviewOnOpen(true); setArea('live') }} />
        : !persona ? <article className="panel"><h3>What is your assistant called?</h3><p>You can change its voice and name later.</p><label>Assistant name<input disabled={busy || lifecycle.pending} value={name} maxLength={80} onChange={(event) => { setName(event.target.value); trackDirty(true) }} /></label><Button disabled={busy || !name.trim()} onClick={() => void create()}>Describe this assistant</Button>{busy && <p role="status">Creating your assistant…</p>}</article>
        : !persona.permissions.edit ? <p>Your assistant is available for review. Ask a program owner or editor to change its voice.</p>
        : <><PersonaSetupChat persona={persona} disabled={busy} manualDirty={false} mutationLifecycle={lifecycle} onDirtyChange={trackDirty} saveAndPreview onPersonaChange={(next) => { setPersona(next); setPreviewOnOpen(true); setArea('live') }} onReviewInForm={(state, _path, draftRevision) => leave(() => onAdvanced({ ...state, personaId: persona.id, workspaceId, draftRevision }))} /><Button variant="secondary" disabled={dirty || lifecycle.pending} onClick={() => setArea('live')}>Preview answers</Button></>}
      </> : !persona ? <article className="panel"><h3>Describe your coach first</h3><p>Your saved tools and look go live together with your coach’s voice.</p><Button onClick={() => setArea('assistant')}>Describe your coach</Button></article> : null}
    {persona && <div hidden={area !== 'live'}><CoachGoLive key={`${persona.id}:${persona.draft_revision}`} persona={persona} cohorts={cohorts} lifecycle={lifecycle} onPersonaChange={setPersona} onEditVoice={() => navigate('assistant', 'voice')} autoPreview={previewOnOpen} canOpenChallenge={currentUser.is_admin || workspace?.membership_role === 'owner'} active={area === 'live'} /></div>}
    <div className="coach-history-link"><h3>History</h3><p>Earlier versions of your coach’s voice, the teaching library and group updates.</p><Button variant="secondary" disabled={busy || lifecycle.pending} onClick={() => leave(() => onAdvanced())}>Open history</Button></div>
  </section></>
}

function readView(key: string): { area: Area; task: Task } {
  try {
    const value = JSON.parse(window.sessionStorage.getItem(key) ?? '{}')
    return { area: ['assistant', 'live'].includes(value.area) ? value.area : 'assistant', task: value.task === 'teaching' ? 'teaching' : 'voice' }
  } catch { return { area: 'assistant', task: 'voice' } }
}

function readUrlView(): Area | null {
  const value = new URL(window.location.href).searchParams.get('coach_area')
  return value === 'assistant' || value === 'live' ? value : null
}
function readUrlTask(): Task | null {
  const value = new URL(window.location.href).searchParams.get('coach_task')
  return value === 'voice' || value === 'teaching' ? value : null
}
function writeView(area: Area, task: Task, replace = false) {
  const url = new URL(window.location.href)
  const unchanged = url.searchParams.get('coach_area') === area && url.searchParams.get('coach_task') === task
  url.searchParams.set('coach_area', area); url.searchParams.set('coach_task', task)
  if (replace) window.history.replaceState({...window.history.state, appHistoryPosition: historyPosition()}, '', url)
  else if (!unchanged) pushHistoryEntry({...window.history.state}, url)
}
