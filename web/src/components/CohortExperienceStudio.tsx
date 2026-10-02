import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
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
  CohortExperienceDraft,
  CohortExperiencePreview,
} from '../api'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

const coreModules = [
  ['Home', 'See the household status and next action.'],
  ['Review', 'Approve activity before it changes actuals.'],
  ['Ask Mia', 'Use the supervised coaching assistant.'],
  ['Budget', 'Review and edit the approved plan.'],
  ['My Profile', 'Manage household context, files, connections, and memory.'],
  ['Wealth', 'See debt, assets, runway, and long-range capacity.'],
] as const

const optionalModules = [
  ['cfo_filter', 'CFO Filter', 'Pressure-test a purchase before money moves.'],
  ['optionality', 'Optionality', 'Compare choices against stability and runway.'],
] as const

type PendingAction = 'load' | 'save' | 'preview' | 'publish' | 'rollback' | null

export function CohortExperienceStudio({
  cohorts,
  cohortsLoading,
  mutationLifecycle,
  onDirtyChange,
}: {
  cohorts: AdminPersonaAssignableCohort[]
  cohortsLoading: boolean
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  onDirtyChange: (dirty: boolean) => void
}) {
  const [selectedCohortId, setSelectedCohortId] = useState<number | null>(cohorts[0]?.id ?? null)
  const [configuration, setConfiguration] = useState<CohortExperienceConfiguration | null>(null)
  const [draft, setDraft] = useState<CohortExperienceDraft | null>(null)
  const [preview, setPreview] = useState<CohortExperiencePreview | null>(null)
  const [pendingAction, setPendingAction] = useState<PendingAction>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const loadRequestRef = useRef(0)
  const loadAbortControllerRef = useRef<AbortController | null>(null)

  const dirty = useMemo(() => Boolean(configuration && draft && JSON.stringify(configuration.draft) !== JSON.stringify(draft)), [configuration, draft])

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
    setSelectedCohortId(cohortId)
  }, [])

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

  function chooseCohort(value: number) {
    if (value === selectedCohortId) return
    if (dirty && !window.confirm('Discard the unsaved participant-tool changes and open another cohort?')) return
    prepareCohortSelection(value)
  }

  function toggleModule(key: 'cfo_filter' | 'optionality') {
    setDraft((current) => current ? {
      ...current,
      optional_modules: { ...current.optional_modules, [key]: !current.optional_modules[key] },
    } : current)
    setPreview(null)
    setNotice(null)
  }

  async function saveDraft() {
    if (!configuration || !draft || pendingAction) return
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
    if (!configuration || dirty || pendingAction) return
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
    if (!configuration || !preview || pendingAction || dirty) return
    const impact = configuration.cohort.participant_count
    if (configuration.cohort.status === 'active' && !window.confirm(
      `Publish these participant tools now? ${impact} participant${impact === 1 ? '' : 's'} in ${configuration.cohort.name} will see the new navigation after refresh.`,
    )) return
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
      setNotice(`Participant tools version ${response.published_version.number} is published.`)
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
    if (!configuration || dirty || pendingAction) return
    if (!window.confirm(`Restore version ${versionNumber} as a new published version?`)) return
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
          <p className="eyebrow">Cohort experience</p>
          <h3>Choose what participants can open.</h3>
          <p>The essential financial controls stay available. Optional teaching tools appear only after this exact draft is previewed and published.</p>
        </div>
        <label>
          <span>Cohort</span>
          <select value={selectedCohortId ?? ''} disabled={pendingAction !== null && pendingAction !== 'load'} onChange={(event) => chooseCohort(Number(event.target.value))}>
            {cohorts.map((cohort) => <option key={cohort.id} value={cohort.id}>{cohort.name} · {cohort.status}</option>)}
          </select>
        </label>
      </article>

      {error && <div className="coach-studio-alert is-error" role="alert"><span>{error}</span>{selectedCohortId && <button type="button" onClick={() => void loadConfiguration(selectedCohortId)}>Reload</button>}</div>}
      {notice && <p className="coach-studio-alert is-success" role="status">{notice}</p>}

      {pendingAction === 'load' && !configuration ? <article className="panel" role="status">Loading participant tools…</article> : configuration && draft && (
        <>
          <div className="experience-module-grid">
            <article className="panel experience-module-group">
              <header><div><p className="eyebrow">Always included</p><h3>Financial control and transparency</h3></div><span>Locked on</span></header>
              {coreModules.map(([label, description]) => (
                <div className="experience-module-row is-core" key={label}>
                  <span><strong>{label}</strong><small>{description}</small></span>
                  <span aria-label={`${label} always included`}>Always on</span>
                </div>
              ))}
            </article>

            <article className="panel experience-module-group">
              <header><div><p className="eyebrow">Coach controlled</p><h3>Optional teaching tools</h3></div><span>{Object.values(draft.optional_modules).filter(Boolean).length} enabled</span></header>
              {optionalModules.map(([key, label, description]) => (
                <label className="experience-module-row" key={key}>
                  <span><strong>{label}</strong><small>{description}</small></span>
                  <input
                    type="checkbox"
                    role="switch"
                    checked={draft.optional_modules[key]}
                    disabled={!configuration.permissions.edit || pendingAction !== null}
                    onChange={() => toggleModule(key)}
                    aria-label={`Include ${label}`}
                  />
                </label>
              ))}
              {!configuration.permissions.edit && <p className="coach-read-only" role="note">Completed and archived cohorts are read-only.</p>}
            </article>
          </div>

          <article className="panel experience-lifecycle">
            <header>
              <div><p className="eyebrow">Save, preview, publish</p><h3>Review the exact participant experience.</h3></div>
              <span>{dirty ? 'Unsaved changes' : configuration.preview_required ? 'Preview required' : 'Ready to publish'}</span>
            </header>
            <div className="experience-actions">
              <Button onClick={() => void saveDraft()} disabled={!dirty || pendingAction !== null || !configuration.permissions.edit}>{pendingAction === 'save' ? 'Saving' : 'Save draft'}</Button>
              <Button variant="secondary" onClick={() => void runPreview()} disabled={dirty || pendingAction !== null || !configuration.permissions.edit}>{pendingAction === 'preview' ? 'Previewing' : 'Preview navigation'}</Button>
              <Button onClick={() => void publishDraft()} disabled={!preview || dirty || pendingAction !== null || preview.digest !== configuration.preview?.digest}>{pendingAction === 'publish' ? 'Publishing' : 'Publish to cohort'}</Button>
            </div>

            {preview && <ExperiencePreview preview={preview} />}

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
          </article>
        </>
      )}
    </div>
  )
}

function ExperiencePreview({ preview }: { preview: CohortExperiencePreview }) {
  const enabled = preview.modules.filter((item) => item.enabled)
  const disabled = preview.modules.filter((item) => !item.enabled)
  return (
    <section className="experience-preview" aria-label="Exact participant navigation preview">
      <div className="experience-preview-device is-desktop">
        <span>Desktop</span>
        <nav aria-label="Desktop preview">{enabled.map((item) => <b key={item.id}>{item.label}</b>)}</nav>
      </div>
      <div className="experience-preview-device is-phone">
        <span>Phone</span>
        <nav aria-label="Phone preview">{enabled.slice(0, 4).map((item) => <b key={item.id}>{item.label}</b>)}<b>Tools</b></nav>
      </div>
      {disabled.length > 0 && <p><strong>Not included:</strong> {disabled.map((item) => item.label).join(', ')}. A saved link returns participants to Home with an explanation.</p>}
    </section>
  )
}

function errorMessage(error: unknown, fallback: string) {
  if (error instanceof ApiRequestError) return error.message
  return error instanceof Error ? error.message : fallback
}
