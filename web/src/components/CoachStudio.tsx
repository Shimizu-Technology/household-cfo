import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent, type KeyboardEvent, type ReactNode } from 'react'
import {
  ApiRequestError,
  archiveAdminPersona,
  createAdminPersona,
  deleteAdminCohortPersonaAssignment,
  fetchAdminPersona,
  fetchAdminPersonaAssignableCohorts,
  fetchAdminPersonas,
  previewAdminPersona,
  publishAdminPersona,
  restoreAdminPersona,
  rollbackAdminPersonaVersion,
  updateAdminCohortPersonaAssignment,
  updateAdminPersona,
} from '../api'
import type {
  AdminPersonaAssignableCohort,
  AdminPersonaDetail,
  AdminPersonaPreview,
  AdminPersonaSummary,
  CurrentUser,
  PersonaConfiguration,
} from '../api'
import { useAuthContext } from '../contexts/authContextValue'
import {
  PERSONA_ACCOUNTABILITY_STYLES,
  PERSONA_ENERGY_STYLES,
  PERSONA_LANGUAGE_STYLES,
  PERSONA_LIST_LIMITS,
  PERSONA_PHRASE_CONTEXTS,
  PERSONA_TONE_TRAITS,
  appendListItem,
  arrayToLineList,
  isPersonaDraftDirty,
  lineListToArray,
  moveListItem,
  replaceListItem as replaceAt,
} from '../lib/personaDraft'
import { Button } from './Button'
import { CohortExperienceStudio } from './CohortExperienceStudio'
import { CoachContentLibrary, PersonaContentPacksPanel } from './CoachContentLibrary'
import './CoachStudio.css'

const guidedSteps = [
  { id: 'identity', label: 'Identity' },
  { id: 'voice', label: 'Voice' },
  { id: 'coaching', label: 'Coaching' },
  { id: 'culture', label: 'Community' },
  { id: 'teaching', label: 'Teaching & response' },
] as const

type GuidedStep = (typeof guidedSteps)[number]['id']
type EditorMode = 'guided' | 'advanced'
type PersonaFilter = 'active' | 'draft' | 'published' | 'archived' | 'all'
type PendingAction = 'create' | 'save' | 'preview' | 'publish' | 'archive' | 'restore' | 'rollback' | 'assignment' | null
type StudioSection = 'assistants' | 'library' | 'participant_tools'
type MutationContext = { sequence: number; workspaceId: number | null }

