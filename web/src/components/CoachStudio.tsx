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
import {
  PERSONA_LIST_LIMITS,
  PERSONA_PHRASE_CONTEXTS,
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

export function CoachStudio({ currentUser, onDirtyChange }: { currentUser: CurrentUser; onDirtyChange: (dirty: boolean) => void }) {
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
  const loadPersonaRequestRef = useRef(0)
  const focusEditorAfterLoadRef = useRef(false)
  const createNameRef = useRef<HTMLInputElement | null>(null)
  const libraryHeadingRef = useRef<HTMLHeadingElement | null>(null)
  const editorHeadingRef = useRef<HTMLHeadingElement | null>(null)

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
    loadPersonaRequestRef.current = requestId
    setDetailLoading(true)
    setError(null)
    try {
      const persona = await fetchAdminPersona(personaId)
      if (requestId !== loadPersonaRequestRef.current) return
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
      if (requestId !== loadPersonaRequestRef.current) return
      setError(errorMessage(caught, 'This assistant could not be loaded.'))
    } finally {
      if (requestId === loadPersonaRequestRef.current) setDetailLoading(false)
    }
  }, [])

  const loadPersonas = useCallback(async (preferredId?: number | null) => {
    setLoading(true)
    setError(null)
    try {
      const [nextPersonas, nextCohorts] = await Promise.all([
        fetchAdminPersonas(),
        fetchAdminPersonaAssignableCohorts(),
      ])
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
      setError(errorMessage(caught, 'Coach Studio could not load.'))
    } finally {
      setLoading(false)
    }
  }, [loadPersona])

  useEffect(() => {
    queueMicrotask(() => void loadPersonas())
  }, [loadPersonas])

  useEffect(() => {
    if (createOpen) window.requestAnimationFrame(() => createNameRef.current?.focus())
  }, [createOpen])

  useEffect(() => {
    onDirtyChange(studioDirty)
  }, [studioDirty, onDirtyChange])

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

  async function handleCreate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!createName.trim() || pendingAction) return
    setPendingAction('create')
    setError(null)
    try {
      const persona = await createAdminPersona({ name: createName.trim(), description: createDescription.trim() })
      setCreateOpen(false)
      setCreateName('')
      setCreateDescription('')
      setNotice(`${persona.name} is ready to shape.`)
      await loadPersonas(persona.id)
    } catch (caught) {
      setError(errorMessage(caught, 'The assistant draft could not be created.'))
    } finally {
      setPendingAction(null)
    }
  }

  async function saveDraft() {
    if (!selectedPersona || !draft || !selectedPersona.permissions.edit || pendingAction) return null
    setPendingAction('save')
    setError(null)
    setConflict(null)
    try {
      const persona = await updateAdminPersona(selectedPersona.id, {
        draft_revision: selectedPersona.draft_revision ?? 0,
        description,
        draft_config: draft,
      })
      setSelectedPersona(persona)
      setDraft(persona.draft ?? draft)
      setDescription(persona.description)
      setPreview(null)
      setPersonas((current) => replacePersonaSummary(current, persona))
      setNotice('Draft saved. Run an exact preview before publishing.')
      return persona
    } catch (caught) {
      handleMutationError(caught, 'The draft could not be saved.')
      return null
    } finally {
      setPendingAction(null)
    }
  }

  async function handlePreview() {
    if (!selectedPersona || !draft || dirty || pendingAction) return
    setPendingAction('preview')
    setError(null)
    setConflict(null)
    try {
      const response = await previewAdminPersona(selectedPersona.id, selectedPersona.draft_revision ?? 0, samplePrompt.trim() || undefined)
      setSelectedPersona(response.persona)
      setDraft(response.persona.draft ?? draft)
      setPreview(response.preview)
      setPersonas((current) => replacePersonaSummary(current, response.persona))
      setNotice(response.preview.status === 'ready' ? 'Exact draft preview is ready for review.' : 'The exact draft was checked, but a behavioral sample is unavailable right now.')
    } catch (caught) {
      handleMutationError(caught, 'The exact draft preview could not run.')
    } finally {
      setPendingAction(null)
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
    setPendingAction('publish')
    setError(null)
    setConflict(null)
    try {
      const response = await publishAdminPersona(selectedPersona.id, {
        draft_revision: selectedPersona.draft_revision ?? 0,
        preview_digest: preview.digest,
        expected_published_version_id: selectedPersona.published_version?.id ?? null,
      })
      setSelectedPersona(response.persona)
      setDraft(response.persona.draft ?? draft)
      setPersonas((current) => replacePersonaSummary(current, response.persona))
      setNotice(`${response.persona.name} version ${response.published_version.number} is published.`)
      await refreshCohorts()
    } catch (caught) {
      setPreview(null)
      handleMutationError(caught, 'The assistant could not be published.')
    } finally {
      setPendingAction(null)
    }
  }

  async function handleArchive() {
    if (!selectedPersona || pendingAction) return
    if (dirty) {
      setConflict('Save or discard your unsaved changes before archiving this assistant.')
      return
    }
    if (!window.confirm(`Archive ${selectedPersona.name}? Its published history will remain available.`)) return
    setPendingAction('archive')
    setError(null)
    try {
      const persona = await archiveAdminPersona(selectedPersona.id)
      acceptPersona(persona)
      setNotice(`${persona.name} is archived.`)
    } catch (caught) {
      handleMutationError(caught, 'The assistant could not be archived.')
    } finally {
      setPendingAction(null)
    }
  }

  async function handleRestore() {
    if (!selectedPersona || pendingAction) return
    setPendingAction('restore')
    setError(null)
    try {
      const persona = await restoreAdminPersona(selectedPersona.id)
      acceptPersona(persona)
      setNotice(`${persona.name} is restored as an editable draft.`)
    } catch (caught) {
      handleMutationError(caught, 'The assistant could not be restored.')
    } finally {
      setPendingAction(null)
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
    setPendingAction('rollback')
    setError(null)
    try {
      const response = await rollbackAdminPersonaVersion(selectedPersona.id, versionId, {
        expected_published_version_id: selectedPersona.published_version?.id ?? null,
        draft_revision: selectedPersona.draft_revision ?? 0,
      })
      acceptPersona(response.persona)
      setPreview(null)
      setNotice(`Version ${response.published_version.number} is now published from version ${versionNumber}.`)
      await refreshCohorts()
    } catch (caught) {
      handleMutationError(caught, 'The version could not be restored.')
    } finally {
      setPendingAction(null)
    }
  }

  async function handleAssignment(cohort: AdminPersonaAssignableCohort) {
    if (!selectedPersona?.published_version || pendingAction || !cohort.assignable) return
    if (dirty) {
      setConflict('Save or discard your unsaved changes before changing cohort assignments.')
      return
    }
    setPendingAction('assignment')
    setError(null)
    try {
      await updateAdminCohortPersonaAssignment(
        cohort.id,
        selectedPersona.id,
        cohort.persona_assignment?.persona.id ?? null,
      )
      await Promise.all([refreshCohorts(), loadPersona(selectedPersona.id)])
      setNotice(`${selectedPersona.name} is assigned to ${cohort.name}.`)
    } catch (caught) {
      handleMutationError(caught, 'The cohort assignment could not be changed.')
      await refreshCohorts()
    } finally {
      setPendingAction(null)
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
    setPendingAction('assignment')
    setError(null)
    try {
      await deleteAdminCohortPersonaAssignment(cohort.id, assignedPersonaId)
      await Promise.all([refreshCohorts(), loadPersona(selectedPersona.id)])
      setNotice(`The coaching assistant was removed from ${cohort.name}.`)
    } catch (caught) {
      handleMutationError(caught, 'The cohort assignment could not be removed.')
      await refreshCohorts()
    } finally {
      setPendingAction(null)
    }
  }

  async function refreshCohorts() {
    try {
      setCohorts(await fetchAdminPersonaAssignableCohorts())
    } catch (caught) {
      setError(errorMessage(caught, 'Cohort assignments could not be refreshed.'))
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
        <p>Build the voice from the coach's own teaching, preview the exact draft, then publish and assign it to a cohort. Location provides context only; the system never invents an accent, slang, or cultural assumptions.</p>
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
          <CoachContentLibrary currentUser={currentUser} onDirtyChange={setLibraryDirty} />
        </div>
      ) : studioSection === 'participant_tools' ? (
        <div className="coach-studio-tab-panel" role="tabpanel" id="coach-studio-panel-participant-tools" aria-labelledby="coach-studio-tab-participant-tools" tabIndex={0}>
          <CohortExperienceStudio cohorts={cohorts} cohortsLoading={loading} onDirtyChange={setExperienceDirty} />
        </div>
      ) : <div className="coach-studio-tab-panel" role="tabpanel" id="coach-studio-panel-assistants" aria-labelledby="coach-studio-tab-assistants" tabIndex={0}>

      {error && <div className="coach-studio-alert is-error" role="alert"><span>{error}</span><button type="button" onClick={() => { setError(null); void loadPersonas(selectedPersona?.id) }}>Retry</button></div>}
      {notice && <p className="coach-studio-alert is-success" role="status">{notice}</p>}
      {conflict && (
        <div className="coach-studio-alert is-conflict" role="alert">
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
            <Button size="compact" onClick={() => setCreateOpen(true)}>Create</Button>
          </div>

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
              <Button onClick={() => setCreateOpen(true)}>Create coaching assistant</Button>
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

function PersonaEditor({
  draft,
  description,
  mode,
  guidedStep,
  onStepChange,
  onDescriptionChange,
  onChange,
  mutate,
}: {
  draft: PersonaConfiguration
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
            {renderEditorSection(guidedStep, draft, onChange, mutate, description, onDescriptionChange)}
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
              <div>{renderEditorSection(step.id, draft, onChange, mutate, description, onDescriptionChange)}</div>
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
      <EditorFieldset legend="How should it sound?" copy="Describe the coach's real communication style. The system applies these instructions without copying an accent or inventing slang.">
        <LineList label="Tone traits" values={draft.voice.tone_traits} minItems={1} maxItems={12} itemMaxLength={80} help="One trait per line, such as warm, direct, grounded." onChange={(values) => onChange({ ...draft, voice: { ...draft.voice, tone_traits: values } })} />
        <TextInput label="Energy" value={draft.voice.energy} maxLength={160} onChange={(value) => onChange({ ...draft, voice: { ...draft.voice, energy: value } })} />
        <TextArea label="Accountability style" value={draft.voice.accountability_style} maxLength={400} rows={3} onChange={(value) => onChange({ ...draft, voice: { ...draft.voice, accountability_style: value } })} />
        <LineList label="Language style" values={draft.voice.language_style} minItems={1} maxItems={8} itemMaxLength={220} help="One approved instruction per line." onChange={(values) => onChange({ ...draft, voice: { ...draft.voice, language_style: values } })} />
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
        <LineList label="Do not" values={draft.coaching.do_not} maxItems={16} itemMaxLength={400} help="Optional boundaries, one per line. Unsafe instructions are rejected even here." onChange={(values) => onChange({ ...draft, coaching: { ...draft.coaching, do_not: values } })} />
      </EditorFieldset>
    )
  }

  if (step === 'culture') {
    return (
      <EditorFieldset legend="What community context has the coach approved?" copy="Locale is a label for context. It never generates dialect, accent, slang, values, or stereotypes. Add only language and realities the coach has explicitly authored.">
        <div className="coach-culture-boundary" role="note"><strong>Coach authored only.</strong> Choosing Guam, the South, or another place does not add phrases automatically.</div>
        <TextInput label="Locale label" value={draft.culture.locale_label} maxLength={120} help="For example: Guam families in Mrs. Mel's first cohort, or No locale selected." onChange={(value) => onChange({ ...draft, culture: { ...draft.culture, locale_label: value } })} />
        <TextArea label="Cultural and community context" value={draft.culture.context} maxLength={1000} rows={5} onChange={(value) => onChange({ ...draft, culture: { ...draft.culture, context: value } })} />
        <LineList label="Local realities" values={draft.culture.local_realities} maxItems={16} itemMaxLength={300} help="One verified reality per line, such as shipping costs or multigenerational obligations." onChange={(values) => onChange({ ...draft, culture: { ...draft.culture, local_realities: values } })} />
        <LineList label="Approved references" values={draft.culture.references} maxItems={16} itemMaxLength={300} help="Coach authored examples, programs, or community references." onChange={(values) => onChange({ ...draft, culture: { ...draft.culture, references: values } })} />
        <PhraseEditor draft={draft} mutate={mutate} />
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

function PhraseEditor({ draft, mutate }: { draft: PersonaConfiguration; mutate: (mutator: (current: PersonaConfiguration) => PersonaConfiguration) => void }) {
  const phrases = draft.phrases
  return (
    <section className="coach-array-editor">
      <header><div><strong>Approved phrases</strong><small>Meaning and context are required. Crisis use should normally stay prohibited.</small></div><Button type="button" size="compact" variant="secondary" disabled={phrases.length >= PERSONA_LIST_LIMITS.phrases} onClick={() => mutate((current) => ({ ...current, phrases: appendListItem(current.phrases, { text: 'New phrase', meaning: 'Coach-approved meaning and intent.', allowed_contexts: ['general'], prohibited_contexts: ['crisis'], frequency: 'rare', caution: '' }, PERSONA_LIST_LIMITS.phrases) }))}>Add phrase</Button></header>
      {phrases.length === 0 && <p>No phrases added. Locale alone will never create them.</p>}
      {phrases.map((phrase, index) => (
        <article key={index}>
          <div className="coach-array-row-heading"><strong>Phrase {index + 1}</strong><ArrayActions label={`phrase ${index + 1}`} index={index} count={phrases.length} onMove={(direction) => mutate((current) => ({ ...current, phrases: moveItem(current.phrases, index, direction) }))} onRemove={() => mutate((current) => ({ ...current, phrases: current.phrases.filter((_, itemIndex) => itemIndex !== index) }))} /></div>
          <TextInput label="Phrase" value={phrase.text} maxLength={100} onChange={(value) => mutate((current) => ({ ...current, phrases: replaceAt(current.phrases, index, { ...current.phrases[index], text: value }) }))} />
          <TextArea label="Meaning and intent" value={phrase.meaning} maxLength={300} rows={2} onChange={(value) => mutate((current) => ({ ...current, phrases: replaceAt(current.phrases, index, { ...current.phrases[index], meaning: value }) }))} />
          <label><span>Frequency</span><select value={phrase.frequency} onChange={(event) => mutate((current) => ({ ...current, phrases: replaceAt(current.phrases, index, { ...current.phrases[index], frequency: event.target.value as typeof phrase.frequency }) }))}><option value="very_rare">Very rare</option><option value="rare">Rare</option><option value="sparing">Sparing</option><option value="as_needed">As needed</option></select></label>
          <TextArea label="Caution" value={phrase.caution} maxLength={300} rows={2} onChange={(value) => mutate((current) => ({ ...current, phrases: replaceAt(current.phrases, index, { ...current.phrases[index], caution: value }) }))} />
          <ContextChecks label="Allowed contexts" selected={phrase.allowed_contexts} onChange={(values) => mutate((current) => ({ ...current, phrases: replaceAt(current.phrases, index, { ...current.phrases[index], allowed_contexts: values }) }))} />
          <ContextChecks label="Prohibited contexts" selected={phrase.prohibited_contexts} onChange={(values) => mutate((current) => ({ ...current, phrases: replaceAt(current.phrases, index, { ...current.phrases[index], prohibited_contexts: values }) }))} />
        </article>
      ))}
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

function TextInput({ label, value, onChange, maxLength, help }: { label: string; value: string; onChange: (value: string) => void; maxLength?: number; help?: string }) {
  return <label><span>{label}</span><input value={value} maxLength={maxLength} onChange={(event) => onChange(event.target.value)} />{help && <small>{help}</small>}</label>
}

function TextArea({ label, value, onChange, rows, maxLength, help }: { label: string; value: string; onChange: (value: string) => void; rows: number; maxLength?: number; help?: string }) {
  return <label className="is-wide"><span>{label}</span><textarea value={value} rows={rows} maxLength={maxLength} onChange={(event) => onChange(event.target.value)} />{help && <small>{help}</small>}</label>
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

function ContextChecks({ label, selected, onChange }: { label: string; selected: string[]; onChange: (values: typeof PERSONA_PHRASE_CONTEXTS[number][]) => void }) {
  return <fieldset className="coach-context-checks"><legend>{label}</legend>{PERSONA_PHRASE_CONTEXTS.map((context) => <label key={context}><input type="checkbox" checked={selected.includes(context)} onChange={(event) => onChange(event.target.checked ? [...selected.filter((value) => value !== context), context] as typeof PERSONA_PHRASE_CONTEXTS[number][] : selected.filter((value) => value !== context) as typeof PERSONA_PHRASE_CONTEXTS[number][])} /><span>{titleize(context)}</span></label>)}</fieldset>
}

function ArrayActions({ label, index, count, onMove, onRemove }: { label: string; index: number; count: number; onMove: (direction: -1 | 1) => void; onRemove: () => void }) {
  return <div className="coach-array-actions"><button type="button" aria-label={`Move ${label} up`} disabled={index === 0} onClick={() => onMove(-1)}>↑</button><button type="button" aria-label={`Move ${label} down`} disabled={index === count - 1} onClick={() => onMove(1)}>↓</button><button type="button" aria-label={`Remove ${label}`} onClick={onRemove}>Remove</button></div>
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
