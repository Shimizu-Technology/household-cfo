import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { partitionParticipantSections, participantSectionsForModules } from '../lib/participantNavigation'
import {
  ApiRequestError,
  fetchCohortExperienceConfiguration,
  previewCohortExperienceConfiguration,
  publishCohortExperienceConfiguration,
  rollbackCohortExperienceConfiguration,
  updateCohortExperienceConfiguration,
} from '../api'
import type {
  AdminPersonaAssignableCohort,
  CohortExperienceConfiguration,
  ConfigurableCohortExperienceDraft,
  CohortExperienceDraft,
  CohortExperiencePreview,
  ExperienceMode,
  ExperienceModuleId,
} from '../api'
import { Button } from './Button'
import './ProgramSettingsFlow.css'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'
import { confirmAction, confirmDiscard } from '../lib/confirmAction'

const coreModules = [
  ['Home', 'See the household status and next action.'],
  ['Ask Mia', 'Use the supervised coaching assistant.'],
] as const

const optionalModules = [
  ['review', 'Review', 'Approve activity before it changes actuals.'],
  ['budget', 'Budget', 'Review and edit the approved plan.'],
  ['profile', 'My Profile', 'Manage household details and preferences.'],
  ['statements', 'Statements', 'Upload and review private statements and files.'],
  ['wealth', 'Wealth', 'See debt, assets, runway, and long-range capacity.'],
  ['cfo_filter', 'CFO Filter', 'Pressure-test a purchase before money moves.'],
  ['optionality', 'Optionality', 'Compare choices against stability and runway.'],
] as const
const defaultModuleOrder: ExperienceModuleId[] = ['home', 'review', 'ask_mia', 'budget', 'profile', 'wealth', 'cfo_filter', 'optionality', 'statements']
const moduleLabels = { home: 'Home', ask_mia: 'Ask Mia', ...Object.fromEntries(optionalModules.map(([id, label]) => [id, label])) } as Record<ExperienceModuleId, string>

function configurableDraft(draft: CohortExperienceDraft): ConfigurableCohortExperienceDraft {
  if (draft.schema_version === 4) return draft
  return { schema_version: 4, experience_mode: experienceModeOf(draft), module_order: [], optional_modules: {
    review: true, budget: true, profile: true, statements: true, wealth: true, ...draft.optional_modules,
  } }
}

function moduleOrder(draft: CohortExperienceDraft) {
  return [...new Set([...(draft.module_order ?? []), ...defaultModuleOrder])]
}

function enabledModules(draft: CohortExperienceDraft) {
  const current = configurableDraft(draft)
  return moduleOrder(current).filter(id => id === 'home' || id === 'ask_mia' || current.optional_modules[id])
}

const experienceModes: Array<{ mode: ExperienceMode; title: string; description: string; detail: string }> = [
  {
    mode: 'household_cfo',
    title: 'Household CFO',
    description: 'The everyday coaching experience: plan, review, ask Mia, and grow.',
    detail: 'Home, Review, Ask Mia, Budget, My Profile and Wealth, plus any optional tools you turn on.',
  },
  {
    mode: 'savings_challenge',
    title: '90-day Savings Challenge',
    description: 'A guided challenge: join, set a comfortable target, and record money set aside.',
    detail: 'Participants land on Savings with Today check-ins, Ask Mia and Statements. Review becomes Transactions.',
  },
]

function experienceModeOf(draft: { experience_mode?: ExperienceMode }): ExperienceMode {
  return draft.experience_mode === 'savings_challenge' ? 'savings_challenge' : 'household_cfo'
}

// Mirrors the labels ParticipantTabs shows participants in each mode.
function navigationLabel(section: string, savingsChallenge: boolean) {
  if (savingsChallenge && section === 'Home') return 'Savings'
  if (savingsChallenge && section === 'Review') return 'Transactions'
  return section
}


type PendingAction = 'load' | 'save' | 'preview' | 'publish' | 'rollback' | null