export function CoachStudio({ currentUser, onDirtyChange }: { currentUser: CurrentUser; onDirtyChange: (dirty: boolean) => void }) {
  const { activeCoachWorkspaceId: activeWorkspaceId, selectCoachWorkspace } = useAuthContext()
  const workspaceOptions = currentUser.coach_workspaces ?? []
  const workspaceCreateDisabled = currentUser.is_admin && activeWorkspaceId === null
  const [personas, setPersonas] = useState<AdminPersonaSummary[]>([])
  const [selectedPersona, setSelectedPersona] = useState<AdminPersonaDetail | null>(null)
  const [draft, setDraft] = useState<PersonaConfiguration | null>(null)
  const [description, setDescription] = useState('')
  const [cohorts, setCohorts] = useState<AdminPersonaAssignableCohort[]>([])
  const [preview, setPreview] = useState<AdminPersonaPreview | null>(null)
  const [samplePrompt, setSamplePrompt] = useState('How should I think about spending $100 this weekend? Give me one clear next step.')
  const [mode, setMode] = useState<EditorMode>('guided')
  const [guidedStep, setGuidedStep] = useState<GuidedStep>('identity')
  const [filter, setFilter] = useState<PersonaFilter>('active')
  const [search, setSearch] = useState('')
  const [loading, setLoading] = useState(true)
  const [detailLoading, setDetailLoading] = useState(false)
  const [pendingAction, setPendingAction] = useState<PendingAction>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [conflict, setConflict] = useState<string | null>(null)
  const [createOpen, setCreateOpen] = useState(false)
  const [createName, setCreateName] = useState('')
  const [createDescription, setCreateDescription] = useState('')
  const [pendingSelectionId, setPendingSelectionId] = useState<number | null>(null)
  const [pendingLibraryReturn, setPendingLibraryReturn] = useState(false)
  const [experienceDirty, setExperienceDirty] = useState(false)
  const [studioSection, setStudioSection] = useState<StudioSection>('assistants')
  const [libraryDirty, setLibraryDirty] = useState(false)
  const [personaSourcesDirty, setPersonaSourcesDirty] = useState(false)
  const selectedIdRef = useRef<number | null>(null)
  const activeWorkspaceIdRef = useRef(activeWorkspaceId)
  activeWorkspaceIdRef.current = activeWorkspaceId
  const loadPersonaRequestRef = useRef(0)
  const loadPersonasRequestRef = useRef(0)
  const mutationSequenceRef = useRef(0)
  const focusEditorAfterLoadRef = useRef(false)
  const createNameRef = useRef<HTMLInputElement | null>(null)
  const libraryHeadingRef = useRef<HTMLHeadingElement | null>(null)
  const editorHeadingRef = useRef<HTMLHeadingElement | null>(null)
  const errorAlertRef = useRef<HTMLDivElement | null>(null)
  const conflictAlertRef = useRef<HTMLDivElement | null>(null)

  const dirty = useMemo(() => {
    if (!selectedPersona?.draft || !draft) return false
    return description !== selectedPersona.description || isPersonaDraftDirty(draft, selectedPersona.draft)
  }, [description, draft, selectedPersona])
  const studioDirty = dirty || experienceDirty || libraryDirty || personaSourcesDirty

  const filteredPersonas = useMemo(() => {
    const query = search.trim().toLowerCase()
    return personas.filter((persona) => {
      const statusMatches = filter === 'all'
        || (filter === 'active' ? persona.status !== 'archived' : persona.status === filter)
      const searchMatches = !query || `${persona.name} ${persona.description} ${persona.owner?.full_name ?? ''}`.toLowerCase().includes(query)
      return statusMatches && searchMatches
    })
  }, [filter, personas, search])

  const loadPersona = useCallback(async (personaId: number) => {
    const requestId = loadPersonaRequestRef.current + 1
    const requestedWorkspaceId = activeWorkspaceIdRef.current
    loadPersonaRequestRef.current = requestId
    setDetailLoading(true)
    setError(null)
    try {
      const persona = await fetchAdminPersona(personaId)
      if (requestId !== loadPersonaRequestRef.current || requestedWorkspaceId !== activeWorkspaceIdRef.current) return
      selectedIdRef.current = persona.id
      setSelectedPersona(persona)
      setDraft(persona.draft ?? null)
      setDescription(persona.description)
      setPreview(null)
      setConflict(null)
      setPendingSelectionId(null)
      setPendingLibraryReturn(false)
      setPersonaSourcesDirty(false)
      setPersonas((current) => replacePersonaSummary(current, persona))
      if (focusEditorAfterLoadRef.current) {
        focusEditorAfterLoadRef.current = false
        window.requestAnimationFrame(() => {
          editorHeadingRef.current?.scrollIntoView({ block: 'start' })
          editorHeadingRef.current?.focus({ preventScroll: true })
        })
      }
    } catch (caught) {
      if (requestId !== loadPersonaRequestRef.current || requestedWorkspaceId !== activeWorkspaceIdRef.current) return
      setError(errorMessage(caught, 'This assistant could not be loaded.'))
    } finally {
      if (requestId === loadPersonaRequestRef.current && requestedWorkspaceId === activeWorkspaceIdRef.current) setDetailLoading(false)
    }
  }, [])

  const loadPersonas = useCallback(async (preferredId?: number | null) => {
    // Workspace selection changes the request header and invalidates every result in this view.
    const requestedWorkspaceId = activeWorkspaceId
    const requestId = ++loadPersonasRequestRef.current
    setLoading(true)
    setError(null)
    try {
      const [nextPersonas, nextCohorts] = await Promise.all([
        fetchAdminPersonas(),
        fetchAdminPersonaAssignableCohorts(),
      ])
      if (requestId !== loadPersonasRequestRef.current || requestedWorkspaceId !== activeWorkspaceIdRef.current) return
      setPersonas(nextPersonas)
      setCohorts(nextCohorts)
      const candidateId = preferredId
        ?? selectedIdRef.current
        ?? nextPersonas.find((persona) => persona.status !== 'archived')?.id
        ?? nextPersonas[0]?.id
        ?? null
      if (candidateId && nextPersonas.some((persona) => persona.id === candidateId)) {
        await loadPersona(candidateId)
      } else {
        selectedIdRef.current = null
        setSelectedPersona(null)
        setDraft(null)
      }
    } catch (caught) {
      if (requestId === loadPersonasRequestRef.current && requestedWorkspaceId === activeWorkspaceIdRef.current) {
        setError(errorMessage(caught, 'Coach Studio could not load.'))
      }
    } finally {
      if (requestId === loadPersonasRequestRef.current && requestedWorkspaceId === activeWorkspaceIdRef.current) setLoading(false)
    }
  }, [activeWorkspaceId, loadPersona])

  useEffect(() => {
    queueMicrotask(() => void loadPersonas())
  }, [loadPersonas])

  useEffect(() => {
    // Mobile browsers can preserve a temporary horizontal focus offset after
    // the native workspace picker closes and the narrower result view renders.
    window.scrollTo(0, window.scrollY)
  }, [activeWorkspaceId])

  useEffect(() => {
    if (createOpen) window.requestAnimationFrame(() => createNameRef.current?.focus())
  }, [createOpen])

  useEffect(() => {
    onDirtyChange(studioDirty)
  }, [studioDirty, onDirtyChange])

  useEffect(() => {
    const alert = error ? errorAlertRef.current : conflict ? conflictAlertRef.current : null
    if (!alert) return

    window.requestAnimationFrame(() => {
      alert.scrollIntoView({ block: 'center' })
      alert.focus({ preventScroll: true })
    })
  }, [conflict, error])

  useEffect(() => () => onDirtyChange(false), [onDirtyChange])

  useEffect(() => {
    if (!studioDirty) return
    const protectUnsavedDraft = (event: BeforeUnloadEvent) => {
      event.preventDefault()
      event.returnValue = ''
    }
    window.addEventListener('beforeunload', protectUnsavedDraft)
    return () => window.removeEventListener('beforeunload', protectUnsavedDraft)
  }, [studioDirty])

  function chooseStudioSection(next: StudioSection): boolean {
    if (next === studioSection) return true
    if (studioDirty && !window.confirm('Discard unsaved Coach Studio changes and switch views?')) return false
    if (dirty && selectedPersona) {
      setDraft(selectedPersona.draft ?? null)
      setDescription(selectedPersona.description)
    }
    setExperienceDirty(false)
    setLibraryDirty(false)
    setPersonaSourcesDirty(false)
    setStudioSection(next)
    return true
  }

  function chooseWorkspace(nextId: number | null) {
    if (nextId === activeWorkspaceId || pendingAction) return
    if (studioDirty && !window.confirm('Discard unsaved Coach Studio changes and switch workspaces?')) return

    mutationSequenceRef.current += 1
    selectCoachWorkspace(nextId)
    // Ignore an assistant detail response that began in the workspace we are leaving.
    loadPersonaRequestRef.current += 1
    loadPersonasRequestRef.current += 1
    selectedIdRef.current = null
    setPersonas([])
    setCohorts([])
    setSelectedPersona(null)
    setDraft(null)
    setPreview(null)
    setDescription('')
    setError(null)
    setConflict(null)
    setNotice(null)
    setExperienceDirty(false)
    setLibraryDirty(false)
    setPersonaSourcesDirty(false)
  }

  function handleStudioSectionKeyDown(event: KeyboardEvent<HTMLButtonElement>) {
    const tabs = Array.from(event.currentTarget.parentElement?.querySelectorAll<HTMLButtonElement>('[role="tab"]') ?? [])
    const currentIndex = tabs.indexOf(event.currentTarget)
    let nextIndex: number
    if (event.key === 'ArrowRight' || event.key === 'ArrowDown') nextIndex = (currentIndex + 1) % tabs.length
    else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') nextIndex = (currentIndex - 1 + tabs.length) % tabs.length
    else if (event.key === 'Home') nextIndex = 0
    else if (event.key === 'End') nextIndex = tabs.length - 1
    else return

    event.preventDefault()
    const nextTab = tabs[nextIndex]
    const nextSection = nextTab?.dataset.studioSection as StudioSection | undefined
    if (nextTab && nextSection && chooseStudioSection(nextSection)) nextTab.focus()
  }

  function replaceDraft(next: PersonaConfiguration) {
    setDraft(next)
    setNotice(null)
    setConflict(null)
  }

  function mutateDraft(mutator: (current: PersonaConfiguration) => PersonaConfiguration) {
    setDraft((current) => current ? mutator(current) : current)
    setNotice(null)
    setConflict(null)
  }

  function requestSelection(personaId: number) {
    if (personaId === selectedPersona?.id) return
    if (dirty || personaSourcesDirty) {
      setPendingSelectionId(personaId)
      setConflict('You have unsaved changes. Save this draft or discard the changes before opening another assistant.')
      return
    }
    focusEditorAfterLoadRef.current = true
    void loadPersona(personaId)
  }

  function requestLibraryReturn() {
    if (dirty || personaSourcesDirty) {
      setPendingLibraryReturn(true)
      setConflict('You have unsaved changes. Save this draft or discard the changes before returning to the assistant library.')
      return
    }
    closeSelectedPersona()
  }

  function closeSelectedPersona() {
    loadPersonaRequestRef.current += 1
    selectedIdRef.current = null
    setSelectedPersona(null)
    setDraft(null)
    setPersonaSourcesDirty(false)
    setPendingLibraryReturn(false)
    setConflict(null)
    window.requestAnimationFrame(() => libraryHeadingRef.current?.focus())
  }

  function beginMutation(action: Exclude<PendingAction, null>): MutationContext {
    const context = { sequence: ++mutationSequenceRef.current, workspaceId: activeWorkspaceIdRef.current }
    setPendingAction(action)
    return context
  }

  function mutationIsCurrent(context: MutationContext) {
    return context.sequence === mutationSequenceRef.current && context.workspaceId === activeWorkspaceIdRef.current
  }

  function finishMutation(context: MutationContext) {
    if (mutationIsCurrent(context)) setPendingAction(null)
  }

  async function handleCreate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!createName.trim() || pendingAction) return
    const mutation = beginMutation('create')
    setError(null)
    try {
      const persona = await createAdminPersona({ name: createName.trim(), description: createDescription.trim() })
      if (!mutationIsCurrent(mutation)) return
      setCreateOpen(false)
      setCreateName('')
      setCreateDescription('')
      setNotice(`${persona.name} is ready to shape.`)
      await loadPersonas(persona.id)
    } catch (caught) {
      if (mutationIsCurrent(mutation)) setError(errorMessage(caught, 'The assistant draft could not be created.'))
    } finally {
      finishMutation(mutation)
    }
  }

  async function saveDraft() {
    if (!selectedPersona || !draft || !selectedPersona.permissions.edit || pendingAction) return null
    const mutation = beginMutation('save')
    setError(null)
    setConflict(null)
    try {
      const persona = await updateAdminPersona(selectedPersona.id, {
        draft_revision: selectedPersona.draft_revision ?? 0,
        description,
        draft_config: draft,
      })
      if (!mutationIsCurrent(mutation)) return null
      setSelectedPersona(persona)
      setDraft(persona.draft ?? draft)
      setDescription(persona.description)
      setPreview(null)
      setPersonas((current) => replacePersonaSummary(current, persona))
      setNotice('Draft saved. Run an exact preview before publishing.')
      return persona
    } catch (caught) {
      if (mutationIsCurrent(mutation)) handleMutationError(caught, 'The draft could not be saved.')
      return null
    } finally {
      finishMutation(mutation)
    }
  }

  async function handlePreview() {
    if (!selectedPersona || !draft || dirty || pendingAction) return
    const mutation = beginMutation('preview')
    setError(null)
    setConflict(null)
    try {
      const response = await previewAdminPersona(selectedPersona.id, selectedPersona.draft_revision ?? 0, samplePrompt.trim() || undefined)
      if (!mutationIsCurrent(mutation)) return
      setSelectedPersona(response.persona)
      setDraft(response.persona.draft ?? draft)
      setPreview(response.preview)
      setPersonas((current) => replacePersonaSummary(current, response.persona))
      setNotice(response.preview.status === 'ready' ? 'Exact draft preview is ready for review.' : 'The exact draft was checked, but a behavioral sample is unavailable right now.')
    } catch (caught) {
      if (mutationIsCurrent(mutation)) handleMutationError(caught, 'The exact draft preview could not run.')
    } finally {
      finishMutation(mutation)
    }
  }

  async function handlePublish() {
    if (!selectedPersona || !preview || dirty || pendingAction) return
    if (preview.status !== 'ready') {
      setError('Run a successful behavioral preview before publishing this draft.')
      return
    }
    if (preview.digest !== selectedPersona.preview?.digest) {
      setError('Run an exact preview of the saved draft before publishing.')
      return
    }
    if (selectedPersona.assignments.length > 0 && !window.confirm(
      `Publish this version now? Future participant messages in ${selectedPersona.assignments.length} assigned cohort${selectedPersona.assignments.length === 1 ? '' : 's'} will use it immediately.`,
    )) return
    const mutation = beginMutation('publish')
    setError(null)
    setConflict(null)
    try {
      const response = await publishAdminPersona(selectedPersona.id, {
        draft_revision: selectedPersona.draft_revision ?? 0,
        preview_digest: preview.digest,
        expected_published_version_id: selectedPersona.published_version?.id ?? null,
      })
      if (!mutationIsCurrent(mutation)) return
      setSelectedPersona(response.persona)
      setDraft(response.persona.draft ?? draft)
      setPersonas((current) => replacePersonaSummary(current, response.persona))
      setNotice(`${response.persona.name} version ${response.published_version.number} is published.`)
      await refreshCohorts(mutation)
    } catch (caught) {
      if (mutationIsCurrent(mutation)) {
        setPreview(null)
        handleMutationError(caught, 'The assistant could not be published.')
      }
    } finally {
      finishMutation(mutation)
    }
  }

  async function handleArchive() {
    if (!selectedPersona || pendingAction) return
    if (dirty) {
      setConflict('Save or discard your unsaved changes before archiving this assistant.')
      return
    }
    if (!window.confirm(`Archive ${selectedPersona.name}? Its published history will remain available.`)) return
    const mutation = beginMutation('archive')
    setError(null)
    try {
      const persona = await archiveAdminPersona(selectedPersona.id)
      if (!mutationIsCurrent(mutation)) return
      acceptPersona(persona)
      setNotice(`${persona.name} is archived.`)
    } catch (caught) {
      if (mutationIsCurrent(mutation)) handleMutationError(caught, 'The assistant could not be archived.')
    } finally {
      finishMutation(mutation)
    }
  }

  async function handleRestore() {
    if (!selectedPersona || pendingAction) return
    const mutation = beginMutation('restore')
    setError(null)
    try {
      const persona = await restoreAdminPersona(selectedPersona.id)
      if (!mutationIsCurrent(mutation)) return
      acceptPersona(persona)
      setNotice(`${persona.name} is restored as an editable draft.`)
    } catch (caught) {
      if (mutationIsCurrent(mutation)) handleMutationError(caught, 'The assistant could not be restored.')
    } finally {
      finishMutation(mutation)
    }
  }

  async function handleRollback(versionId: number, versionNumber: number) {
    if (!selectedPersona || pendingAction) return
    if (dirty) {
      setConflict('Save or discard your unsaved changes before restoring an earlier version.')
      return
    }
    const assignmentImpact = selectedPersona.assignments.length > 0
      ? ` Future participant messages in ${selectedPersona.assignments.length} assigned cohort${selectedPersona.assignments.length === 1 ? '' : 's'} will use it immediately.`
      : ''
    if (!window.confirm(`Publish a new version using the content from version ${versionNumber}? Current history will stay intact.${assignmentImpact}`)) return
    const mutation = beginMutation('rollback')
    setError(null)
    try {
      const response = await rollbackAdminPersonaVersion(selectedPersona.id, versionId, {
        expected_published_version_id: selectedPersona.published_version?.id ?? null,
        draft_revision: selectedPersona.draft_revision ?? 0,
      })
      if (!mutationIsCurrent(mutation)) return
      acceptPersona(response.persona)
      setPreview(null)
      setNotice(`Version ${response.published_version.number} is now published from version ${versionNumber}.`)
      await refreshCohorts(mutation)
    } catch (caught) {
      if (mutationIsCurrent(mutation)) handleMutationError(caught, 'The version could not be restored.')
    } finally {
      finishMutation(mutation)
    }
  }

  async function handleAssignment(cohort: AdminPersonaAssignableCohort) {
    if (!selectedPersona?.published_version || pendingAction || !cohort.assignable) return
    if (dirty) {
      setConflict('Save or discard your unsaved changes before changing cohort assignments.')
      return
    }
    const mutation = beginMutation('assignment')
    setError(null)
    try {
      await updateAdminCohortPersonaAssignment(
        cohort.id,
        selectedPersona.id,
        cohort.persona_assignment?.persona.id ?? null,
      )
      if (!mutationIsCurrent(mutation)) return
      await Promise.all([refreshCohorts(mutation), loadPersona(selectedPersona.id)])
      if (!mutationIsCurrent(mutation)) return
      setNotice(`${selectedPersona.name} is assigned to ${cohort.name}.`)
    } catch (caught) {
      if (mutationIsCurrent(mutation)) {
        handleMutationError(caught, 'The cohort assignment could not be changed.')
        await refreshCohorts(mutation)
      }
    } finally {
      finishMutation(mutation)
    }
  }

  async function handleRemoveAssignment(cohort: AdminPersonaAssignableCohort) {
    const assignedPersonaId = cohort.persona_assignment?.persona.id
    if (!assignedPersonaId || !selectedPersona || pendingAction) return
    if (dirty) {
      setConflict('Save or discard your unsaved changes before changing cohort assignments.')
      return
    }
    if (!window.confirm(`Remove the coaching assistant from ${cohort.name}? Participants will receive the neutral product voice until another persona is assigned.`)) return
    const mutation = beginMutation('assignment')
    setError(null)
    try {
      await deleteAdminCohortPersonaAssignment(cohort.id, assignedPersonaId)
      if (!mutationIsCurrent(mutation)) return
      await Promise.all([refreshCohorts(mutation), loadPersona(selectedPersona.id)])
      if (!mutationIsCurrent(mutation)) return
      setNotice(`The coaching assistant was removed from ${cohort.name}.`)
    } catch (caught) {
      if (mutationIsCurrent(mutation)) {
        handleMutationError(caught, 'The cohort assignment could not be removed.')
        await refreshCohorts(mutation)
      }
    } finally {
      finishMutation(mutation)
    }
  }

  async function refreshCohorts(mutation?: MutationContext) {
    try {
      const nextCohorts = await fetchAdminPersonaAssignableCohorts()
      if (mutation && !mutationIsCurrent(mutation)) return
      setCohorts(nextCohorts)
    } catch (caught) {
      if (!mutation || mutationIsCurrent(mutation)) setError(errorMessage(caught, 'Cohort assignments could not be refreshed.'))
    }
  }

  function acceptPersona(persona: AdminPersonaDetail) {
    setSelectedPersona(persona)
    setDraft(persona.draft ?? null)
    setDescription(persona.description)
    setPreview(null)
    setPersonas((current) => replacePersonaSummary(current, persona))
  }

  function handleMutationError(caught: unknown, fallback: string) {
    const message = errorMessage(caught, fallback)
    if (caught instanceof ApiRequestError && caught.status === 409) {
      setConflict(message)
      return
    }
    setError(message)
  }

  const previewMatches = Boolean(preview && selectedPersona?.preview?.digest === preview.digest && !dirty)
  const canPublish = Boolean(selectedPersona?.permissions.publish && previewMatches && preview?.status === 'ready' && selectedPersona?.preview_required === false)
  const assignmentCohorts = selectedPersona ? cohorts : []

  return (
    <section className="screen-grid coach-studio-screen" aria-busy={loading || detailLoading || pendingAction !== null}>
      <header className="screen-heading coach-studio-heading">
        <div>
          <p className="eyebrow">Coach Studio</p>
          <h2 data-page-heading tabIndex={-1}>Shape a coaching assistant people can trust.</h2>
        </div>
        <div className="coach-workspace-heading-tools">
          <p>Build the voice from the coach's own teaching, preview the exact draft, then publish and assign it to a cohort. Location provides context only; the system never invents an accent, slang, or cultural assumptions.</p>
          {workspaceOptions.length > 0 && (
            <label className="coach-workspace-picker">
              <span>Coach workspace</span>
              <select disabled={pendingAction !== null} value={activeWorkspaceId ?? 'platform'} onChange={(event) => chooseWorkspace(event.target.value === 'platform' ? null : Number(event.target.value))}>
                {currentUser.is_admin && <option value="platform">All workspaces / Platform</option>}
                {workspaceOptions.map((workspace) => (
                  <option key={workspace.id} value={workspace.id}>{workspace.name}</option>
                ))}
              </select>
              <small>{activeWorkspaceId === null
                ? 'Platform administrator · all workspaces'
                : `${workspaceOptions.find((workspace) => workspace.id === activeWorkspaceId)?.coach_profile?.display_name ?? 'Coach identity'} · ${formatWorkspaceRole(workspaceOptions.find((workspace) => workspace.id === activeWorkspaceId)?.membership_role)}`}</small>
            </label>
          )}
        </div>
      </header>

      <div className="coach-studio-trust-strip" role="note">
        <span aria-hidden="true"><ShieldIcon /></span>
        <p><strong>Always a digital assistant.</strong> System financial, privacy, crisis, and approval guardrails stay locked for every persona.</p>
        <small>Signed in as {currentUser.full_name}</small>
      </div>

      <nav className="coach-studio-section-tabs" role="tablist" aria-label="Coach Studio areas">
        <button type="button" role="tab" id="coach-studio-tab-assistants" aria-controls="coach-studio-panel-assistants" aria-selected={studioSection === 'assistants'} tabIndex={studioSection === 'assistants' ? 0 : -1} data-studio-section="assistants" onKeyDown={handleStudioSectionKeyDown} onClick={() => chooseStudioSection('assistants')}>
          <strong>Assistant voice</strong><small>Shape how Mia coaches and communicates</small>
        </button>
        <button type="button" role="tab" id="coach-studio-tab-library" aria-controls="coach-studio-panel-library" aria-selected={studioSection === 'library'} tabIndex={studioSection === 'library' ? 0 : -1} data-studio-section="library" onKeyDown={handleStudioSectionKeyDown} onClick={() => chooseStudioSection('library')}>
          <strong>Coaching Library</strong><small>Approve and publish reusable coaching sources</small>
        </button>
        <button type="button" role="tab" id="coach-studio-tab-participant-tools" aria-controls="coach-studio-panel-participant-tools" aria-selected={studioSection === 'participant_tools'} tabIndex={studioSection === 'participant_tools' ? 0 : -1} data-studio-section="participant_tools" onKeyDown={handleStudioSectionKeyDown} onClick={() => chooseStudioSection('participant_tools')}>
          <strong>Participant tools</strong><small>Choose the cohort's optional learning tools</small>
        </button>
      </nav>

      {studioSection === 'library' ? (
        <div className="coach-studio-tab-panel" role="tabpanel" id="coach-studio-panel-library" aria-labelledby="coach-studio-tab-library" tabIndex={0}>
          <CoachContentLibrary key={activeWorkspaceId ?? 'legacy'} currentUser={currentUser} onDirtyChange={setLibraryDirty} />
        </div>
      ) : studioSection === 'participant_tools' ? (
        <div className="coach-studio-tab-panel" role="tabpanel" id="coach-studio-panel-participant-tools" aria-labelledby="coach-studio-tab-participant-tools" tabIndex={0}>
          <CohortExperienceStudio key={activeWorkspaceId ?? 'legacy'} cohorts={cohorts} cohortsLoading={loading} onDirtyChange={setExperienceDirty} />
        </div>
      ) : <div className="coach-studio-tab-panel" role="tabpanel" id="coach-studio-panel-assistants" aria-labelledby="coach-studio-tab-assistants" tabIndex={0}>

      {error && <div className="coach-studio-alert is-error" role="alert" tabIndex={-1} ref={errorAlertRef}><span>{error}</span><button type="button" onClick={() => { setError(null); void loadPersonas(selectedPersona?.id) }}>Retry</button></div>}
      {notice && <p className="coach-studio-alert is-success" role="status">{notice}</p>}
      {conflict && (
        <div className="coach-studio-alert is-conflict" role="alert" tabIndex={-1} ref={conflictAlertRef}>
          <span>{conflict}</span>
          <div>
            {selectedPersona && <button type="button" onClick={() => void loadPersona(selectedPersona.id)}>Reload server draft</button>}
            {pendingSelectionId && <button type="button" onClick={() => { const target = pendingSelectionId; setPendingSelectionId(null); setConflict(null); focusEditorAfterLoadRef.current = true; void loadPersona(target) }}>Discard and switch</button>}
            {pendingLibraryReturn && <button type="button" onClick={closeSelectedPersona}>Discard and show assistants</button>}
            <button type="button" className="link-button" onClick={() => { setConflict(null); setPendingSelectionId(null); setPendingLibraryReturn(false) }}>Keep editing</button>
          </div>
        </div>
      )}

      <div className={`coach-studio-layout${selectedPersona ? ' has-selection' : ''}`}>
        <aside className="coach-library panel" aria-label="Coaching assistants">
          <div className="coach-library-heading">
            <div>
              <p className="eyebrow">Assistant library</p>
              <h3 ref={libraryHeadingRef} tabIndex={-1}>{personas.length} coaching assistant{personas.length === 1 ? '' : 's'}</h3>
            </div>
            <Button size="compact" disabled={workspaceCreateDisabled} onClick={() => setCreateOpen(true)}>Create</Button>
          </div>

          {workspaceCreateDisabled && <p className="coach-content-note">Choose a coach workspace before creating an assistant. Platform mode can review all workspaces without assigning a hidden owner.</p>}

          {createOpen && (
            <form className="coach-create-form" onSubmit={handleCreate}>
              <label>
                <span>Assistant name</span>
                <input ref={createNameRef} required maxLength={80} value={createName} onChange={(event) => setCreateName(event.target.value)} placeholder="Coach Lani" />
              </label>
              <label>
                <span>Internal description</span>
                <textarea rows={2} value={createDescription} onChange={(event) => setCreateDescription(event.target.value)} placeholder="Mrs. Mel's first cohort voice" />
              </label>
              <div>
                <Button size="compact" type="submit" disabled={pendingAction === 'create'}>{pendingAction === 'create' ? 'Creating' : 'Create safe draft'}</Button>
                <Button size="compact" type="button" variant="ghost" onClick={() => setCreateOpen(false)}>Cancel</Button>
              </div>
            </form>
          )}

          <label className="coach-library-search">
            <span>Search assistants</span>
            <input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Name, coach, or description" />
          </label>
          <div className="coach-filter-row" aria-label="Filter assistants">
            {(['active', 'draft', 'published', 'archived', 'all'] as PersonaFilter[]).map((value) => (
              <button type="button" key={value} className={filter === value ? 'is-active' : ''} aria-pressed={filter === value} onClick={() => setFilter(value)}>{titleize(value)}</button>
            ))}
          </div>

          {loading && personas.length === 0 ? (
            <p className="coach-empty" role="status">Loading coaching assistants…</p>
          ) : filteredPersonas.length === 0 ? (
            <div className="coach-empty">
              <strong>{personas.length === 0 ? 'Create the first coaching assistant.' : 'No assistants match this view.'}</strong>
              <p>{personas.length === 0 ? 'The server starts every assistant with a safe, neutral configuration you can shape.' : 'Change the search or status filter.'}</p>
            </div>
          ) : (
            <div className="coach-library-list">
              {filteredPersonas.map((persona) => (
                <button
                  type="button"
                  key={persona.id}
                  disabled={pendingAction !== null}
                  className={selectedPersona?.id === persona.id ? 'is-selected' : ''}
                  aria-current={selectedPersona?.id === persona.id ? 'true' : undefined}
                  onClick={() => requestSelection(persona.id)}
                >
                  <span><strong>{persona.name}</strong><StatusBadge status={persona.status} /></span>
                  <small>{persona.role}</small>
                  <small>{persona.visible_assignment_count} cohort assignment{persona.visible_assignment_count === 1 ? '' : 's'}{persona.has_unpublished_changes ? ' · Unpublished changes' : ''}</small>
                </button>
              ))}
            </div>
          )}
        </aside>

        <div className="coach-editor-column">
          {detailLoading ? (
            <article className="panel coach-loading" role="status">Loading the selected assistant…</article>
          ) : !selectedPersona ? (
            <article className="panel coach-empty coach-empty-main">
              <p className="eyebrow">Start here</p>
              <h3>Create a safe draft, then shape it with the guided questions.</h3>
              <p>You can preview and publish only after the exact saved revision has passed the fixed system guardrails.</p>
              <Button disabled={workspaceCreateDisabled} onClick={() => setCreateOpen(true)}>Create coaching assistant</Button>
            </article>
          ) : (
            <>
              <article className="panel coach-editor-shell">
                <header className="coach-editor-header">
                  <div>
                    <button type="button" className="coach-mobile-back" disabled={pendingAction !== null} onClick={requestLibraryReturn}>← All assistants</button>
                    <p className="eyebrow">{selectedPersona.owner?.full_name ? `${selectedPersona.owner.full_name}'s assistant` : 'Coaching assistant'}</p>
                    <h3 ref={editorHeadingRef} tabIndex={-1}>{selectedPersona.name}</h3>
                    <p>{selectedPersona.description || (draft ? 'Add an internal description so other staff understand where this voice belongs.' : 'Published assistant assigned to a cohort you manage.')}</p>
                  </div>
                  <div className="coach-editor-status">
                    <StatusBadge status={selectedPersona.status} />
                    {dirty && <span className="coach-unsaved">Unsaved changes</span>}
                    {!dirty && selectedPersona.has_unpublished_changes && <span className="coach-unpublished">Saved, not published</span>}
                  </div>
                </header>

                {draft ? (
                  <>
                    <div className="coach-mode-switch" role="group" aria-label="Editing mode">
                      <button type="button" aria-pressed={mode === 'guided'} className={mode === 'guided' ? 'is-active' : ''} onClick={() => setMode('guided')}>
                        <strong>Guided setup</strong><small>Short steps with plain-language prompts</small>
                      </button>
                      <button type="button" aria-pressed={mode === 'advanced'} className={mode === 'advanced' ? 'is-active' : ''} onClick={() => setMode('advanced')}>
                        <strong>Advanced settings</strong><small>Every structured field in one view</small>
                      </button>
                    </div>

                    {selectedPersona.permissions.edit ? (
                      <PersonaEditor
                        draft={draft}
                        phraseArtifactAccess={selectedPersona.phrase_artifact_access}
                        description={description}
                        mode={mode}
                        guidedStep={guidedStep}
                        onStepChange={setGuidedStep}
                        onDescriptionChange={setDescription}
                        onChange={replaceDraft}
                        mutate={mutateDraft}
                      />
                    ) : (
                      <p className="coach-read-only" role="note">This assistant is read-only for your account or while archived. You can review its published history and assignments below.</p>
                    )}

                    <div className="coach-save-bar">
                      <div>
                        <strong>{dirty ? 'Draft changes are local to this browser.' : 'Draft matches the latest server revision.'}</strong>
                        <small>{dirty ? 'Save before previewing so the exact revision is checked.' : `Draft revision ${selectedPersona.draft_revision ?? 'read-only'}`}</small>
                      </div>
                      {selectedPersona.permissions.edit && <Button onClick={() => void saveDraft()} disabled={!dirty || pendingAction !== null}>{pendingAction === 'save' ? 'Saving draft' : 'Save draft'}</Button>}
                    </div>
                  </>
                ) : (
                  <p className="coach-read-only">Private draft settings are visible only to the owning coach and administrators. The published identity and assignment history remain available.</p>
                )}
              </article>

              {selectedPersona.draft && (
                <PersonaContentPacksPanel
                  key={selectedPersona.id}
                  persona={selectedPersona}
                  dirty={dirty}
                  onDirtyChange={setPersonaSourcesDirty}
                  onPersonaChange={(persona) => {
                    setPersonaSourcesDirty(false)
                    acceptPersona(persona)
                    setNotice('Approved content selection saved. Run a fresh preview before publishing.')
                  }}
                />
              )}

              <LifecyclePanel
                persona={selectedPersona}
                preview={preview}
                samplePrompt={samplePrompt}
                dirty={dirty}
                canPublish={canPublish}
                pendingAction={pendingAction}
                onSamplePromptChange={setSamplePrompt}
                onPreview={() => void handlePreview()}
                onPublish={() => void handlePublish()}
                onRollback={(versionId, number) => void handleRollback(versionId, number)}
                onArchive={() => void handleArchive()}
                onRestore={() => void handleRestore()}
              />

              <AssignmentPanel
                persona={selectedPersona}
                cohorts={assignmentCohorts}
                pending={pendingAction === 'assignment'}
                dirty={dirty}
                onAssign={(cohort) => void handleAssignment(cohort)}
                onRemove={(cohort) => void handleRemoveAssignment(cohort)}
              />
            </>
          )}
        </div>
      </div>
      </div>}
    </section>
  )
}

