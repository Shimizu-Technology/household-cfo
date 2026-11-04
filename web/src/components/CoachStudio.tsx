import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createAdminPersona, fetchAdminPersonas, fetchAdminPersona, fetchAdminPersonaAssignableCohorts, type AdminPersonaDetail, type AdminPersonaAssignableCohort, type CurrentUser } from '../api'
import { useAuthContext } from '../contexts/authContextValue'
import { Button } from './Button'
import { CoachStudioAdvanced, type CoachFormProposal } from './CoachStudioAdvanced'
import { CoachProgramSettings } from './CoachProgramSettings'
import { CohortExperienceStudio } from './CohortExperienceStudio'
import { CoachTeachingWorkspace } from './CoachTeaching'
import { PersonaSetupChat } from './PersonaSetupChat'
import { CoachGoLive } from './CoachGoLive'
import { useCoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
import './CoachStudio.css'
import { confirmDiscard } from '../lib/confirmAction'

type Area = 'people' | 'assistant' | 'live'
type Task = 'voice' | 'branding' | 'tools' | 'teaching' | 'advanced'

type ProposedState = CoachFormProposal

export function CoachStudio({ currentUser, onDirtyChange }: { currentUser: CurrentUser; onDirtyChange: (dirty: boolean) => void }) {
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
  return <StudioProgram key={activeCoachWorkspaceId ?? 'platform'} currentUser={currentUser} workspaceId={activeCoachWorkspaceId} selectWorkspace={selectCoachWorkspace} onDirtyChange={onDirtyChange} onAdvanced={(proposal) => { try { window.sessionStorage.setItem(modeKey, 'advanced') } catch { /* Optional UI preference only. */ } setAdvanced({ proposal, section: 'assistants' }) }} />
}

function StudioProgram({ currentUser, workspaceId, selectWorkspace, onDirtyChange, onAdvanced }: { currentUser: CurrentUser; workspaceId: number | null; selectWorkspace: (id: number | null) => void; onDirtyChange: (dirty: boolean) => void; onAdvanced: (proposal?: ProposedState) => void }) {
  const viewKey = `hcfo.coachStudio.view:${currentUser.id}:${workspaceId}`
  const [area, setArea] = useState<Area>(() => readView(viewKey).area)
  const [task, setTask] = useState<Task>(() => readView(viewKey).task)
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
  const showProgramPicker = (currentUser.coach_workspaces?.length ?? 0) > 1 || (currentUser.is_admin && workspaceId === null && (currentUser.coach_workspaces?.length ?? 0) > 0)
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

  return <section className="screen-grid coach-studio-screen coach-simple" aria-busy={loading || busy || groupsBusy}>
    <header className={area === 'people' && cohorts.length > 0 && !showProgramPicker ? 'sr-only' : 'coach-simple-heading'}><div><h2 data-page-heading tabIndex={-1}>{workspace?.name ?? 'Coach Studio'}</h2></div>
      {showProgramPicker && <label>Program<select aria-label="Program" value={workspaceId ?? ''} disabled={busy || groupsBusy || lifecycle.pending} onChange={(event) => leave(() => selectWorkspace(Number(event.target.value)))}><option value="" disabled>Choose your program</option>{currentUser.coach_workspaces?.map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label>}
    </header>
    <nav className="coach-studio-section-tabs" aria-label="Coach Studio areas">
      {([['people', 'People'], ['assistant', 'Your assistant'], ['live', 'Go live']] as const).map(([id, label]) => <button type="button" key={id} aria-current={area === id ? 'page' : undefined} disabled={busy || groupsBusy || lifecycle.pending} onClick={() => leave(() => setArea(id))}>{label}</button>)}
    </nav>
    {error && <p role="alert">{error} <Button variant="secondary" onClick={() => setAttempt((value) => value + 1)}>Try again</Button></p>}
    {workspaceId === null ? <article className="panel"><h3>Start with a program</h3><p>Each program keeps its coaches, assistant and people together. Choose a program above, or create one to get started.</p><CoachProgramSettings simple workspaceId={null} currentUser={currentUser} mutationLifecycle={lifecycle} onDirtyChange={trackDirty} /></article>
      : loading ? <p role="status">Opening your program…</p>
      : area === 'people' ? <>
        {(!persona || cohorts.length === 0) && <article className="panel coach-setup-checklist"><h3>Get your program ready</h3><ol><li><button disabled={busy || groupsBusy || lifecycle.pending} onClick={() => leave(() => { focusAssistant.current = true; setArea('assistant'); setTask('voice'); if (!persona) void create() })}>Describe your assistant</button><span>{persona?.published_version ? 'Live' : persona ? 'Started' : 'Ready to start'}</span></li><li><button onClick={() => leave(() => setArea('live'))}>Preview answers and go live</button></li><li>Invite people from Group invitations &amp; access below.</li></ol></article>}
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
      </> : persona ? <CoachGoLive key={`${persona.id}:${persona.draft_revision}`} persona={persona} cohorts={cohorts} lifecycle={lifecycle} onPersonaChange={setPersona} onEditVoice={() => { setArea('assistant'); setTask('voice') }} autoPreview={previewOnOpen} /> : <article className="panel"><h3>Save your assistant’s voice first</h3><p>Your saved tools will go live with your assistant.</p><Button onClick={() => setArea('assistant')}>Set up your assistant</Button></article>}
    <details className="coach-simple-advanced"><summary>Advanced / history</summary><p>All structured fields, approved sources, earlier versions, team access and controlled group updates.</p><Button variant="secondary" disabled={busy || groupsBusy || lifecycle.pending} onClick={() => leave(() => onAdvanced())}>Open advanced settings</Button></details>
  </section>
}

function readView(key: string): { area: Area; task: Task } {
  try {
    const value = JSON.parse(window.sessionStorage.getItem(key) ?? '{}')
    return { area: ['people', 'assistant', 'live'].includes(value.area) ? value.area : 'people', task: ['voice', 'teaching', 'tools', 'branding'].includes(value.task) ? value.task : 'voice' }
  } catch { return { area: 'people', task: 'voice' } }
}