export function CohortExperienceStudio({
  cohorts,
  simple = false,
  cohortsLoading,
  mutationLifecycle,
  onDirtyChange,
  selectedCohortId,
  onSelectedCohortIdChange,
}: {
  cohorts: AdminPersonaAssignableCohort[]
  simple?: boolean
  cohortsLoading: boolean
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  onDirtyChange: (dirty: boolean) => void
  selectedCohortId: number | null
  onSelectedCohortIdChange: (cohortId: number | null) => void
}) {
  const [configuration, setConfiguration] = useState<CohortExperienceConfiguration | null>(null)
  const [draft, setDraft] = useState<CohortExperienceDraft | null>(null)
  const [preview, setPreview] = useState<CohortExperiencePreview | null>(null)
  const [pendingAction, setPendingAction] = useState<PendingAction>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const loadRequestRef = useRef(0)
  const loadAbortControllerRef = useRef<AbortController | null>(null)

  const dirty = useMemo(() => Boolean(configuration && draft && JSON.stringify(configuration.draft) !== JSON.stringify(draft)), [configuration, draft])

  const closedGroup = Boolean(configuration && ['completed', 'archived'].includes(configuration.cohort.status))
  const previewMatches = Boolean(preview && configuration?.preview?.digest === preview.digest && configuration.draft_revision === preview.draft_revision)

  useEffect(() => onDirtyChange(dirty), [dirty, onDirtyChange])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])

  const prepareCohortSelection = useCallback((cohortId: number | null) => {
    loadRequestRef.current += 1
    loadAbortControllerRef.current?.abort()
    loadAbortControllerRef.current = null
    setConfiguration(null)
    setDraft(null)
    setPreview(null)
    setError(null)
    setNotice(null)
    setPendingAction(cohortId ? 'load' : null)
    onSelectedCohortIdChange(cohortId)
  }, [onSelectedCohortIdChange])

  useEffect(() => {
    if (selectedCohortId && cohorts.some((cohort) => cohort.id === selectedCohortId)) return

    const firstCohortId = cohorts[0]?.id ?? null
    queueMicrotask(() => prepareCohortSelection(firstCohortId))
  }, [cohorts, prepareCohortSelection, selectedCohortId])

  const loadConfiguration = useCallback(async (cohortId: number) => {
    const requestId = loadRequestRef.current + 1
    loadRequestRef.current = requestId
    loadAbortControllerRef.current?.abort()
    const abortController = new AbortController()
    loadAbortControllerRef.current = abortController
    setPendingAction('load')
    setError(null)
    setConfiguration(null)
    setDraft(null)
    setPreview(null)
    try {
      const next = await fetchCohortExperienceConfiguration(cohortId, abortController.signal)
      if (requestId !== loadRequestRef.current || abortController.signal.aborted) return
      if (next.cohort.id !== cohortId) throw new Error('Participant tools returned the wrong cohort. Reload and try again.')
      setConfiguration(next)
      setDraft(next.draft)
    } catch (caught) {
      if (requestId !== loadRequestRef.current || abortController.signal.aborted) return
      setError(errorMessage(caught, 'Participant tools could not be loaded.'))
    } finally {
      if (requestId === loadRequestRef.current) {
        loadAbortControllerRef.current = null
        setPendingAction(null)
      }
    }
  }, [])

  useEffect(() => () => {
    loadRequestRef.current += 1
    loadAbortControllerRef.current?.abort()
  }, [])

  useEffect(() => {
    if (selectedCohortId) queueMicrotask(() => void loadConfiguration(selectedCohortId))
  }, [loadConfiguration, selectedCohortId])

  async function chooseCohort(value: number) {
    if (value === selectedCohortId) return
    if (dirty && !(await confirmDiscard('Discard the unsaved participant-tool changes and open another cohort?'))) return
    prepareCohortSelection(value)
  }

  function chooseMode(mode: ExperienceMode) {
    setDraft((current) => {
      if (!current || experienceModeOf(current) === mode) return current
      if (current.schema_version === 4) return { ...current, experience_mode: mode }
      return mode === 'savings_challenge'
        ? { schema_version: 3, experience_mode: 'savings_challenge', optional_modules: { cfo_filter: false, optionality: false } }
        : { schema_version: 1, optional_modules: current.optional_modules }
    })
    setPreview(null)
    setNotice(null)
  }

  function toggleModule(key: typeof optionalModules[number][0]) {
    setDraft((current) => current ? {
      ...configurableDraft(current),
      optional_modules: { ...configurableDraft(current).optional_modules, [key]: !configurableDraft(current).optional_modules[key] },
    } : current)
    setPreview(null)
    setNotice(null)
  }

  function moveModule(id: ExperienceModuleId, direction: -1 | 1) {
    setDraft(current => {
      if (!current) return current
      const order = moduleOrder(current)
      const index = order.indexOf(id)
      const next = index + direction
      if (next < 0 || next >= order.length) return current
      ;[order[index], order[next]] = [order[next], order[index]]
      return { ...configurableDraft(current), module_order: order }
    })
    setPreview(null)
    setNotice(null)
  }

  function resetModuleOrder() {
    setDraft(current => current ? { ...configurableDraft(current), module_order: [] } : current)
    setPreview(null)
    setNotice(null)
  }

  async function saveDraft() {
    if (!configuration || !draft || pendingAction || !configuration.permissions.edit) return
    const ticket = mutationLifecycle.begin()
    setPendingAction('save')
    setError(null)
    try {
      const next = await updateCohortExperienceConfiguration(configuration.cohort.id, configuration.draft_revision, draft)
      if (!mutationLifecycle.isCurrent(ticket)) return
      setConfiguration(next)
      setDraft(next.draft)
      setPreview(null)
      setNotice('Participant-tools draft saved. Preview this exact draft before publishing.')
    } catch (caught) {
      if (mutationLifecycle.isCurrent(ticket)) setError(errorMessage(caught, 'The participant-tools draft could not be saved.'))
    } finally {
      if (mutationLifecycle.isCurrent(ticket)) setPendingAction(null)
      mutationLifecycle.finish(ticket)
    }
  }

  async function runPreview() {
    if (!configuration || dirty || pendingAction || !configuration.permissions.review) return
    const ticket = mutationLifecycle.begin()
    setPendingAction('preview')
    setError(null)
    try {
      const response = await previewCohortExperienceConfiguration(configuration.cohort.id, configuration.draft_revision)
      if (!mutationLifecycle.isCurrent(ticket)) return
      setConfiguration(response.experience_configuration)
      setDraft(response.experience_configuration.draft)
      setPreview(response.preview)
      setNotice('Exact participant navigation preview is ready.')
    } catch (caught) {
      if (mutationLifecycle.isCurrent(ticket)) setError(errorMessage(caught, 'The participant-tools preview could not run.'))
    } finally {
      if (mutationLifecycle.isCurrent(ticket)) setPendingAction(null)
      mutationLifecycle.finish(ticket)
    }
  }

  async function publishDraft() {
    if (!configuration || !preview || pendingAction || dirty || !configuration.permissions.publish) return
    const impact = configuration.cohort.participant_count
    if (configuration.cohort.status === 'active' && !(await confirmAction(
      `${impact} participant${impact === 1 ? '' : 's'} will keep their group’s current tools until you launch or update their group. Participants without a saved group version will see the published tools after refresh.`,
      { title: `Publish these participant tools for ${configuration.cohort.name}?`, confirmLabel: 'Publish', cancelLabel: 'Not yet' },
    ))) return
    const ticket = mutationLifecycle.begin()
    setPendingAction('publish')
    setError(null)
    try {
      const response = await publishCohortExperienceConfiguration(configuration.cohort.id, {
        draft_revision: configuration.draft_revision,
        preview_digest: preview.digest,
        expected_published_version_id: configuration.published_version?.id ?? null,
      })
      if (!mutationLifecycle.isCurrent(ticket)) return
      setConfiguration(response.experience_configuration)
      setDraft(response.experience_configuration.draft)
      setPreview(null)
      const experience = experienceModeOf(response.experience_configuration.draft) === 'savings_challenge' ? '90-day Savings Challenge' : 'Household CFO'
      setNotice(`Participant tools version ${response.published_version.number} is published (${experience}). Seal and launch a release next; the challenge opens separately from Admin.`)
    } catch (caught) {
      if (mutationLifecycle.isCurrent(ticket)) {
        setPreview(null)
        setError(errorMessage(caught, 'The participant-tools draft could not be published.'))
      }
    } finally {
      if (mutationLifecycle.isCurrent(ticket)) setPendingAction(null)
      mutationLifecycle.finish(ticket)
    }
  }

  async function rollback(versionId: number, versionNumber: number) {
    if (!configuration || dirty || pendingAction || !configuration.permissions.rollback) return
    if (!(await confirmAction('It is published as a new version. Nothing is deleted.', { title: `Restore version ${versionNumber}?`, confirmLabel: 'Restore', cancelLabel: 'Not yet' }))) return
    const ticket = mutationLifecycle.begin()
    setPendingAction('rollback')
    setError(null)
    try {
      const response = await rollbackCohortExperienceConfiguration(configuration.cohort.id, versionId, {
        draft_revision: configuration.draft_revision,
        expected_published_version_id: configuration.published_version?.id ?? null,
      })
      if (!mutationLifecycle.isCurrent(ticket)) return
      setConfiguration(response.experience_configuration)
      setDraft(response.experience_configuration.draft)
      setPreview(null)
      setNotice(`Version ${versionNumber} was restored as version ${response.published_version.number}.`)
    } catch (caught) {
      if (mutationLifecycle.isCurrent(ticket)) setError(errorMessage(caught, 'That participant-tools version could not be restored.'))
    } finally {
      if (mutationLifecycle.isCurrent(ticket)) setPendingAction(null)
      mutationLifecycle.finish(ticket)
    }
  }

  if (cohortsLoading && cohorts.length === 0) {
    return <article className="panel coach-empty coach-empty-main" role="status">Loading manageable cohorts…</article>
  }

  if (cohorts.length === 0) {
    return <article className="panel coach-empty coach-empty-main"><h3>No manageable cohorts yet.</h3><p>Assign this coach to a cohort before configuring participant tools.</p></article>
  }

  return (
    <div className="experience-studio" aria-busy={pendingAction !== null}>
      <article className="panel experience-cohort-picker">
        <div>
          <h3>Choose what participants can open.</h3>
          <p>{simple ? 'Save your choices, then review them in Go live. Your people keep their current tools until you approve the group update.' : 'Prepare the tools for this group. After publishing, use Release & rollout to launch or update the group. People already using a release keep their current tools until that update.'}</p>
        </div>
        <label>
          <span>Group</span>
          <select value={selectedCohortId ?? ''} disabled={pendingAction !== null && pendingAction !== 'load'} onChange={(event) => chooseCohort(Number(event.target.value))}>
            {cohorts.map((cohort) => <option key={cohort.id} value={cohort.id}>{cohort.name} · {cohort.status}</option>)}
          </select>
        </label>
      </article>

      {error && <div className="coach-studio-alert is-error" role="alert"><span>{error}</span>{selectedCohortId && <button type="button" onClick={() => void loadConfiguration(selectedCohortId)}>Reload</button>}</div>}
      {notice && <p className="coach-studio-alert is-success" role="status">{notice}</p>}

      {pendingAction === 'load' && !configuration ? <article className="panel" role="status">Loading participant tools…</article> : configuration && draft && (
        <>
          <article className="panel experience-mode-picker">
            <fieldset disabled={!configuration.permissions.edit || pendingAction !== null}>
              <legend><strong>What experience will participants get?</strong></legend>
              <div className="experience-mode-options">
                {experienceModes.map((option) => (
                  <label key={option.mode} className={`experience-mode-option${experienceModeOf(draft) === option.mode ? ' is-selected' : ''}`}>
                    <input type="radio" name="experience-mode" value={option.mode} checked={experienceModeOf(draft) === option.mode} onChange={() => chooseMode(option.mode)} />
                    <span><strong>{option.title}</strong><small>{option.description}</small><small>{option.detail}</small></span>
                  </label>
                ))}
              </div>
            </fieldset>
            <NavigationSummary draft={draft} />
          </article>
          <div className="experience-module-grid">
            <article className="panel experience-module-group">
              <header><div><h3>Participant tools</h3></div></header>
              <p>Home and Ask Mia stay available. Choose the other tools for this group.</p>
              {optionalModules.map(([key, label, description]) => (
                <label className="experience-module-row" key={key}>
                  <span><strong>{label}</strong><small>{description}</small></span>
                  <input type="checkbox" role="switch" checked={Boolean(configurableDraft(draft).optional_modules[key])}
                    disabled={!configuration.permissions.edit || pendingAction !== null}
                    onChange={() => toggleModule(key)} aria-label={`Include ${label}`} />
                </label>
              ))}
              {!configuration.permissions.edit && <p className="coach-read-only" role="note">{closedGroup ? 'Completed and archived cohorts are read-only.' : 'Your workspace role can view these tools but cannot change them.'}</p>}
            </article>
            <article className="panel experience-module-group">
              <h3>Tool order</h3>
              <p>Move tools up or down. Hidden tools keep their place until you turn them on.</p>
              <ol aria-label="Participant tool order">
                {moduleOrder(draft).map((id, index, order) => <li key={id}>
                  <span>{moduleLabels[id]}</span>{' '}
                  <Button variant="ghost" disabled={!configuration.permissions.edit || pendingAction !== null || index === 0} onClick={() => moveModule(id, -1)} aria-label={`Move ${moduleLabels[id]} up`}>Up</Button>{' '}
                  <Button variant="ghost" disabled={!configuration.permissions.edit || pendingAction !== null || index === order.length - 1} onClick={() => moveModule(id, 1)} aria-label={`Move ${moduleLabels[id]} down`}>Down</Button>
                </li>)}
              </ol>
              <Button variant="ghost" disabled={!configuration.permissions.edit || pendingAction !== null || !draft.module_order?.length} onClick={resetModuleOrder}>Use default order</Button>
            </article>
          </div>

            <details className="panel experience-module-group">
              <summary>Included tools and financial controls</summary>
              <p>These controls are always included.</p>
              {coreModules.map(([label, description]) => (
                <div className="experience-module-row is-core" key={label}>
                  <span><strong>{label}</strong><small>{description}</small></span>
                  <span aria-label={`${label} always included`}>Always on</span>
                </div>
              ))}
            </details>


          <>{simple && <article className="panel"><Button disabled={!dirty || pendingAction !== null || !configuration.permissions.edit} onClick={() => void saveDraft()}>{pendingAction === 'save' ? 'Saving…' : 'Save draft'}</Button><p>Review these saved choices in Go live before your people receive them.</p></article>}<article hidden={simple} className="panel experience-lifecycle">
            <header>
              <div><h3>Review the tools for this group.</h3></div>
              <span>{closedGroup ? 'Read-only group' : dirty ? 'Unsaved changes' : !previewMatches ? 'Preview required' : !configuration.permissions.publish ? 'Owner or reviewer needed' : 'Ready to publish'}</span>
            </header>
            <div className="experience-actions">
              <Button variant="secondary" aria-describedby={closedGroup ? 'experience-closed-help' : 'experience-save-help'} onClick={() => void saveDraft()} disabled={!dirty || pendingAction !== null || !configuration.permissions.edit}>{pendingAction === 'save' ? 'Saving' : 'Save draft'}</Button>
              <Button variant="secondary" aria-describedby={closedGroup ? 'experience-closed-help' : 'experience-preview-help'} onClick={() => void runPreview()} disabled={dirty || pendingAction !== null || !configuration.permissions.review}>{pendingAction === 'preview' ? 'Previewing' : 'Preview navigation'}</Button>
              <Button aria-describedby={closedGroup ? 'experience-closed-help' : 'experience-publish-help'} onClick={() => void publishDraft()} disabled={!configuration.permissions.publish || !previewMatches || dirty || pendingAction !== null}>{pendingAction === 'publish' ? 'Publishing' : 'Publish tool version'}</Button>
            </div>

            {closedGroup ? <p id="experience-closed-help" className="experience-action-help">Completed and archived groups are read-only. Their tools cannot be saved, previewed, or published.</p> : <>
            <p id="experience-save-help" className="experience-action-help">{pendingAction ? 'Wait for the current action to finish.' : !configuration.permissions.edit ? 'Your role cannot save changes to these tools.' : !dirty ? 'Tool choices saved. Change a choice to save again.' : 'Save your choices before previewing.'}</p>
            <p id="experience-preview-help" className="experience-action-help">{pendingAction ? 'Wait for the current action to finish.' : !configuration.permissions.review ? 'A program editor, reviewer, or owner must preview these tools.' : dirty ? 'Save your changes before previewing.' : 'Preview the saved choices to check the exact navigation.'}</p>
            <p id="experience-publish-help" className="experience-action-help">{pendingAction ? 'Wait for the current action to finish.' : !configuration.permissions.publish ? 'This group or your program role does not allow publishing. An owner or reviewer can publish tools for an open group.' : dirty ? 'Save and preview your changes before publishing.' : !previewMatches ? 'Preview navigation to enable publishing.' : 'Publish this version, then launch or update the group in Release & rollout. Participants without a release see published tools after refresh.'}</p>
            </>}

            {preview && <ExperiencePreview preview={preview} savingsChallenge={experienceModeOf(draft) === 'savings_challenge'} />}

            <details className="coach-version-history">
              <summary>Version history ({configuration.versions.length})</summary>
              <div className="coach-version-list">
                {configuration.versions.length === 0 ? <p>No published versions yet.</p> : configuration.versions.map((version) => (
                  <article key={version.id}>
                    <div><strong>Version {version.number}</strong><small>{new Date(version.published_at).toLocaleString()} · {version.published_by.full_name}</small></div>
                    {version.id === configuration.published_version?.id
                      ? <span className="coach-status is-current">Current</span>
                      : <Button size="compact" variant="ghost" disabled={dirty || pendingAction !== null || !configuration.permissions.rollback} onClick={() => void rollback(version.id, version.number)}>Restore as new version</Button>}
                  </article>
                ))}
              </div>
            </details>
          </article></>
        </>
      )}
    </div>
  )
}