function formatWorkspaceRole(role: string | null | undefined) {
  return (role ?? 'viewer').replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase())
}

function PersonaEditor({
  draft,
  phraseArtifactAccess,
  description,
  mode,
  guidedStep,
  onStepChange,
  onDescriptionChange,
  onChange,
  mutate,
}: {
  draft: PersonaConfiguration
  phraseArtifactAccess: AdminPersonaDetail['phrase_artifact_access']
  description: string
  mode: EditorMode
  guidedStep: GuidedStep
  onStepChange: (step: GuidedStep) => void
  onDescriptionChange: (value: string) => void
  onChange: (draft: PersonaConfiguration) => void
  mutate: (mutator: (current: PersonaConfiguration) => PersonaConfiguration) => void
}) {
  const currentIndex = guidedSteps.findIndex((step) => step.id === guidedStep)

  function handleStepKeyDown(event: KeyboardEvent<HTMLButtonElement>, index: number) {
    let nextIndex = index
    if (event.key === 'ArrowRight') nextIndex = (index + 1) % guidedSteps.length
    else if (event.key === 'ArrowLeft') nextIndex = (index - 1 + guidedSteps.length) % guidedSteps.length
    else if (event.key === 'Home') nextIndex = 0
    else if (event.key === 'End') nextIndex = guidedSteps.length - 1
    else return

    event.preventDefault()
    onStepChange(guidedSteps[nextIndex].id)
    const tabs = event.currentTarget.parentElement?.querySelectorAll<HTMLButtonElement>('[role="tab"]')
    window.requestAnimationFrame(() => tabs?.[nextIndex]?.focus())
  }

  return (
    <div className={`persona-editor is-${mode}`}>
      {mode === 'guided' && (
        <>
          <div className="coach-step-tabs" role="tablist" aria-label="Guided setup steps">
            {guidedSteps.map((step, index) => (
              <button
                type="button"
                role="tab"
                key={step.id}
                id={`coach-step-tab-${step.id}`}
                aria-controls={`coach-step-panel-${step.id}`}
                aria-selected={guidedStep === step.id}
                tabIndex={guidedStep === step.id ? 0 : -1}
                className={guidedStep === step.id ? 'is-active' : ''}
                onClick={() => onStepChange(step.id)}
                onKeyDown={(event) => handleStepKeyDown(event, index)}
              >
                <span>{index + 1}</span>{step.label}
              </button>
            ))}
          </div>
          <div role="tabpanel" className="coach-step-panel" id={`coach-step-panel-${guidedStep}`} aria-labelledby={`coach-step-tab-${guidedStep}`}>
            {renderEditorSection(guidedStep, draft, onChange, mutate, description, onDescriptionChange, phraseArtifactAccess)}
          </div>
          <div className="coach-step-actions">
            <Button type="button" variant="secondary" disabled={currentIndex === 0} onClick={() => onStepChange(guidedSteps[currentIndex - 1].id)}>Previous</Button>
            <span>Step {currentIndex + 1} of {guidedSteps.length}</span>
            <Button type="button" disabled={currentIndex === guidedSteps.length - 1} onClick={() => onStepChange(guidedSteps[currentIndex + 1].id)}>Next</Button>
          </div>
        </>
      )}

      {mode === 'advanced' && (
        <div className="coach-advanced-sections">
          {guidedSteps.map((step) => (
            <details key={step.id} open={step.id === 'identity'}>
              <summary>{step.label}</summary>
              <div>{renderEditorSection(step.id, draft, onChange, mutate, description, onDescriptionChange, phraseArtifactAccess)}</div>
            </details>
          ))}
        </div>
      )}
    </div>
  )
}

