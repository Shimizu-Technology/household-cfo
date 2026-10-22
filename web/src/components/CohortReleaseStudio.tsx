import { coachVersionGuidance } from '../lib/coachVersionGuidance'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent as ReactKeyboardEvent, type MouseEvent as ReactMouseEvent } from 'react'
import {
  ApiRequestError,
  createCohortReleaseRequestId,
  fetchCohortReleaseStudio,
  restoreCohortRelease,
  sealCohortRelease,
} from '../api'
import type {
  AdminPersonaAssignableCohort,
  CohortReleaseRecord,
  CohortReleaseStudio as CohortReleaseStudioData,
} from '../api'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

type PendingAction = 'load' | 'seal' | 'restore' | null
type Confirmation = {
  kind: 'seal' | 'restore'
  release: CohortReleaseRecord | null
  requestId: string
}

const requiredChecks = [
  { key: 'workspace_brand', label: 'Program appearance' },
  { key: 'assistant_voice', label: 'Assistant voice' },
  { key: 'participant_tools', label: 'Participant tools' },
  { key: 'system_controls', label: 'System controls' },
  { key: 'participant_cohort', label: 'Group membership' },
] as const

export function CohortReleaseStudio({
  cohorts,
  cohortsLoading,
  mutationLifecycle,
  selectedCohortId,
  onSelectedCohortIdChange,
  embedded = false,
  onReleaseChange,
  beforeReleaseAction,
}: {
  cohorts: AdminPersonaAssignableCohort[]
  cohortsLoading: boolean
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  selectedCohortId: number | null
  onSelectedCohortIdChange: (cohortId: number | null) => void
  embedded?: boolean
  onReleaseChange?: () => void
  beforeReleaseAction?: () => boolean
}) {
  const [studio, setStudio] = useState<CohortReleaseStudioData | null>(null)
  const [pendingAction, setPendingAction] = useState<PendingAction>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [confirmation, setConfirmation] = useState<Confirmation | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [focusVersion, setFocusVersion] = useState(0)
  const loadRequestRef = useRef(0)
  const loadAbortControllerRef = useRef<AbortController | null>(null)
  const restoreFocusRef = useRef<HTMLElement | null>(null)
  const releaseStateHeadingRef = useRef<HTMLHeadingElement | null>(null)

  useLayoutEffect(() => {
    if (focusVersion > 0) releaseStateHeadingRef.current?.focus()
  }, [focusVersion])

  const loadStudio = useCallback(async (cohortId: number) => {
    const requestId = ++loadRequestRef.current
    loadAbortControllerRef.current?.abort()
    const abortController = new AbortController()
    loadAbortControllerRef.current = abortController
    setPendingAction('load')
    setStudio(null)
    setError(null)
    try {
      const next = await fetchCohortReleaseStudio(cohortId, abortController.signal)
      if (requestId !== loadRequestRef.current || abortController.signal.aborted) return
      if (next.cohort.id !== cohortId) throw new Error('Release records returned the wrong cohort. Reload and try again.')
      setStudio(next)
    } catch (caught) {
      if (requestId !== loadRequestRef.current || abortController.signal.aborted) return
      setError(releaseErrorMessage(caught, 'Cohort release records could not be loaded.'))
    } finally {
      if (requestId === loadRequestRef.current) {
        loadAbortControllerRef.current = null
        setPendingAction(null)
      }
    }
  }, [])

  useEffect(() => {
    if (selectedCohortId && cohorts.some((cohort) => cohort.id === selectedCohortId)) return
    const firstCohortId = cohorts[0]?.id ?? null
    queueMicrotask(() => {
      onSelectedCohortIdChange(firstCohortId)
      setStudio(null)
      setError(null)
      setNotice(null)
    })
  }, [cohorts, onSelectedCohortIdChange, selectedCohortId])

  useEffect(() => {
    if (selectedCohortId) queueMicrotask(() => void loadStudio(selectedCohortId))
  }, [loadStudio, selectedCohortId])

  useEffect(() => () => {
    loadRequestRef.current += 1
    loadAbortControllerRef.current?.abort()
  }, [])

  const displayedChecks = useMemo(() => requiredChecks.map((expected) => {
    const check = studio?.candidate?.checks.find((entry) => normalizeCheckKey(entry.key || entry.label) === expected.key)
    return check ? { ...check, label: expected.label } : {
      key: expected.key,
      label: expected.label,
      ready: false,
      detail: 'Waiting for server readiness evidence.',
    }
  }), [studio])

  const releases = useMemo(() => [...(studio?.releases ?? [])].sort((left, right) => (
    right.release_number - left.release_number || right.id - left.id
  )), [studio])
  const historyTotal = studio?.history.total_count ?? releases.length
  const historyLabel = studio?.history.truncated
    ? `${releases.length} of ${historyTotal} saved versions`
    : `${historyTotal} saved version${historyTotal === 1 ? '' : 's'}`
  const alreadyPrepared = Boolean(studio?.latest_release_match || studio?.candidate?.seal_needed === false)
  const latest = releases[0]
  const changes = studio?.candidate && latest ? [
    studio.candidate.brand_snapshot_digest !== latest.brand_snapshot_digest ? 'Program appearance' : null,
    studio.candidate.persona_version_id !== latest.persona_version_id ? 'Mia voice' : null,
    studio.candidate.experience_version_id !== latest.experience_version_id ? 'Participant tools' : null,
    studio.candidate.registry_digest !== latest.registry_digest ? 'System controls' : null,
  ].filter(Boolean) : []
  const restoreExpectedLatestReleaseId = studio?.candidate?.expected_latest_release_id ?? null

  const closeConfirmation = useCallback(() => {
    setConfirmation(null)
    setActionError(null)
    window.requestAnimationFrame(() => restoreFocusRef.current?.focus())
  }, [])

  function chooseCohort(cohortId: number) {
    if (cohortId === selectedCohortId || pendingAction || mutationLifecycle.pending) return
    loadRequestRef.current += 1
    loadAbortControllerRef.current?.abort()
    onSelectedCohortIdChange(cohortId)
    setStudio(null)
    setError(null)
    setNotice(null)
  }

  function requestSeal(event: ReactMouseEvent<HTMLButtonElement>) {
    if (beforeReleaseAction && !beforeReleaseAction()) return
    restoreFocusRef.current = event.currentTarget
    setActionError(null)
    setConfirmation({ kind: 'seal', release: null, requestId: createCohortReleaseRequestId() })
  }

  function requestRestore(event: ReactMouseEvent<HTMLButtonElement>, release: CohortReleaseRecord) {
    if (beforeReleaseAction && !beforeReleaseAction()) return
    restoreFocusRef.current = event.currentTarget
    setActionError(null)
    setConfirmation({ kind: 'restore', release, requestId: createCohortReleaseRequestId() })
  }

  async function confirmAction() {
    if (!confirmation || !studio || pendingAction || mutationLifecycle.pending) return
    if (confirmation.kind === 'seal' && !studio.candidate) return
    if (confirmation.kind === 'restore' && (!confirmation.release || restoreExpectedLatestReleaseId === null)) {
      setActionError('The latest release evidence is unavailable. Cancel this review, reload the cohort, and try again.')
      return
    }
    const cohortId = studio.cohort.id
    const mutation = mutationLifecycle.begin()
    setPendingAction(confirmation.kind)
    setActionError(null)
    try {
      if (confirmation.kind === 'seal') {
        if (!studio.candidate) return
        await sealCohortRelease(cohortId, {
          expected_bundle_digest: studio.candidate.bundle_digest,
          expected_assignment_id: studio.candidate.assignment_id,
          expected_persona_version_id: studio.candidate.persona_version_id,
          expected_experience_version_id: studio.candidate.experience_version_id,
          expected_brand_version_id: studio.candidate.brand_version_id,
          expected_tool_registry_digest: studio.candidate.registry_digest,
          expected_tool_registry_version: studio.candidate.registry_version,
          expected_latest_release_id: studio.candidate.expected_latest_release_id,
        }, confirmation.requestId)
      } else if (confirmation.release && restoreExpectedLatestReleaseId !== null) {
        await restoreCohortRelease(cohortId, confirmation.release.id, {
          expected_latest_release_id: restoreExpectedLatestReleaseId,
          source_bundle_digest: confirmation.release.bundle_digest,
          source_persona_version_id: confirmation.release.persona_version_id,
          source_experience_version_id: confirmation.release.experience_version_id,
          source_brand_version_id: confirmation.release.brand_version_id,
        }, confirmation.requestId)
      }
      if (!mutationLifecycle.isCurrent(mutation)) return
      const action = confirmation.kind
      setConfirmation(null)
      setNotice(action === 'seal'
        ? 'Version prepared. Participant settings did not change. Launch or update the group next.'
        : 'Previous settings saved as a new version. Participant settings did not change.')
      await loadStudio(cohortId)
      onReleaseChange?.()
      setFocusVersion((version) => version + 1)
    } catch (caught) {
      if (!mutationLifecycle.isCurrent(mutation)) return
      if (caught instanceof ApiRequestError && caught.status === 409) {
        setConfirmation(null)
        await loadStudio(cohortId)
        setError('Readiness changed before the version was saved. Review the latest cohort evidence before trying again.')
        window.requestAnimationFrame(() => restoreFocusRef.current?.focus())
      } else if (caught instanceof ApiRequestError && caught.status === 403) {
        setConfirmation(null)
        await loadStudio(cohortId)
        setError('Your release permission changed. The latest cohort view is loaded below.')
        window.requestAnimationFrame(() => restoreFocusRef.current?.focus())
      } else if (caught instanceof ApiRequestError && caught.status >= 400 && caught.status < 500) {
        setConfirmation(null)
        const message = releaseErrorMessage(caught, 'The version could not be saved. Review the latest evidence and try again.')
        await loadStudio(cohortId)
        setError(message)
        window.requestAnimationFrame(() => restoreFocusRef.current?.focus())
      } else {
        setActionError(releaseErrorMessage(caught, 'The version could not be saved.'))
      }
    } finally {
      if (mutationLifecycle.isCurrent(mutation)) setPendingAction(null)
      mutationLifecycle.finish(mutation)
    }
  }

  if (cohortsLoading && cohorts.length === 0) {
    return <article className="panel coach-empty coach-empty-main" role="status">Loading manageable cohorts…</article>
  }

  if (cohorts.length === 0) {
    return <article className="panel coach-empty coach-empty-main"><h3>No manageable cohorts yet.</h3><p>Assign this coach to a cohort before reviewing release evidence.</p></article>
  }

  return (
    <section className="cohort-release-studio" aria-busy={pendingAction !== null || mutationLifecycle.pending}>
      {!embedded && <div className="cohort-release-truth" role="note">
        <span className="cohort-release-truth-icon" aria-hidden="true"><EvidenceIcon /></span>
        <div>
          <strong>Release records are audit evidence.</strong>
          <p>Preparing or restoring a version does not change the appearance, assistant, or tools participants use.</p>
          <small>Continue to publish the brand, assign the assistant, and publish participant tools in their existing areas.</small>
        </div>
      </div>}

      {!embedded && <article className="panel cohort-release-picker">
        <div>
          <p className="eyebrow">Cohort releases</p>
          <h3>Review and seal the brand, assistant, and tools together</h3>
          <p>Choose a cohort to check the exact published versions and preserve an immutable record.</p>
        </div>
        <label>
          <span>Cohort</span>
          <select value={selectedCohortId ?? ''} disabled={pendingAction !== null || mutationLifecycle.pending} onChange={(event) => chooseCohort(Number(event.target.value))}>
            {cohorts.map((cohort) => <option key={cohort.id} value={cohort.id}>{cohort.name} · {titleize(cohort.status)}</option>)}
          </select>
        </label>
      </article>}

      {error && (
        <div className="coach-studio-alert is-error" role="alert">
          <span>{error}</span>
          <button type="button" onClick={() => selectedCohortId && void loadStudio(selectedCohortId)}>Retry</button>
        </div>
      )}
      {notice && <p className="coach-studio-alert is-success" role="status">{notice}</p>}

      {pendingAction === 'load' && !studio ? (
        <article className="panel cohort-release-loading" role="status">Checking the exact release evidence…</article>
      ) : studio && !studio.permissions.view ? (
        <article className="panel cohort-release-empty"><h3>Release records are unavailable.</h3><p>Your role does not have access to this cohort's release evidence.</p></article>
      ) : studio ? (
        <div className="cohort-release-layout">
          <article className="panel cohort-release-readiness">
            <header>
              <div>

                <h3 ref={releaseStateHeadingRef} tabIndex={-1}>{alreadyPrepared ? 'Settings already prepared' : studio.candidate?.ready ? 'Ready to prepare' : 'Settings need attention'}</h3>
              </div>
              <span className={`cohort-release-state ${studio.candidate?.ready ? 'is-ready' : ''}`}>{alreadyPrepared ? 'Prepared' : studio.candidate?.ready ? 'Ready' : 'Needs attention'}</span>
            </header>

            {!alreadyPrepared && changes.length > 0 && <p><strong>Pending changes:</strong> {changes.join(', ')}. Preparing this version does not change what participants use.</p>}
            <details open={!alreadyPrepared}><summary>Readiness checks</summary>
            <ol className="cohort-release-checklist">
              {displayedChecks.map((check) => (
                <li key={check.key} className={check.ready ? 'is-ready' : ''}>
                  <span aria-hidden="true">{check.ready ? <CheckIcon /> : <PendingIcon />}</span>
                  <div><strong>{check.label}</strong><small>{coachVersionGuidance(check.detail ?? (check.ready ? 'The reviewed settings are ready.' : 'Complete this requirement before preparing a version.'))}</small></div>
                  <b>{check.ready ? 'Ready' : 'Needed'}<span className="sr-only">: {check.label}</span></b>
                </li>
              ))}
            </ol></details>

            {studio.candidate?.blockers && studio.candidate.blockers.length > 0 && (
              <div className="cohort-release-blockers" role="note">
                <strong>What needs attention</strong>
                <ul>{studio.candidate.blockers.map((blocker) => <li key={blocker}>{coachVersionGuidance(blocker)}</li>)}</ul>
              </div>
            )}
            {studio.candidate?.warnings && studio.candidate.warnings.length > 0 && (
              <div className="cohort-release-warnings" role="note">
                <strong>Review before sealing</strong>
                <ul>{studio.candidate.warnings.map((warning) => <li key={warning}>{coachVersionGuidance(warning)}</li>)}</ul>
              </div>
            )}

            {studio.candidate && (
              <details><summary>Version details</summary><dl className="cohort-release-evidence">
                <div><dt>Brand version</dt><dd>{brandEvidenceLabel(studio.candidate.brand_mode, studio.candidate.brand_version_id)}</dd></div>
                <div><dt>Assistant version</dt><dd>{studio.candidate.persona_version_id === null ? 'Neutral built-in voice' : `Version ${studio.candidate.persona_version_id}`} </dd></div>
                <div><dt>Participant tools version</dt><dd>{studio.candidate.experience_version_id === null ? 'Safe default tools' : `Version ${studio.candidate.experience_version_id}`} </dd></div>
                <div className="is-wide"><dt>Bundle fingerprint</dt><dd>{shortDigest(studio.candidate.bundle_digest)}</dd></div>
              </dl></details>
            )}

            {(pendingAction !== null || mutationLifecycle.pending) && <p role="status">Wait for the current action to finish.</p>}
            {!studio.candidate?.ready && !alreadyPrepared && <p>Complete the readiness checks above before preparing a version.</p>}
            <div className="cohort-release-actions">
              {studio.permissions.seal ? (
                <Button
                  onClick={requestSeal}
                  disabled={!studio.candidate?.ready || !studio.candidate.seal_needed || studio.latest_release_match || pendingAction !== null || mutationLifecycle.pending}
                >
                  {pendingAction === 'seal' ? 'Preparing version' : studio.latest_release_match || !studio.candidate?.seal_needed ? 'Settings already prepared' : 'Review and prepare version'}
                </Button>
              ) : <p className="coach-read-only">You can review release evidence, but this cohort or your role does not allow sealing records.</p>}
              {(studio.latest_release_match || studio.candidate?.seal_needed === false) && <p className="cohort-release-noop" role="status">The latest version already includes these settings. Use the launch review above, or choose Update group to check for a pending update.</p>}
            </div>
          </article>

          <details className="panel cohort-release-history"><summary>Version history ({historyTotal})</summary>
            <header>
              <div><h3>{historyLabel}</h3></div>
            </header>
            {releases.length === 0 ? (
              <div className="cohort-release-empty"><strong>No saved versions yet.</strong><p>Prepare the reviewed settings to save this group’s first version.</p></div>
            ) : (
              <ol>
                {releases.map((release, index) => (
                  <li key={release.id}>
                    <header>
                      <div>
                        <strong>{index === 0 ? 'Latest saved version' : `Version ${release.release_number}`}</strong>
                        <small>{formatReleaseEvent(release)} · {formatReleaseDate(release.released_at)}</small>
                      </div>
                      <span>Version {release.release_number}</span>
                    </header>
                    <dl>
                      <div><dt>Saved by</dt><dd>{release.actor?.full_name ?? (release.actor_user_id ? `Authorized user #${release.actor_user_id}` : 'System record')}</dd></div>
                      <div><dt>Brand version</dt><dd>{brandEvidenceLabel(release.brand_mode, release.brand_version_id)}</dd></div>
                      <div><dt>Fingerprint</dt><dd>{shortDigest(release.bundle_digest)}</dd></div>
                    </dl>
                    {release.source_release_id && <p>Restored from saved record {release.source_release_id}.</p>}
                    {release.restore_allowed && studio.permissions.restore && restoreExpectedLatestReleaseId !== null ? (
                      <Button size="compact" variant="secondary" onClick={(event) => requestRestore(event, release)} disabled={pendingAction !== null || mutationLifecycle.pending}>Review restore record</Button>
                    ) : release.restore_allowed && studio.permissions.restore ? (
                      <small className="cohort-release-restore-reason">Restore unavailable: latest release evidence is unavailable. Reload the cohort and try again.</small>
                    ) : index !== 0 && release.restore_reason ? (
                      <small className="cohort-release-restore-reason">Restore unavailable: {coachVersionGuidance(release.restore_reason)}</small>
                    ) : null}
                  </li>
                ))}
              </ol>
            )}
          </details>
        </div>
      ) : null}

      {confirmation && studio && (
        <ReleaseConfirmationDialog
          confirmation={confirmation}
          cohortName={studio.cohort.name}
          brandLabel={confirmation.kind === 'restore'
            ? brandEvidenceLabel(confirmation.release?.brand_mode ?? '', confirmation.release?.brand_version_id ?? null)
            : brandEvidenceLabel(studio.candidate?.brand_mode ?? '', studio.candidate?.brand_version_id ?? null)}
          experienceLabel={confirmation.kind === 'seal' ? studio.candidate?.participant_experience?.label ?? null : null}
          pending={pendingAction === confirmation.kind}
          error={actionError}
          onCancel={closeConfirmation}
          onConfirm={() => void confirmAction()}
        />
      )}
    </section>
  )
}

