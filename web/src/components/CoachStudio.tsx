import { useCallback, useEffect, useRef, useState } from 'react'
import { createAdminPersona, fetchAdminPersonas, fetchAdminPersona, fetchAdminPersonaAssignableCohorts, type AdminPersonaDetail, type AdminPersonaAssignableCohort, type CurrentUser, type PersonaConfiguration } from '../api'
import { useAuthContext } from '../contexts/authContextValue'
import { Button } from './Button'
import { CoachStudioAdvanced } from './CoachStudioAdvanced'
import { CoachProgramSettings } from './CoachProgramSettings'
import { CohortExperienceStudio } from './CohortExperienceStudio'
import { CoachContentLibrary } from './CoachContentLibrary'
import { PersonaSetupChat } from './PersonaSetupChat'
import { CoachGoLive } from './CoachGoLive'
import { useCoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
import './CoachStudio.css'

type Area = 'people' | 'assistant' | 'live'
type Task = 'voice' | 'branding' | 'tools' | 'teaching' | 'advanced'

export function CoachStudio({ currentUser, onDirtyChange }: { currentUser: CurrentUser; onDirtyChange: (dirty: boolean) => void }) {
  const { activeCoachWorkspaceId, selectCoachWorkspace } = useAuthContext()
  // Remount on program changes so private drafts and in-flight results cannot cross programs.
  return <StudioProgram key={activeCoachWorkspaceId ?? 'platform'} currentUser={currentUser} workspaceId={activeCoachWorkspaceId} selectWorkspace={selectCoachWorkspace} onDirtyChange={onDirtyChange} />
}

function StudioProgram({ currentUser, workspaceId, selectWorkspace, onDirtyChange }: { currentUser: CurrentUser; workspaceId: number | null; selectWorkspace: (id: number | null) => void; onDirtyChange: (dirty: boolean) => void }) {
  const [area, setArea] = useState<Area>('people')
  const [task, setTask] = useState<Task>('voice')
  const [persona, setPersona] = useState<AdminPersonaDetail | null>(null)
  const [cohorts, setCohorts] = useState<AdminPersonaAssignableCohort[]>([])
  const [selectedCohortId, setSelectedCohortId] = useState<number | null>(null)
  const [name, setName] = useState('Mia')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [advanced, setAdvanced] = useState(false)
  const [proposedState, setProposedState] = useState<{description: string; draft_config: PersonaConfiguration} | undefined>()
  const [attempt, setAttempt] = useState(0)
  const lifecycle = useCoachWorkspaceMutationLifecycle(workspaceId)
  const mounted = useRef(true)
  const workspace = currentUser.coach_workspaces?.find((item) => item.id === workspaceId)
  const trackDirty = useCallback((value: boolean) => { setDirty(value); onDirtyChange(value) }, [onDirtyChange])
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])
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

  function leave(action: () => void) {
    if (busy || lifecycle.pending) return
    if (dirty && !window.confirm('Leave without saving these changes?')) return
    trackDirty(false)
    action()
  }
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
  if (advanced) return <><Button variant="secondary" disabled={lifecycle.pending} onClick={() => leave(() => { setAdvanced(false); setProposedState(undefined); setAttempt((value) => value + 1) })}>Back to simple setup</Button><CoachStudioAdvanced currentUser={currentUser} onDirtyChange={trackDirty} initialSection="assistants" proposedState={proposedState} /></>
  return <section className="screen-grid coach-studio-screen coach-simple" aria-busy={loading || busy}>
    <header className="coach-simple-heading"><div><h2 data-page-heading tabIndex={-1}>{workspace?.name ?? 'Coach Studio'}</h2><p>Coach your people. Make your assistant sound like you.</p></div>
      {(currentUser.coach_workspaces?.length ?? 0) > 1 && <label>Program<select value={workspaceId ?? ''} disabled={busy || lifecycle.pending} onChange={(event) => leave(() => selectWorkspace(Number(event.target.value)))}><option value="" disabled>Choose your program</option>{currentUser.coach_workspaces?.map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label>}
    </header>
    <nav className="coach-studio-section-tabs" aria-label="Coach Studio areas">
      {([['people', 'People'], ['assistant', 'Your assistant'], ['live', 'Go live']] as const).map(([id, label]) => <button type="button" key={id} aria-current={area === id ? 'page' : undefined} disabled={busy || lifecycle.pending} onClick={() => leave(() => setArea(id))}>{label}</button>)}
    </nav>
    {error && <p role="alert">{error} <Button variant="secondary" onClick={() => setAttempt((value) => value + 1)}>Try again</Button></p>}
    {workspaceId === null ? <article className="panel"><h3>Start with a program</h3><p>Each program keeps its coaches, assistant and people together. Choose a program above, or create one to get started.</p><CoachProgramSettings workspaceId={null} currentUser={currentUser} mutationLifecycle={lifecycle} onDirtyChange={trackDirty} /></article>
      : loading ? <p role="status">Opening your program…</p>
      : area === 'people' ? <>
        {(!persona?.published_version || cohorts.length === 0) && <article className="panel coach-setup-checklist"><h3>Get your program ready</h3><ol><li><button onClick={() => leave(() => { setArea('assistant'); setTask('voice') })}>Describe your assistant</button><span>{persona?.published_version ? 'Live' : persona ? 'Started' : 'Ready to start'}</span></li><li><button onClick={() => leave(() => setArea('live'))}>Preview answers and go live</button></li><li>Invite people from Group invitations &amp; access below.</li></ol></article>}
        <CoachStudioAdvanced currentUser={currentUser} onDirtyChange={trackDirty} initialSection="groups" embedded onGroupsChanged={() => setAttempt((value) => value + 1)} />
      </> : area === 'assistant' ? <>
        <nav className="coach-simple-tasks" aria-label="Assistant settings">{([['voice', 'Voice'], ['teaching', 'Teaching'], ['tools', 'Tools'], ['branding', 'Appearance']] as const).map(([id,label]) => <Button key={id} variant="secondary" aria-pressed={task === id} disabled={busy || lifecycle.pending} onClick={() => leave(() => setTask(id))}>{label}</Button>)}</nav>
        {task === 'branding' ? <CoachProgramSettings workspaceId={workspaceId} currentUser={currentUser} mutationLifecycle={lifecycle} onDirtyChange={trackDirty} />
        : task === 'tools' ? <CohortExperienceStudio cohorts={cohorts} cohortsLoading={loading} selectedCohortId={selectedCohortId} onSelectedCohortIdChange={setSelectedCohortId} mutationLifecycle={lifecycle} onDirtyChange={trackDirty} />
        : task === 'teaching' ? <CoachContentLibrary currentUser={currentUser} selectedPersona={persona} mutationLifecycle={lifecycle} onDirtyChange={trackDirty} onPersonaChange={setPersona} />
        : !persona ? <article className="panel"><h3>What is your assistant called?</h3><p>You can change its voice and name later.</p><label>Assistant name<input value={name} maxLength={80} onChange={(event) => { setName(event.target.value); trackDirty(true) }} /></label><Button disabled={busy || !name.trim()} onClick={() => void create()}>Describe this assistant</Button></article>
        : !persona.permissions.edit ? <p>Your assistant is available for review. Ask a program owner or editor to change its voice.</p>
        : <><PersonaSetupChat persona={persona} disabled={busy} manualDirty={false} mutationLifecycle={lifecycle} onDirtyChange={trackDirty} onPersonaChange={setPersona} onReviewInForm={(state) => { setProposedState(state); leave(() => setAdvanced(true)) }} /><Button disabled={dirty || lifecycle.pending} onClick={() => setArea('live')}>Preview answers</Button></>}
      </> : persona ? <CoachGoLive key={`${persona.id}:${persona.draft_revision}`} persona={persona} cohorts={cohorts} lifecycle={lifecycle} onPersonaChange={setPersona} /> : <article className="panel"><h3>Describe your assistant first</h3><Button onClick={() => setArea('assistant')}>Set up your assistant</Button></article>}
    <details className="coach-simple-advanced"><summary>Advanced / history</summary><p>All structured fields, approved sources, earlier versions, team access and controlled group updates.</p><Button variant="secondary" disabled={busy || lifecycle.pending} onClick={() => leave(() => setAdvanced(true))}>Open advanced settings</Button></details>
  </section>
}