function renderEditorSection(
  step: GuidedStep,
  draft: PersonaConfiguration,
  onChange: (draft: PersonaConfiguration) => void,
  mutate: (mutator: (current: PersonaConfiguration) => PersonaConfiguration) => void,
  description: string,
  onDescriptionChange: (value: string) => void,
  phraseArtifactAccess: AdminPersonaDetail['phrase_artifact_access'],
) {
  if (step === 'identity') {
    return (
      <EditorFieldset legend="Who is this assistant?" copy="Use a distinct assistant name and name the human coach whose approved approach it applies.">
        <TextInput label="Assistant name" value={draft.identity.assistant_name} maxLength={80} onChange={(value) => onChange({ ...draft, identity: { ...draft.identity, assistant_name: value } })} />
        <TextInput label="Human coach name" value={draft.identity.human_coach_name} maxLength={120} onChange={(value) => onChange({ ...draft, identity: { ...draft.identity, human_coach_name: value } })} />
        <TextInput label="Human coach title" value={draft.identity.human_coach_title} maxLength={120} onChange={(value) => onChange({ ...draft, identity: { ...draft.identity, human_coach_title: value } })} />
        <TextInput label="Participant term" value={draft.identity.client_term} maxLength={80} help="For example: participant, household, member, or client." onChange={(value) => onChange({ ...draft, identity: { ...draft.identity, client_term: value } })} />
        <TextArea label="Internal description" value={description} rows={2} help="Visible to staff in the assistant library." onChange={onDescriptionChange} />
        <TextArea label="Audience" value={draft.identity.audience} maxLength={500} rows={3} onChange={(value) => onChange({ ...draft, identity: { ...draft.identity, audience: value } })} />
        <TextArea label="Assistant relationship" value={draft.identity.assistant_relationship} maxLength={400} rows={3} help="Must clearly say this is a digital or AI assistant." onChange={(value) => onChange({ ...draft, identity: { ...draft.identity, assistant_relationship: value } })} />
        <TextArea label="Disclosure shown to the model" value={draft.identity.disclosure} maxLength={500} rows={3} help="Keep the digital assistant identity explicit. This cannot be replaced by a human impersonation." onChange={(value) => onChange({ ...draft, identity: { ...draft.identity, disclosure: value } })} />
      </EditorFieldset>
    )
  }

  if (step === 'voice') {
    return (
      <EditorFieldset legend="How should it sound?" copy="Choose from reviewed voice options. Community wording can only come from sealed phrase artifacts.">
        <ChoiceChips label="Tone traits" options={PERSONA_TONE_TRAITS} selected={draft.voice.tone_traits} minimum={1} onChange={(values) => onChange({ ...draft, voice: { ...draft.voice, tone_traits: values } })} />
        <SelectChoice label="Energy" options={PERSONA_ENERGY_STYLES} value={draft.voice.energy} onChange={(value) => onChange({ ...draft, voice: { ...draft.voice, energy: value } })} />
        <SelectChoice label="Accountability style" options={PERSONA_ACCOUNTABILITY_STYLES} value={draft.voice.accountability_style} onChange={(value) => onChange({ ...draft, voice: { ...draft.voice, accountability_style: value } })} />
        <ChoiceChips label="Language style" options={PERSONA_LANGUAGE_STYLES} selected={draft.voice.language_style} minimum={1} onChange={(values) => onChange({ ...draft, voice: { ...draft.voice, language_style: values } })} />
      </EditorFieldset>
    )
  }

  if (step === 'coaching') {
    return (
      <EditorFieldset legend="How does the coach help someone decide?" copy="Capture the teaching method and accountability boundaries. Fixed safety rules still take priority.">
        <TextArea label="Coaching philosophy" value={draft.coaching.philosophy} maxLength={1200} rows={4} onChange={(value) => onChange({ ...draft, coaching: { ...draft.coaching, philosophy: value } })} />
        <TextArea label="Method" value={draft.coaching.method} maxLength={600} rows={4} onChange={(value) => onChange({ ...draft, coaching: { ...draft.coaching, method: value } })} />
        <LineList label="Principles" values={draft.coaching.principles} minItems={1} maxItems={16} itemMaxLength={400} onChange={(values) => onChange({ ...draft, coaching: { ...draft.coaching, principles: values } })} />
        <LineList label="Do" values={draft.coaching.do} maxItems={16} itemMaxLength={400} help="Optional behaviors to encourage, one per line." onChange={(values) => onChange({ ...draft, coaching: { ...draft.coaching, do: values } })} />
        <LineList label="Do not" values={draft.coaching.do_not} maxItems={16} itemMaxLength={400} help="State a safe boundary without quoting or embedding cultural mimicry. Every line is validated as an instruction." onChange={(values) => onChange({ ...draft, coaching: { ...draft.coaching, do_not: values } })} />
      </EditorFieldset>
    )
  }

  if (step === 'culture') {
    return (
      <EditorFieldset legend="What community context has the coach approved?" copy="Locale is a label for context. It never generates dialect, accent, slang, values, or stereotypes. Add only language and realities the coach has explicitly authored.">
        <div className="coach-culture-boundary" role="note"><strong>Coach authored only.</strong> Choosing Guam, the South, or another place does not add phrases automatically.</div>
        <TextInput label="Locale label" value={draft.culture.locale_label} maxLength={120} help="For example: Guam families in Mrs. Mel's first cohort, or No locale selected." onChange={(value) => onChange({ ...draft, culture: { ...draft.culture, locale_label: value } })} />
        <TextArea label="Cultural and community context" value={draft.culture.context} maxLength={1000} rows={5} onChange={(value) => onChange({ ...draft, culture: { ...draft.culture, context: value } })} />
        <LineList label="Local realities" values={draft.culture.local_realities} maxItems={16} itemMaxLength={300} help="One verified factual access, cost, calendar, weather, or regulatory reality per line." onChange={(values) => onChange({ ...draft, culture: { ...draft.culture, local_realities: values } })} />
        <LineList label="Approved references" values={draft.culture.references} maxItems={16} itemMaxLength={300} help="Coach authored examples, programs, or community references." onChange={(values) => onChange({ ...draft, culture: { ...draft.culture, references: values } })} />
        <PhraseEditor draft={draft} mutate={mutate} access={phraseArtifactAccess} />
      </EditorFieldset>
    )
  }

  return (
    <EditorFieldset legend="What teaching material and answer shape are approved?" copy="Add reusable lessons and examples, then set a concise response range that fits the audience.">
      <GuidanceEditor draft={draft} mutate={mutate} />
      <ScriptEditor draft={draft} mutate={mutate} />
      <ExampleEditor draft={draft} mutate={mutate} />
      <div className="coach-response-grid">
        <NumberInput label="Minimum sentences" min={1} max={10} value={draft.response_shape.min_sentences} onChange={(value) => onChange({ ...draft, response_shape: { ...draft.response_shape, min_sentences: value } })} />
        <NumberInput label="Maximum sentences" min={1} max={12} value={draft.response_shape.max_sentences} onChange={(value) => onChange({ ...draft, response_shape: { ...draft.response_shape, max_sentences: value } })} />
        <NumberInput label="Maximum characters" min={200} max={4000} value={draft.response_shape.max_characters} onChange={(value) => onChange({ ...draft, response_shape: { ...draft.response_shape, max_characters: value } })} />
      </div>
      <div className="coach-check-grid">
        <CheckField label="Plain text answers" checked={draft.response_shape.plain_text_only} onChange={(checked) => onChange({ ...draft, response_shape: { ...draft.response_shape, plain_text_only: checked } })} />
      </div>
      <div className="coach-culture-boundary" role="note"><strong>Fact validation and one concrete next move are always on.</strong> Every persona must verify missing financial facts before coaching and end factual financial answers with one practical next step. These rules cannot be changed here.</div>
    </EditorFieldset>
  )
}