function ReleaseConfirmationDialog({
  confirmation,
  cohortName,
  brandLabel,
  experienceLabel,
  pending,
  error,
  onCancel,
  onConfirm,
}: {
  confirmation: Confirmation
  cohortName: string
  brandLabel: string | number
  experienceLabel: string | null
  pending: boolean
  error: string | null
  onCancel: () => void
  onConfirm: () => void
}) {
  const dialogRef = useRef<HTMLElement | null>(null)
  const cancelRef = useRef<HTMLButtonElement | null>(null)

  useEffect(() => {
    dialogRef.current?.focus({ preventScroll: true })
    if (dialogRef.current) dialogRef.current.scrollTop = 0
    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => { document.body.style.overflow = previousOverflow }
  }, [])

  useEffect(() => {
    const handleEscape = (event: globalThis.KeyboardEvent) => {
      if (event.key === 'Escape' && !pending) onCancel()
    }
    document.addEventListener('keydown', handleEscape)
    return () => document.removeEventListener('keydown', handleEscape)
  }, [onCancel, pending])

  function trapFocus(event: ReactKeyboardEvent<HTMLElement>) {
    if (event.key !== 'Tab') return
    const focusable = Array.from(dialogRef.current?.querySelectorAll<HTMLElement>('button:not(:disabled), [href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex="-1"])') ?? [])
    if (focusable.length === 0) return
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (document.activeElement === dialogRef.current) { event.preventDefault(); (event.shiftKey ? last : first).focus() }
    else if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  const restoring = confirmation.kind === 'restore'
  return (
    <div className="cohort-release-modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget && !pending) onCancel() }}>
      <section ref={dialogRef} className="cohort-release-modal" tabIndex={-1} role="dialog" aria-modal="true" aria-labelledby="cohort-release-modal-title" aria-describedby="cohort-release-modal-copy" onKeyDown={trapFocus}>
        <p className="eyebrow">Final review</p>
        <h3 id="cohort-release-modal-title">{restoring ? `Restore version ${confirmation.release?.release_number}` : 'Prepare this version?'}</h3>
        <p id="cohort-release-modal-copy">This saves a fixed version of the reviewed settings for {cohortName}. Participants keep their current settings until you launch or update the group.</p>
        <dl className="cohort-rollout-confirmation-summary">
          <div><dt>Cohort</dt><dd>{cohortName}</dd></div>
          <div><dt>{restoring ? 'Historical brand' : 'Brand version'}</dt><dd>{brandLabel}</dd></div>
          {experienceLabel && <div><dt>Participant experience</dt><dd>{experienceLabel}</dd></div>}
        </dl>
        {restoring && <p className="cohort-release-modal-note">A restore preserves the selected historical bundle as a new record. Existing history remains unchanged.</p>}
        {error && <p className="coach-studio-alert is-error" role="alert">{error}</p>}
        <div className="cohort-release-modal-actions">
          <button ref={cancelRef} type="button" className="button button--ghost button--default" onClick={onCancel} disabled={pending}>Cancel</button>
          <Button onClick={onConfirm} disabled={pending}>{pending ? 'Preparing version' : restoring ? 'Save restored version' : 'Prepare version'}</Button>
        </div>
      </section>
    </div>
  )
}

function normalizeCheckKey(value: string) {
  const normalized = value.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '')
  if (normalized.includes('brand')) return 'workspace_brand'
  if (normalized.includes('assistant') || normalized.includes('persona') || normalized.includes('voice')) return 'assistant_voice'
  if (normalized.includes('tool') || normalized.includes('experience')) return 'participant_tools'
  if (normalized.includes('system') || normalized.includes('control') || normalized.includes('registry')) return 'system_controls'
  if (normalized.includes('participant') || normalized.includes('cohort') || normalized.includes('member')) return 'participant_cohort'
  return normalized
}

