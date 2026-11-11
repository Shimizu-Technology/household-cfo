import { historyPosition, pushHistoryEntry } from '../lib/browserHistory'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { createAdminPersona, fetchAdminPersonas, fetchAdminPersona, fetchAdminPersonaAssignableCohorts, type AdminPersonaDetail, type AdminPersonaAssignableCohort, type CurrentUser } from '../api'
import { useAuthContext } from '../contexts/authContextValue'
import { Button } from './Button'
import { CoachStudioAdvanced, type CoachFormProposal } from './CoachStudioAdvanced'
import { CoachProgramSettings } from './CoachProgramSettings'
import { CohortExperienceStudio } from './CohortExperienceStudio'
import { CoachTeachingWorkspace } from './CoachTeaching'
import { PersonaSetupChat } from './PersonaSetupChat'
import { ProgramCreatedNotice } from './ProgramCreatedNotice'
import { CoachGoLive } from './CoachGoLive'
import { useCoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
import './CoachStudio.css'
import { confirmDiscard } from '../lib/confirmAction'
import { adminPath, navigateTo } from '../lib/appRoutes'

type Area = 'people' | 'assistant' | 'live'
type Task = 'voice' | 'branding' | 'tools' | 'teaching' | 'advanced'

type ProposedState = CoachFormProposal

// `view` places Coach Studio inside the Admin side: Today is the people area,
// Coaching is the assistant and Go live. Without it, the studio shows all three.
type StudioView = 'today' | 'coaching'
const AREAS_FOR_VIEW: Record<StudioView, Area[]> = { today: ['people'], coaching: ['assistant', 'live'] }
const AREA_LABELS: Record<Area, string> = { people: 'People', assistant: 'Your assistant', live: 'Go live' }

export function CoachStudio({ currentUser, onDirtyChange, view }: { currentUser: CurrentUser; onDirtyChange: (dirty: boolean) => void; view?: StudioView }) {
  const { activeCoachWorkspaceId, selectCoachWorkspace } = useAuthContext()
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
  }}>Back to simple setup</Button><CoachStudioAdvanced currentUser={currentUser} onDirtyChange={trackAdvancedDirty} onPendingChange={setAdvancedBusy} initialSection={advanced.section} proposedState={advanced.proposal} /></>
  // The detailed editor already owns workspace transitions. Simple authoring is
  // remounted per program so private local drafts cannot cross programs.
  return <StudioProgram key={activeCoachWorkspaceId ?? 'platform'} view={view} currentUser={currentUser} workspaceId={activeCoachWorkspaceId} selectWorkspace={selectCoachWorkspace} onDirtyChange={onDirtyChange} onAdvanced={(proposal) => { try { window.sessionStorage.setItem(modeKey, 'advanced') } catch { /* Optional UI preference only. */ } setAdvanced({ proposal, section: 'assistants' }) }} />
}