function LifecyclePanel({ persona, preview, samplePrompt, dirty, canPublish, pendingAction, onSamplePromptChange, onPreview, onPublish, onRollback, onArchive, onRestore }: {
  persona: AdminPersonaDetail
  preview: AdminPersonaPreview | null
  samplePrompt: string
  dirty: boolean
  canPublish: boolean
  pendingAction: PendingAction
  onSamplePromptChange: (value: string) => void
  onPreview: () => void
  onPublish: () => void
  onRollback: (versionId: number, number: number) => void
  onArchive: () => void
  onRestore: () => void
}) {
  const savedPreviewNeedsReview = !dirty && !preview && persona.preview_required === false && Boolean(persona.preview)
  const previewStatus = persona.preview_required
    ? 'preview required'
    : canPublish
      ? 'ready to publish'
      : savedPreviewNeedsReview
        ? 'saved preview'
        : 'preview required'

  return (
    <article className="panel coach-lifecycle">
      <header>
        <div><p className="eyebrow">Preview and publish</p><h3>Check the exact saved revision.</h3></div>
        <StatusBadge status={previewStatus} />
      </header>
      <label className="coach-sample-prompt">
        <span>Behavioral preview question</span>
        <textarea rows={3} maxLength={2000} value={samplePrompt} onChange={(event) => onSamplePromptChange(event.target.value)} placeholder="Ask the kind of question a participant will bring." />
        <small>Use fictional details only. Do not paste participant names, messages, or financial information. Your sample question is sent to the configured model; saved household data is not loaded.</small>
      </label>
      <div className="coach-lifecycle-actions">
        <Button variant="secondary" onClick={onPreview} disabled={dirty || !persona.permissions.publish || pendingAction !== null}>{pendingAction === 'preview' ? 'Running exact preview' : 'Run exact preview'}</Button>
        <Button onClick={onPublish} disabled={!canPublish || pendingAction !== null}>{pendingAction === 'publish' ? 'Publishing' : persona.published_version ? 'Publish next version' : 'Publish first version'}</Button>
      </div>
      {dirty && <p className="coach-inline-note">Save this draft before previewing. The preview digest is tied to one exact saved revision.</p>}
      {!dirty && preview?.status === 'unavailable' && <p className="coach-inline-note">A successful behavioral preview is required before publishing. Try again when the configured model is available.</p>}
      {!dirty && preview?.status === 'safety_only' && <p className="coach-inline-note">The crisis boundary worked, but it did not exercise this persona. Run a non-crisis question with the configured model before publishing.</p>}
      {savedPreviewNeedsReview && <p className="coach-inline-note">This exact revision passed preview in another session. Run it again here to review the behavior before publishing.</p>}
      {persona.assignments.length > 0 && <p className="coach-inline-note">Publishing or restoring a version updates future participant messages in all assigned cohorts immediately. You will confirm this impact before it changes.</p>}
      {preview && <PreviewResult preview={preview} current={canPublish} />}

      <details className="coach-locked-guardrails">
        <summary>Locked system guardrails</summary>
        <div>
          <p>{persona.guardrails.source} · Persona authors cannot edit these rules.</p>
          <ul>{persona.guardrails.rules.map((rule) => <li key={rule}>{rule}</li>)}</ul>
        </div>
      </details>

      <details className="coach-version-history">
        <summary>Version history ({persona.versions.length})</summary>
        <div className="coach-version-list">
          {persona.versions.length === 0 ? <p>No published versions yet.</p> : persona.versions.map((version) => (
            <article key={version.id}>
              <div><strong>Version {version.number}</strong><small>{new Date(version.published_at).toLocaleString()} · {version.published_by?.full_name ?? 'Unknown publisher'}</small>{version.restored_from_version && <small>Restored from version {version.restored_from_version.number}</small>}</div>
              {version.id === persona.published_version?.id ? <StatusBadge status="current" /> : persona.permissions.publish && <Button size="compact" variant="ghost" disabled={dirty || pendingAction !== null} onClick={() => onRollback(version.id, version.number)}>Restore as new version</Button>}
            </article>
          ))}
        </div>
      </details>

      <div className="coach-archive-row">
        {persona.status === 'archived'
          ? <Button variant="secondary" disabled={!persona.permissions.restore || pendingAction !== null} onClick={onRestore}>{pendingAction === 'restore' ? 'Restoring' : 'Restore assistant'}</Button>
          : <Button variant="danger" disabled={dirty || !persona.permissions.archive || pendingAction !== null} onClick={onArchive}>{pendingAction === 'archive' ? 'Archiving' : 'Archive assistant'}</Button>}
        {!persona.permissions.archive && persona.permissions.edit && persona.status !== 'archived' && <small>Remove this assistant from every draft, enrolling, or active cohort before archiving.</small>}
      </div>
    </article>
  )
}