function navigationFor(enabledIds: string[], savingsChallenge: boolean, order: string[] = [], independentStatements = false) {
  // Mirror ParticipantTabs exactly: the same primary destinations, and More only when needed.
  const { primary, secondary } = partitionParticipantSections(participantSectionsForModules(enabledIds, { moduleOrder: order, independentStatements }), savingsChallenge, order.length > 0)
  return { primary: primary.map((label) => navigationLabel(label, savingsChallenge)), secondary: secondary.map((label) => navigationLabel(label, savingsChallenge)) }
}

/** Live view of the tabs the current choice gives participants, before any preview round trip. */
function NavigationSummary({ draft }: { draft: CohortExperienceDraft }) {
  const savingsChallenge = experienceModeOf(draft) === 'savings_challenge'
  const { primary, secondary } = navigationFor(enabledModules(draft), savingsChallenge, draft.module_order, draft.schema_version === 4)
  return (
    <p className="experience-nav-summary" aria-label="Navigation participants will see">
      <span>Participants will see:</span> {primary.map((label) => <b key={label}>{label}</b>)}{secondary.length > 0 && <b>More · {secondary.join(', ')}</b>}
    </p>
  )
}

function ExperiencePreview({ preview, savingsChallenge }: { preview: CohortExperiencePreview; savingsChallenge: boolean }) {
  const enabled = preview.modules.filter((item) => item.enabled)
  const disabled = preview.modules.filter((item) => !item.enabled)
  const { primary, secondary } = navigationFor(enabled.map((item) => item.id), savingsChallenge, preview.module_order, preview.modules.some(item => item.id === 'statements'))
  return (
    <section className="experience-preview" aria-label="Exact participant navigation preview">
      <p className="experience-preview-mode"><strong>Experience:</strong> {savingsChallenge ? '90-day Savings Challenge' : 'Household CFO'}</p>
      <div className="experience-preview-device is-desktop">
        <span>Desktop</span>
        <nav aria-label="Desktop preview">{primary.map((label) => <b key={label}>{label}</b>)}{secondary.length > 0 && <b>More · {secondary.join(', ')}</b>}</nav>
      </div>
      <div className="experience-preview-device is-phone">
        <span>Phone</span>
        <nav aria-label="Phone preview">{primary.map((label) => <b key={label}>{label}</b>)}{secondary.length > 0 && <b>More</b>}</nav>
      </div>
      {disabled.length > 0 && <p><strong>Not included:</strong> {disabled.map((item) => item.label).join(', ')}. A saved link returns participants to Home with an explanation.</p>}
    </section>
  )
}

function errorMessage(error: unknown, fallback: string) {
  if (error instanceof ApiRequestError) return error.message
  return error instanceof Error ? error.message : fallback
}