function StudioProgram({ view, currentUser, workspaceId, selectWorkspace, onDirtyChange, onAdvanced }: { view?: StudioView; currentUser: CurrentUser; workspaceId: number | null; selectWorkspace: (id: number | null) => void; onDirtyChange: (dirty: boolean) => void; onAdvanced: (proposal?: ProposedState) => void }) {
  const viewKey = `hcfo.coachStudio.view:${currentUser.id}:${workspaceId}`
  const allowedAreas = useMemo<Area[]>(() => view ? AREAS_FOR_VIEW[view] : ['people', 'assistant', 'live'], [view])
  const fitArea = useCallback((candidate: Area | null): Area => candidate && allowedAreas.includes(candidate) ? candidate : allowedAreas[0], [allowedAreas])
  const [area, updateArea] = useState<Area>(() => fitArea(readUrlView() ?? readView(viewKey).area))
  const [task, updateTask] = useState<Task>(() => readUrlTask() ?? readView(viewKey).task)
  useEffect(() => { try { window.sessionStorage.setItem(viewKey, JSON.stringify({ area, task })) } catch { /* Optional UI preference. */ } }, [viewKey, area, task])
  const [persona, setPersona] = useState<AdminPersonaDetail | null>(null)
  const [cohorts, setCohorts] = useState<AdminPersonaAssignableCohort[]>([])
  const [selectedCohortId, setSelectedCohortId] = useState<number | null>(null)
  const [name, setName] = useState('Mia')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [groupsBusy, setGroupsBusy] = useState(false)
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
  const showProgramPicker = !view && ((currentUser.coach_workspaces?.length ?? 0) > 1 || (currentUser.is_admin && workspaceId === null && (currentUser.coach_workspaces?.length ?? 0) > 0))
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
        setSelectedCohortId(groups[0]?.id ?? null)
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
    if (busy || groupsBusy || lifecycle.pending) return
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
  // From Today, the assistant and Go live belong to the Coaching section.
  function openArea(next: Area, nextTask: Task = task) {
    if (view && !allowedAreas.includes(next)) {
      const target = new URL(adminPath('coaching'), window.location.origin)
      target.searchParams.set('coach_area', next); target.searchParams.set('coach_task', nextTask)
      navigateTo(`${target.pathname}${target.search}`)
      return
    }
    navigate(next, nextTask)
  }
  function setArea(next: Area) { openArea(next) }
  function setTask(next: Task) { navigate(area, next) }
  useEffect(() => {
    writeView(area, task, true)
    const follow = () => {
      const restoredIndex = historyPosition()
      if (restoringHistory.current === restoredIndex) { restoringHistory.current = null; return }
      restoringHistory.current = null
      if (!view && window.location.hash !== '#Coach%20Studio') return
      if (view && !window.location.pathname.startsWith('/admin')) return
      const nextArea = fitArea(readUrlView())
      const nextTask = readUrlTask() ?? 'voice'
      const nextIndex = historyPosition()
      const restore = () => {
        const delta = historyIndex.current - nextIndex
        if (delta) { restoringHistory.current = historyIndex.current; window.history.go(delta) }
      }
      if (nextArea === area && nextTask === task) { historyIndex.current = nextIndex; return }
      if (busy || groupsBusy || lifecycle.pending) { restore(); return }
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
  }, [area, task, busy, groupsBusy, lifecycle.pending, dirty, trackDirty, view, fitArea])

  async function create() {
    if (!name.trim() || busy || groupsBusy || lifecycle.pending || !workspaceId) return
    const ticket = lifecycle.begin()
    setBusy(true); setError(null)
    try {
      const result = await createAdminPersona({ name: name.trim(), description: '' })
      if (mounted.current && lifecycle.isCurrent(ticket)) { setPersona(result); trackDirty(false) }
    } catch { if (mounted.current && lifecycle.isCurrent(ticket)) setError('Your assistant could not be created. Try again.') }
    finally { if (mounted.current) setBusy(false); lifecycle.finish(ticket) }
  }

  return <><ProgramCreatedNotice userId={currentUser.id} workspaceId={workspaceId}/><section className="screen-grid coach-studio-screen coach-simple" aria-busy={loading || busy || groupsBusy}>
    <header className={area === 'people' && cohorts.length > 0 && !showProgramPicker ? 'sr-only' : 'coach-simple-heading'}><div><h2 data-page-heading tabIndex={-1}>{view === 'today' ? 'Today' : view === 'coaching' ? 'Coaching' : workspace?.name ?? 'Coach Studio'}</h2></div>
      {showProgramPicker && <label>Program<select aria-label="Program" value={workspaceId ?? ''} disabled={busy || groupsBusy || lifecycle.pending} onChange={(event) => leave(() => selectWorkspace(Number(event.target.value)))}><option value="" disabled>Choose your program</option>{currentUser.coach_workspaces?.map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label>}
    </header>
    <nav className="coach-studio-section-tabs" aria-label="Coach Studio areas">
      {(['people', 'assistant', 'live'] as const).map(id => [id, AREA_LABELS[id]] as const).map(([id, label]) => <button type="button" key={id} aria-current={area === id ? 'page' : undefined} disabled={busy || groupsBusy || lifecycle.pending} onClick={() => leave(() => setArea(id))}>{label}</button>)}
    </nav>
    {error && <p role="alert">{error} <Button variant="secondary" onClick={() => setAttempt((value) => value + 1)}>Try again</Button></p>}
    {workspaceId === null ? <article className="panel"><h3>Start with a program</h3><p>Each program keeps its coaches, assistant and people together. Choose a program above, or create one to get started.</p><CoachProgramSettings simple workspaceId={null} currentUser={currentUser} mutationLifecycle={lifecycle} onDirtyChange={trackDirty} /></article>
      : loading ? <p role="status">Opening your program…</p>
      : area === 'people' ? <>
        {(!persona || cohorts.length === 0) && <article className="panel coach-setup-checklist"><h3>Get your program ready</h3><ol><li><button disabled={busy || groupsBusy || lifecycle.pending} onClick={() => leave(() => { focusAssistant.current = true; openArea('assistant', 'voice'); if (!persona && !view) void create() })}>Describe your assistant</button><span>{persona?.published_version ? 'Live' : persona ? 'Started' : 'Ready to start'}</span></li><li><button onClick={() => leave(() => setArea('live'))}>Preview answers and go live</button></li><li>Invite people from Group invitations &amp; access below.</li></ol></article>}
        <CoachStudioAdvanced currentUser={currentUser} onDirtyChange={trackDirty} initialSection="groups" embedded onPendingChange={setGroupsBusy} onGroupsChanged={() => { void fetchAdminPersonaAssignableCohorts().then((next) => { if (mounted.current) setCohorts(next) }).catch(() => { if (mounted.current) setError('Your group was saved, but the list could not refresh. Try again.') }) }} />
      </> : area === 'assistant' ? <>
        <h3 className="sr-only" ref={assistantHeading} tabIndex={-1}>Your assistant</h3>
        <details className="coach-assistant-settings"><summary>More settings</summary><nav className="coach-simple-tasks" aria-label="Assistant settings">{([['voice', 'Voice'], ['teaching', 'Teaching'], ['tools', 'Tools'], ['branding', 'Appearance']] as const).map(([id,label]) => <Button key={id} variant="secondary" aria-pressed={task === id} disabled={busy || groupsBusy || lifecycle.pending} onClick={() => leave(() => setTask(id))}>{label}</Button>)}</nav></details>
        {task === 'branding' ? <CoachProgramSettings simple workspaceId={workspaceId} currentUser={currentUser} mutationLifecycle={lifecycle} onDirtyChange={trackDirty} />
        : task === 'tools' ? <CohortExperienceStudio simple cohorts={cohorts} cohortsLoading={loading} selectedCohortId={selectedCohortId} onSelectedCohortIdChange={setSelectedCohortId} mutationLifecycle={lifecycle} onDirtyChange={trackDirty} />
        : task === 'teaching' ? <CoachTeachingWorkspace persona={persona} currentUser={currentUser} lifecycle={lifecycle} onDirtyChange={trackDirty} onPersonaChange={setPersona} onPreview={() => { setPreviewOnOpen(true); setArea('live') }} />
        : !persona ? <article className="panel"><h3>What is your assistant called?</h3><p>You can change its voice and name later.</p><label>Assistant name<input disabled={busy || groupsBusy || lifecycle.pending} value={name} maxLength={80} onChange={(event) => { setName(event.target.value); trackDirty(true) }} /></label><Button disabled={busy || !name.trim()} onClick={() => void create()}>Describe this assistant</Button>{busy && <p role="status">Creating your assistant…</p>}</article>
        : !persona.permissions.edit ? <p>Your assistant is available for review. Ask a program owner or editor to change its voice.</p>
        : <><PersonaSetupChat persona={persona} disabled={busy} manualDirty={false} mutationLifecycle={lifecycle} onDirtyChange={trackDirty} saveAndPreview onPersonaChange={(next) => { setPersona(next); setPreviewOnOpen(true); setArea('live') }} onReviewInForm={(state, _path, draftRevision) => leave(() => onAdvanced({ ...state, personaId: persona.id, workspaceId, draftRevision }))} /><Button variant="secondary" disabled={dirty || lifecycle.pending} onClick={() => setArea('live')}>Preview answers</Button></>}
      </> : !persona ? <article className="panel"><h3>Save your assistant’s voice first</h3><p>Your saved tools will go live with your assistant.</p><Button onClick={() => setArea('assistant')}>Set up your assistant</Button></article> : null}
    {persona && <div hidden={area !== 'live'}><CoachGoLive key={`${persona.id}:${persona.draft_revision}`} persona={persona} cohorts={cohorts} lifecycle={lifecycle} onPersonaChange={setPersona} onEditVoice={() => navigate('assistant', 'voice')} autoPreview={previewOnOpen} canOpenChallenge={currentUser.is_admin || workspace?.membership_role === 'owner'} active={area === 'live'} /></div>}
    <details className="coach-simple-advanced"><summary>Advanced / history</summary><p>All structured fields, approved sources, earlier versions, team access and controlled group updates.</p><Button variant="secondary" disabled={busy || groupsBusy || lifecycle.pending} onClick={() => leave(() => onAdvanced())}>Open advanced settings</Button></details>
  </section></>
}

function readView(key: string): { area: Area; task: Task } {
  try {
    const value = JSON.parse(window.sessionStorage.getItem(key) ?? '{}')
    return { area: ['people', 'assistant', 'live'].includes(value.area) ? value.area : 'people', task: ['voice', 'teaching', 'tools', 'branding'].includes(value.task) ? value.task : 'voice' }
  } catch { return { area: 'people', task: 'voice' } }
}

function readUrlView(): Area | null {
  const value = new URL(window.location.href).searchParams.get('coach_area')
  return value === 'people' || value === 'assistant' || value === 'live' ? value : null
}
function readUrlTask(): Task | null {
  const value = new URL(window.location.href).searchParams.get('coach_task')
  return value === 'voice' || value === 'branding' || value === 'tools' || value === 'teaching' ? value : null
}
function writeView(area: Area, task: Task, replace = false) {
  const url = new URL(window.location.href)
  const unchanged = url.searchParams.get('coach_area') === area && url.searchParams.get('coach_task') === task
  url.searchParams.set('coach_area', area); url.searchParams.set('coach_task', task)
  if (replace) window.history.replaceState({...window.history.state, appHistoryPosition: historyPosition()}, '', url)
  else if (!unchanged) pushHistoryEntry({...window.history.state}, url)
}