function PreviewResult({ preview, current }: { preview: AdminPersonaPreview; current: boolean }) {
  const heading = preview.status === 'ready'
    ? 'Behavioral sample ready'
    : preview.status === 'safety_only'
      ? 'Safety response checked'
      : preview.status === 'unavailable'
        ? 'Behavioral sample unavailable'
        : 'Exact draft checked'

  return (
    <section className={`coach-preview-result is-${preview.status}`} aria-label="Exact draft preview">
      <header><div><strong>{heading}</strong><small>Draft revision {preview.draft_revision} · {titleize(preview.source)}</small></div><StatusBadge status={current ? 'current preview' : 'not publishable'} /></header>
      <p>{preview.notice}</p>
      {preview.sample_prompt && <div><small>Sample question</small><p>{preview.sample_prompt}</p></div>}
      {preview.sample_reply && <blockquote>{preview.sample_reply}</blockquote>}
      {!preview.sample_reply && preview.status === 'unavailable' && <p className="coach-inline-note">No generated answer is shown because the model preview was unavailable. Publishing stays locked until a successful behavioral preview checks this exact draft.</p>}
      {preview.status === 'safety_only' && <p className="coach-inline-note">This safety response is shown for review, but it cannot authorize publication because the coach persona was not exercised.</p>}
      <details><summary>Compiled instructions for this revision</summary><pre>{preview.rendered_instructions}</pre></details>
      <small>Guardrails applied: {preview.guardrails_applied ? 'Yes' : 'No'} · Generated {new Date(preview.generated_at).toLocaleString()}</small>
    </section>
  )
}

