import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { partitionParticipantSections, participantSectionsForModules } from '../lib/participantNavigation'
import {
  ApiRequestError,
  fetchCohortExperienceConfiguration,
  rollbackCohortExperienceConfiguration,
  updateCohortExperienceConfiguration,
} from '../api'
import type {
  AdminPersonaAssignableCohort,
  CohortExperienceConfiguration,
  ConfigurableCohortExperienceDraft,
  CohortExperienceDraft,
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
  ['review', 'Review', 'Check purchases before they count in your spending.'],
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


type PendingAction = 'load' | 'save' | 'rollback' | null

// Tools for a group: choose what people can open and in what order, save it as a draft (it goes live
// with Coaching → Go live), and go back to an earlier version.
export function CohortExperienceStudio({
  cohorts,
  fixedGroup = false,
  cohortsLoading,
  mutationLifecycle,
  onDirtyChange,
  selectedCohortId,
  onSelectedCohortIdChange,
}: {
  cohorts: AdminPersonaAssignableCohort[]
  // The group page already says which group this is, so the picker steps aside.
  fixedGroup?: boolean
  cohortsLoading: boolean
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  onDirtyChange: (dirty: boolean) => void
  selectedCohortId: number | null
  onSelectedCohortIdChange: (cohortId: number | null) => void
}) {
  const [configuration, setConfiguration] = useState<CohortExperienceConfiguration | null>(null)
  const [draft, setDraft] = useState<CohortExperienceDraft | null>(null)
  const [pendingAction, setPendingAction] = useState<PendingAction>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const loadRequestRef = useRef(0)
  const loadAbortControllerRef = useRef<AbortController | null>(null)

  const dirty = useMemo(() => Boolean(configuration && draft && JSON.stringify(configuration.draft) !== JSON.stringify(draft)), [configuration, draft])

  const closedGroup = Boolean(configuration && ['completed', 'archived'].includes(configuration.cohort.status))

  useEffect(() => onDirtyChange(dirty), [dirty, onDirtyChange])
  useEffect(() => () => onDirtyChange(false), [onDirtyChange])

  const prepareCohortSelection = useCallback((cohortId: number | null) => {
    loadRequestRef.current += 1
    loadAbortControllerRef.current?.abort()
    loadAbortControllerRef.current = null
    setConfiguration(null)
    setDraft(null)
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
    try {
      const next = await fetchCohortExperienceConfiguration(cohortId, abortController.signal)
      if (requestId !== loadRequestRef.current || abortController.signal.aborted) return
      if (next.cohort.id !== cohortId) throw new Error('Participant tools returned the wrong group. Reload and try again.')
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
    if (dirty && !(await confirmDiscard('Discard the unsaved participant-tool changes and open another group?'))) return
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
    setNotice(null)
  }

  function toggleModule(key: typeof optionalModules[number][0]) {
    setDraft((current) => current ? {
      ...configurableDraft(current),
      optional_modules: { ...configurableDraft(current).optional_modules, [key]: !configurableDraft(current).optional_modules[key] },
    } : current)
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
    setNotice(null)
  }

  function resetModuleOrder() {
    setDraft(current => current ? { ...configurableDraft(current), module_order: [] } : current)
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
        setNotice('Tools saved. Review them in Go live.')
    } catch (caught) {
      if (mutationLifecycle.isCurrent(ticket)) setError(errorMessage(caught, 'The participant-tools draft could not be saved.'))
    } finally {
      if (mutationLifecycle.isCurrent(ticket)) setPendingAction(null)
      mutationLifecycle.finish(ticket)
    }
  }

  async function rollback(versionId: number, versionNumber: number) {
    if (!configuration || dirty || pendingAction || !configuration.permissions.rollback) return
    if (!(await confirmAction('It is published as a new version and nothing is deleted. People with a saved group version keep their current tools until you update the group in Coaching → Go live. People without a saved group version may see the restored tools after they refresh.', { title: `Go back to version ${versionNumber}?`, confirmLabel: 'Go back to it', cancelLabel: 'Not yet' }))) return
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
        setNotice(`Version ${versionNumber} is back, saved as version ${response.published_version.number}.`)
    } catch (caught) {
      if (mutationLifecycle.isCurrent(ticket)) setError(errorMessage(caught, 'That earlier version could not be restored.'))
    } finally {
      if (mutationLifecycle.isCurrent(ticket)) setPendingAction(null)
      mutationLifecycle.finish(ticket)
    }
  }

  if (cohortsLoading && cohorts.length === 0) {
    return <article className="panel coach-empty coach-empty-main" role="status">Loading groups…</article>
  }

  if (cohorts.length === 0) {
    return <article className="panel coach-empty coach-empty-main"><h3>No groups yet.</h3><p>Tools belong to a group. Ask a program owner to add you to one.</p></article>
  }

  return (
    <div className="experience-studio" aria-busy={pendingAction !== null}>
      {fixedGroup ? <p className="experience-fixed-intro">Save your choices, then approve them under Coaching → Go live. Your people keep their current tools until you approve the group update.</p> : <article className="panel experience-cohort-picker">
        <div>
          <h3>Choose what participants can open.</h3>
          <p>Save your choices, then review them in Go live. Your people keep their current tools until you approve the group update.</p>
        </div>
        <label>
          <span>Group</span>
          <select value={selectedCohortId ?? ''} disabled={pendingAction !== null && pendingAction !== 'load'} onChange={(event) => chooseCohort(Number(event.target.value))}>
            {cohorts.map((cohort) => <option key={cohort.id} value={cohort.id}>{cohort.name}</option>)}
          </select>
        </label>
      </article>}

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
          <article className="panel experience-module-group">
            <header><div><h3>What people can open, and in what order</h3></div></header>
            <p>Turn tools on or off, and move them up or down. Home and Ask Mia are always on.</p>
            <ol className="experience-tool-list" aria-label="Participant tool order">
              {moduleOrder(draft).map((id, index, order) => {
                const always = id === 'home' || id === 'ask_mia'
                const description = [...coreModules.map(([label, text]) => [label === 'Home' ? 'home' : 'ask_mia', text] as const), ...optionalModules.map(([key, , text]) => [key, text] as const)].find(([key]) => key === id)?.[1]
                const locked = !configuration.permissions.edit || pendingAction !== null
                return <li key={id} className="experience-module-row">
                  <span><strong>{moduleLabels[id]}</strong><small>{description}</small></span>
                  {always ? <span className="experience-always" aria-label={`${moduleLabels[id]} always included`}>Always on</span>
                    : <input type="checkbox" role="switch" checked={Boolean(configurableDraft(draft).optional_modules[id as keyof ConfigurableCohortExperienceDraft['optional_modules']])} disabled={locked} onChange={() => toggleModule(id as typeof optionalModules[number][0])} aria-label={`Include ${moduleLabels[id]}`} />}
                  <span className="experience-move">
                    <Button variant="secondary" disabled={locked || index === 0} onClick={() => moveModule(id, -1)} aria-label={`Move ${moduleLabels[id]} up`}>↑</Button>
                    <Button variant="secondary" disabled={locked || index === order.length - 1} onClick={() => moveModule(id, 1)} aria-label={`Move ${moduleLabels[id]} down`}>↓</Button>
                  </span>
                </li>
              })}
            </ol>
            <Button variant="ghost" disabled={!configuration.permissions.edit || pendingAction !== null || !draft.module_order?.length} onClick={resetModuleOrder}>Use the usual order</Button>
            {!configuration.permissions.edit && <p className="coach-read-only" role="note">{closedGroup ? 'Finished and archived groups are read-only.' : 'Your role can see these tools but can’t change them.'}</p>}
          </article>

          <article className="panel experience-save">
            <Button disabled={!dirty || pendingAction !== null || !configuration.permissions.edit} onClick={() => void saveDraft()}>{pendingAction === 'save' ? 'Saving…' : 'Save draft'}</Button>
            <p>Review these saved choices in Go live before your people receive them.</p>
          </article>

          {configuration.versions.length > 0 && <details className="panel coach-version-history">
            <summary>Earlier versions ({configuration.versions.length})</summary>
            <div className="coach-version-list">
              {configuration.versions.map((version) => (
                <article key={version.id}>
                  <div><strong>Version {version.number}</strong><small>{new Date(version.published_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })} · {version.published_by.full_name}</small></div>
                  {version.id === configuration.published_version?.id
                    ? <span className="coach-status is-current">Current</span>
                    : <Button size="compact" variant="ghost" disabled={dirty || pendingAction !== null || !configuration.permissions.rollback} onClick={() => void rollback(version.id, version.number)}>Go back to this version</Button>}
                </article>
              ))}
            </div>
            {!configuration.permissions.rollback ? <p className="coach-read-only" role="note">{closedGroup ? 'Finished and archived groups can’t go back to an earlier version.' : 'A program owner or reviewer can go back to an earlier version.'}</p>
              : dirty && <p className="coach-read-only" role="note">Save or discard your changes first, then you can go back to an earlier version.</p>}
          </details>}
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

/** Live view of the tabs the current choice gives participants. */
function NavigationSummary({ draft }: { draft: CohortExperienceDraft }) {
  const savingsChallenge = experienceModeOf(draft) === 'savings_challenge'
  const { primary, secondary } = navigationFor(enabledModules(draft), savingsChallenge, draft.module_order, draft.schema_version === 4)
  return (
    <p className="experience-nav-summary" aria-label="Navigation participants will see">
      <span>Participants will see:</span> {primary.map((label) => <b key={label}>{label}</b>)}{secondary.length > 0 && <b>More · {secondary.join(', ')}</b>}
    </p>
  )
}

function errorMessage(error: unknown, fallback: string) {
  if (error instanceof ApiRequestError) return error.message
  return error instanceof Error ? error.message : fallback
}