function brandEvidenceLabel(mode: string, versionId: number | null) {
  if (versionId !== null) return `Version ${versionId}`
  if (mode === 'legacy_household_cfo_builtin') return 'Household CFO legacy brand'
  return 'Built-in brand'
}

function releaseErrorMessage(caught: unknown, fallback: string) {
  return coachVersionGuidance(caught instanceof Error && caught.message ? caught.message : fallback)
}

function titleize(value: string) {
  return value.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase())
}

function shortDigest(digest: string) {
  if (!digest) return 'Unavailable'
  return digest.length > 20 ? `${digest.slice(0, 12)}…${digest.slice(-8)}` : digest
}

function formatReleaseDate(value: string) {
  if (!value) return 'Time unavailable'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date)
}

function formatReleaseEvent(release: CohortReleaseRecord) {
  if (release.event_type === 'restore') return 'Restore record'
  if (release.event_type === 'reconciliation') return 'Legacy reconciliation'
  return 'Release record'
}

function EvidenceIcon() {
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 3.75h9l3 3V20.25H6zM15 3.75v3h3M9 11.25h6M9 15h4.5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" /></svg>
}

function CheckIcon() {
  return <svg viewBox="0 0 20 20" aria-hidden="true"><path d="m5 10.25 3.1 3.1L15 6.7" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" /></svg>
}

function PendingIcon() {
  return <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 5.25v5.25l3 1.75" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" /></svg>
}