function AssignmentPanel({ persona, cohorts, pending, dirty, onAssign, onRemove }: {
  persona: AdminPersonaDetail
  cohorts: AdminPersonaAssignableCohort[]
  pending: boolean
  dirty: boolean
  onAssign: (cohort: AdminPersonaAssignableCohort) => void
  onRemove: (cohort: AdminPersonaAssignableCohort) => void
}) {
  return (
    <article className="panel coach-assignments">
      <header><div><p className="eyebrow">Cohort assignments</p><h3>Choose where the published voice is active.</h3><p>Each cohort has one effective persona. Replacing one updates future assistant messages while preserving immutable message attribution.</p></div><span>{persona.assignments.length} visible assignment{persona.assignments.length === 1 ? '' : 's'}</span></header>
      {!persona.published_version ? (
        <p className="coach-empty">Publish the first version before assigning this assistant to a cohort.</p>
      ) : cohorts.length === 0 ? (
        <p className="coach-empty">No manageable cohorts are available.</p>
      ) : (
        <div className="coach-cohort-list">
          {cohorts.map((cohort) => {
            const assignedHere = cohort.persona_assignment?.persona.id === persona.id
            return (
              <article key={cohort.id}>
                <div><strong>{cohort.name}</strong><small>{titleize(cohort.status)} · {cohort.persona_assignment ? `${cohort.persona_assignment.persona.name} assigned` : 'Neutral product voice'}</small>{cohort.blocked_reason && <small>{cohort.blocked_reason}</small>}</div>
                {assignedHere
                  ? <Button size="compact" variant="ghost" disabled={dirty || pending || !cohort.assignable} onClick={() => onRemove(cohort)}>Remove</Button>
                  : <Button size="compact" disabled={dirty || pending || !cohort.assignable || !persona.permissions.assign} onClick={() => onAssign(cohort)}>{cohort.persona_assignment ? 'Replace assignment' : 'Assign'}</Button>}
              </article>
            )
          })}
        </div>
      )}
      {dirty && <p className="coach-inline-note">Save or discard this draft before changing cohort assignments.</p>}
    </article>
  )
}

function PhraseEditor({ draft, mutate, access }: { draft: PersonaConfiguration; mutate: (mutator: (current: PersonaConfiguration) => PersonaConfiguration) => void; access: AdminPersonaDetail['phrase_artifact_access'] }) {
  const phrases = draft.phrases
  const capabilities = new Map((access?.artifacts ?? []).map((artifact) => [artifact.artifact_id, artifact]))
  const canAdd = access?.can_add === true
  return (
    <section className="coach-array-editor">
      <header><div><strong>Approved phrases</strong><small>Meaning and context are required. Crisis use should normally stay prohibited.</small></div><Button type="button" size="compact" variant="secondary" disabled={!canAdd || phrases.length >= PERSONA_LIST_LIMITS.phrases} onClick={() => mutate((current) => ({ ...current, phrases: appendListItem(current.phrases, { text: 'New phrase', meaning: 'Coach-approved meaning and intent.', allowed_contexts: ['general'], prohibited_contexts: ['crisis'], frequency: 'rare', caution: '' }, PERSONA_LIST_LIMITS.phrases) }))}>Add phrase</Button></header>
      {!canAdd && <p className="coach-phrase-access-note" role="note">Only the owning coach can add or change approved phrases.</p>}
      {phrases.length === 0 && <p>No phrases added. Locale alone will never create them.</p>}
      {phrases.map((phrase, index) => {
        const capability = phrase.artifact_id ? capabilities.get(phrase.artifact_id) : undefined
        const isNew = !phrase.artifact_id
        const canEdit = isNew ? canAdd : capability?.can_edit === true
        const canMove = isNew ? canAdd : capability?.can_move === true
        const canRemove = isNew ? canAdd : capability?.can_remove === true
        const sourceLabel = isNew ? 'New coach-authored phrase' : capability?.source_label ?? 'Sealed phrase'
        const lockedReason = capability?.locked_reason
        return (
          <article key={phrase.artifact_id ?? `new-${index}`}>
            <div className="coach-array-row-heading"><div><strong>Phrase {index + 1}</strong><p className="coach-phrase-provenance"><span>{sourceLabel}</span>{!canEdit && <span aria-label="Locked phrase">Locked</span>}</p></div><ArrayActions label={`phrase ${index + 1}`} index={index} count={phrases.length} canMove={canMove} canRemove={canRemove} onMove={(direction) => mutate((current) => ({ ...current, phrases: moveItem(current.phrases, index, direction) }))} onRemove={() => mutate((current) => ({ ...current, phrases: current.phrases.filter((_, itemIndex) => itemIndex !== index) }))} /></div>
            {lockedReason && <p className="coach-phrase-access-note" role="note">{lockedReason}</p>}
            <TextInput label="Phrase" value={phrase.text} maxLength={100} disabled={!canEdit} onChange={(value) => mutate((current) => ({ ...current, phrases: replaceAt(current.phrases, index, { ...current.phrases[index], text: value }) }))} />
            <TextArea label="Meaning and intent" value={phrase.meaning} maxLength={300} rows={2} disabled={!canEdit} onChange={(value) => mutate((current) => ({ ...current, phrases: replaceAt(current.phrases, index, { ...current.phrases[index], meaning: value }) }))} />
            <label><span>Frequency</span><select value={phrase.frequency} disabled={!canEdit} onChange={(event) => mutate((current) => ({ ...current, phrases: replaceAt(current.phrases, index, { ...current.phrases[index], frequency: event.target.value as typeof phrase.frequency }) }))}><option value="very_rare">Very rare</option><option value="rare">Rare</option><option value="sparing">Sparing</option><option value="as_needed">As needed</option></select></label>
            <TextArea label="Caution" value={phrase.caution} maxLength={300} rows={2} disabled={!canEdit} onChange={(value) => mutate((current) => ({ ...current, phrases: replaceAt(current.phrases, index, { ...current.phrases[index], caution: value }) }))} />
            <ContextChecks label="Allowed contexts" selected={phrase.allowed_contexts} disabled={!canEdit} onChange={(values) => mutate((current) => ({ ...current, phrases: replaceAt(current.phrases, index, { ...current.phrases[index], allowed_contexts: values }) }))} />
            <ContextChecks label="Prohibited contexts" selected={phrase.prohibited_contexts} disabled={!canEdit} onChange={(values) => mutate((current) => ({ ...current, phrases: replaceAt(current.phrases, index, { ...current.phrases[index], prohibited_contexts: values }) }))} />
          </article>
        )
      })}
    </section>
  )
}

function GuidanceEditor({ draft, mutate }: { draft: PersonaConfiguration; mutate: (mutator: (current: PersonaConfiguration) => PersonaConfiguration) => void }) {
  const items = draft.curriculum.guidance
  return <StructuredEditor title="Approved guidance" addLabel="Add guidance" count={items.length} max={PERSONA_LIST_LIMITS.guidance} onAdd={() => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, guidance: appendListItem(current.curriculum.guidance, { title: 'New guidance', content: 'Add the coach-approved teaching here.' }, PERSONA_LIST_LIMITS.guidance) } }))}>{items.map((item, index) => <article key={index}><div className="coach-array-row-heading"><strong>Guidance {index + 1}</strong><ArrayActions label={`guidance ${index + 1}`} index={index} count={items.length} onMove={(direction) => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, guidance: moveItem(current.curriculum.guidance, index, direction) } }))} onRemove={() => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, guidance: current.curriculum.guidance.filter((_, itemIndex) => itemIndex !== index) } }))} /></div><TextInput label="Title" value={item.title} maxLength={140} onChange={(value) => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, guidance: replaceAt(current.curriculum.guidance, index, { ...current.curriculum.guidance[index], title: value }) } }))} /><TextArea label="Content" value={item.content} maxLength={1200} rows={4} onChange={(value) => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, guidance: replaceAt(current.curriculum.guidance, index, { ...current.curriculum.guidance[index], content: value }) } }))} /></article>)}</StructuredEditor>
}

function ScriptEditor({ draft, mutate }: { draft: PersonaConfiguration; mutate: (mutator: (current: PersonaConfiguration) => PersonaConfiguration) => void }) {
  const items = draft.curriculum.scripts
  return <StructuredEditor title="Coaching scripts" addLabel="Add script" count={items.length} max={PERSONA_LIST_LIMITS.scripts} onAdd={() => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, scripts: appendListItem(current.curriculum.scripts, { title: 'New script', steps: ['Add the first coach-approved step.'] }, PERSONA_LIST_LIMITS.scripts) } }))}>{items.map((item, index) => <article key={index}><div className="coach-array-row-heading"><strong>Script {index + 1}</strong><ArrayActions label={`script ${index + 1}`} index={index} count={items.length} onMove={(direction) => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, scripts: moveItem(current.curriculum.scripts, index, direction) } }))} onRemove={() => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, scripts: current.curriculum.scripts.filter((_, itemIndex) => itemIndex !== index) } }))} /></div><TextInput label="Title" value={item.title} maxLength={140} onChange={(value) => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, scripts: replaceAt(current.curriculum.scripts, index, { ...current.curriculum.scripts[index], title: value }) } }))} /><LineList label="Steps" values={item.steps} minItems={1} maxItems={12} itemMaxLength={500} onChange={(values) => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, scripts: replaceAt(current.curriculum.scripts, index, { ...current.curriculum.scripts[index], steps: values }) } }))} /></article>)}</StructuredEditor>
}

function ExampleEditor({ draft, mutate }: { draft: PersonaConfiguration; mutate: (mutator: (current: PersonaConfiguration) => PersonaConfiguration) => void }) {
  const items = draft.curriculum.examples
  return <StructuredEditor title="Example conversations" addLabel="Add example" count={items.length} max={PERSONA_LIST_LIMITS.examples} onAdd={() => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, examples: appendListItem(current.curriculum.examples, { participant: 'Participant question', assistant: 'Coach-approved example answer.' }, PERSONA_LIST_LIMITS.examples) } }))}>{items.map((item, index) => <article key={index}><div className="coach-array-row-heading"><strong>Example {index + 1}</strong><ArrayActions label={`example ${index + 1}`} index={index} count={items.length} onMove={(direction) => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, examples: moveItem(current.curriculum.examples, index, direction) } }))} onRemove={() => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, examples: current.curriculum.examples.filter((_, itemIndex) => itemIndex !== index) } }))} /></div><TextArea label="Participant" value={item.participant} maxLength={600} rows={3} onChange={(value) => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, examples: replaceAt(current.curriculum.examples, index, { ...current.curriculum.examples[index], participant: value }) } }))} /><TextArea label="Assistant" value={item.assistant} maxLength={1200} rows={4} onChange={(value) => mutate((current) => ({ ...current, curriculum: { ...current.curriculum, examples: replaceAt(current.curriculum.examples, index, { ...current.curriculum.examples[index], assistant: value }) } }))} /></article>)}</StructuredEditor>
}

function StructuredEditor({ title, addLabel, count, max, onAdd, children }: { title: string; addLabel: string; count: number; max: number; onAdd: () => void; children: ReactNode }) {
  return <section className="coach-array-editor"><header><div><strong>{title}</strong><small>{count} of {max}</small></div><Button type="button" size="compact" variant="secondary" disabled={count >= max} onClick={onAdd}>{addLabel}</Button></header>{count === 0 ? <p>Nothing added yet.</p> : children}</section>
}

function EditorFieldset({ legend, copy, children }: { legend: string; copy: string; children: ReactNode }) {
  return <fieldset className="coach-fieldset"><legend>{legend}</legend><p>{copy}</p><div className="coach-field-grid">{children}</div></fieldset>
}

function TextInput({ label, value, onChange, maxLength, help, disabled = false }: { label: string; value: string; onChange: (value: string) => void; maxLength?: number; help?: string; disabled?: boolean }) {
  return <label><span>{label}</span><input value={value} maxLength={maxLength} disabled={disabled} onChange={(event) => onChange(event.target.value)} />{help && <small>{help}</small>}</label>
}

function TextArea({ label, value, onChange, rows, maxLength, help, disabled = false }: { label: string; value: string; onChange: (value: string) => void; rows: number; maxLength?: number; help?: string; disabled?: boolean }) {
  return <label className="is-wide"><span>{label}</span><textarea value={value} rows={rows} maxLength={maxLength} disabled={disabled} onChange={(event) => onChange(event.target.value)} />{help && <small>{help}</small>}</label>
}

function ChoiceChips<Option extends string>({ label, options, selected, onChange, minimum = 0 }: { label: string; options: readonly Option[]; selected: readonly Option[]; onChange: (values: Option[]) => void; minimum?: number }) {
  const toggle = (option: Option, checked: boolean) => {
    if (checked) onChange([...selected.filter((value) => value !== option), option])
    else if (selected.length > minimum) onChange(selected.filter((value) => value !== option))
  }
  return <fieldset className="coach-choice-field is-wide"><legend>{label}</legend><div>{options.map((option) => <label key={option}><input type="checkbox" checked={selected.includes(option)} disabled={selected.includes(option) && selected.length <= minimum} onChange={(event) => toggle(option, event.target.checked)} /><span>{option.includes(' ') ? option : titleize(option)}</span></label>)}</div><small>Choose {minimum === 1 ? 'at least one reviewed option' : 'reviewed options'}.</small></fieldset>
}

function SelectChoice<Option extends string>({ label, options, value, onChange }: { label: string; options: readonly Option[]; value: Option; onChange: (value: Option) => void }) {
  return <label className="coach-select-choice"><span>{label}</span><select value={value} onChange={(event) => onChange(event.target.value as Option)}>{options.map((option) => <option key={option} value={option}>{option}</option>)}</select></label>
}

function LineList({ label, values, onChange, minItems = 0, maxItems, itemMaxLength, help }: { label: string; values: string[]; onChange: (values: string[]) => void; minItems?: number; maxItems: number; itemMaxLength: number; help?: string }) {
  const updateLines = (rawValue: string) => {
    const lines = rawValue.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n').slice(0, maxItems)
    onChange(lines.map((line) => line.slice(0, itemMaxLength)))
  }
  const normalizeLines = () => {
    onChange(lineListToArray(arrayToLineList(values)).slice(0, maxItems))
  }
  return <label className="is-wide"><span>{label}</span><textarea rows={Math.max(3, Math.min(values.length + 1, 7))} value={arrayToLineList(values)} onChange={(event) => updateLines(event.target.value)} onBlur={normalizeLines} /> <small>{help ?? `One item per line. ${minItems ? `At least ${minItems}; ` : ''}up to ${maxItems}, ${itemMaxLength} characters each.`}</small></label>
}

function NumberInput({ label, value, onChange, min, max }: { label: string; value: number; onChange: (value: number) => void; min: number; max: number }) {
  return <label><span>{label}</span><input type="number" inputMode="numeric" min={min} max={max} value={value} onChange={(event) => onChange(Number(event.target.value))} /></label>
}

function CheckField({ label, checked, onChange }: { label: string; checked: boolean; onChange: (checked: boolean) => void }) {
  return <label className="coach-check"><input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} /><span>{label}</span></label>
}

function ContextChecks({ label, selected, onChange, disabled = false }: { label: string; selected: string[]; onChange: (values: typeof PERSONA_PHRASE_CONTEXTS[number][]) => void; disabled?: boolean }) {
  return <fieldset className="coach-context-checks" disabled={disabled}><legend>{label}</legend>{PERSONA_PHRASE_CONTEXTS.map((context) => <label key={context}><input type="checkbox" checked={selected.includes(context)} onChange={(event) => onChange(event.target.checked ? [...selected.filter((value) => value !== context), context] as typeof PERSONA_PHRASE_CONTEXTS[number][] : selected.filter((value) => value !== context) as typeof PERSONA_PHRASE_CONTEXTS[number][])} /><span>{titleize(context)}</span></label>)}</fieldset>
}

function ArrayActions({ label, index, count, onMove, onRemove, canMove = true, canRemove = true }: { label: string; index: number; count: number; onMove: (direction: -1 | 1) => void; onRemove: () => void; canMove?: boolean; canRemove?: boolean }) {
  return <div className="coach-array-actions"><button type="button" aria-label={`Move ${label} up`} disabled={!canMove || index === 0} onClick={() => onMove(-1)}>↑</button><button type="button" aria-label={`Move ${label} down`} disabled={!canMove || index === count - 1} onClick={() => onMove(1)}>↓</button><button type="button" aria-label={`Remove ${label}`} disabled={!canRemove} onClick={onRemove}>Remove</button></div>
}

function StatusBadge({ status }: { status: string }) {
  const tone = status.includes('published') || status.includes('current') || status.includes('previewed') ? 'is-green' : status.includes('archived') || status.includes('outdated') ? 'is-red' : 'is-gold'
  return <span className={`coach-status ${tone}`}>{titleize(status)}</span>
}

function ShieldIcon() {
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3 5 6v5c0 4.6 2.8 8 7 10 4.2-2 7-5.4 7-10V6l-7-3Zm-1 12-3-3 1.4-1.4L11 12.2l3.6-3.6L16 10l-5 5Z" /></svg>
}

function replacePersonaSummary(current: AdminPersonaSummary[], persona: AdminPersonaDetail) {
  const summary: AdminPersonaSummary = persona
  return current.some((item) => item.id === persona.id)
    ? current.map((item) => item.id === persona.id ? summary : item)
    : [summary, ...current]
}

function moveItem<T>(items: T[], index: number, direction: -1 | 1) {
  return moveListItem(items, index, index + direction)
}

function errorMessage(caught: unknown, fallback: string) {
  return caught instanceof Error ? caught.message : fallback
}

function titleize(value: string) {
  return value.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase())
}
