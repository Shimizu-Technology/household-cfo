import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent as ReactKeyboardEvent, type MouseEvent as ReactMouseEvent } from 'react'
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
  { key: 'workspace_brand', label: 'Workspace brand' },
  { key: 'assistant_voice', label: 'Assistant voice' },
  { key: 'participant_tools', label: 'Participant tools' },
  { key: 'system_controls', label: 'System controls' },
  { key: 'participant_cohort', label: 'Participant cohort check' },
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
  const loadRequestRef = useRef(0)
  const loadAbortControllerRef = useRef<AbortController | null>(null)
  const restoreFocusRef = useRef<HTMLElement | null>(null)
  const releaseStateHeadingRef = useRef<HTMLHeadingElement | null>(null)

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
    return check ?? {
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
    ? `${releases.length} of ${historyTotal} sealed records`
    : `${historyTotal} sealed record${historyTotal === 1 ? '' : 's'}`
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
        ? 'Release record sealed. Participant runtime did not change.'
        : 'Restore record sealed. Participant runtime did not change.')
      await loadStudio(cohortId)
      onReleaseChange?.()
      window.requestAnimationFrame(() => releaseStateHeadingRef.current?.focus())
    } catch (caught) {
      if (!mutationLifecycle.isCurrent(mutation)) return
      if (caught instanceof ApiRequestError && caught.status === 409) {
        setConfirmation(null)
        await loadStudio(cohortId)
        setError('Release readiness changed before the record was sealed. Review the latest cohort evidence before trying again.')
        window.requestAnimationFrame(() => restoreFocusRef.current?.focus())
      } else if (caught instanceof ApiRequestError && caught.status === 403) {
        setConfirmation(null)
        await loadStudio(cohortId)
        setError('Your release permission changed. The latest cohort view is loaded below.')
        window.requestAnimationFrame(() => restoreFocusRef.current?.focus())
      } else if (caught instanceof ApiRequestError && caught.status >= 400 && caught.status < 500) {
        setConfirmation(null)
        const message = releaseErrorMessage(caught, 'The release record could not be sealed. Review the latest evidence and try again.')
        await loadStudio(cohortId)
        setError(message)
        window.requestAnimationFrame(() => restoreFocusRef.current?.focus())
      } else {
        setActionError(releaseErrorMessage(caught, 'The release record could not be sealed.'))
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
          <p>{studio?.runtime_truth.message ?? 'Sealing or restoring a record does not change the brand, assistant, or tools participants use.'}</p>
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
                <p className="eyebrow">Exact readiness</p>
                <h3 ref={releaseStateHeadingRef} tabIndex={-1}>{studio.candidate?.ready ? 'Ready to seal' : 'Needs attention before sealing'}</h3>
              </div>
              <span className={`cohort-release-state ${studio.candidate?.ready ? 'is-ready' : ''}`}>{studio.candidate?.ready ? 'Ready' : 'Blocked'}</span>
            </header>

            <ol className="cohort-release-checklist">
              {displayedChecks.map((check) => (
                <li key={check.key} className={check.ready ? 'is-ready' : ''}>
                  <span aria-hidden="true">{check.ready ? <CheckIcon /> : <PendingIcon />}</span>
                  <div><strong>{check.label}</strong><small>{check.detail ?? (check.ready ? 'Exact evidence is ready.' : 'Complete this requirement before sealing.')}</small></div>
                  <b>{check.ready ? 'Ready' : 'Needed'}<span className="sr-only">: {check.label}</span></b>
                </li>
              ))}
            </ol>

            {studio.candidate?.blockers && studio.candidate.blockers.length > 0 && (
              <div className="cohort-release-blockers" role="note">
                <strong>What needs attention</strong>
                <ul>{studio.candidate.blockers.map((blocker) => <li key={blocker}>{blocker}</li>)}</ul>
              </div>
            )}
            {studio.candidate?.warnings && studio.candidate.warnings.length > 0 && (
              <div className="cohort-release-warnings" role="note">
                <strong>Review before sealing</strong>
                <ul>{studio.candidate.warnings.map((warning) => <li key={warning}>{warning}</li>)}</ul>
              </div>
            )}

            {studio.candidate && (
              <dl className="cohort-release-evidence">
                <div><dt>Brand version</dt><dd>{brandEvidenceLabel(studio.candidate.brand_mode, studio.candidate.brand_version_id)}</dd></div>
                <div><dt>Assistant version</dt><dd>{studio.candidate.persona_version_id ?? 'Neutral built-in voice'}</dd></div>
                <div><dt>Participant tools version</dt><dd>{studio.candidate.experience_version_id ?? 'Safe default tools'}</dd></div>
                <div className="is-wide"><dt>Bundle fingerprint</dt><dd>{shortDigest(studio.candidate.bundle_digest)}</dd></div>
              </dl>
            )}

            <div className="cohort-release-actions">
              {studio.permissions.seal ? (
                <Button
                  onClick={requestSeal}
                  disabled={!studio.candidate?.ready || !studio.candidate.seal_needed || studio.latest_release_match || pendingAction !== null || mutationLifecycle.pending}
                >
                  {pendingAction === 'seal' ? 'Sealing record' : studio.latest_release_match || !studio.candidate?.seal_needed ? 'Latest evidence already sealed' : 'Review and seal record'}
                </Button>
              ) : <p className="coach-read-only">You can review release evidence, but this cohort or your role does not allow sealing records.</p>}
              {(studio.latest_release_match || studio.candidate?.seal_needed === false) && <p className="cohort-release-noop" role="status">The latest sealed record already matches this exact brand, assistant, and tool bundle.</p>}
            </div>
          </article>

          <article className="panel cohort-release-history">
            <header>
              <div><p className="eyebrow">Immutable history</p><h3>{historyLabel}</h3></div>
            </header>
            {releases.length === 0 ? (
              <div className="cohort-release-empty"><strong>No release records yet.</strong><p>Seal the ready evidence to create this cohort's first record.</p></div>
            ) : (
              <ol>
                {releases.map((release, index) => (
                  <li key={release.id}>
                    <header>
                      <div>
                        <strong>{index === 0 ? 'Latest sealed record' : `Release record ${release.release_number}`}</strong>
                        <small>{formatReleaseEvent(release)} · {formatReleaseDate(release.released_at)}</small>
                      </div>
                      <span>#{release.release_number}</span>
                    </header>
                    <dl>
                      <div><dt>Sealed by</dt><dd>{release.actor?.full_name ?? (release.actor_user_id ? `Authorized user #${release.actor_user_id}` : 'System record')}</dd></div>
                      <div><dt>Brand version</dt><dd>{brandEvidenceLabel(release.brand_mode, release.brand_version_id)}</dd></div>
                      <div><dt>Fingerprint</dt><dd>{shortDigest(release.bundle_digest)}</dd></div>
                    </dl>
                    {release.source_release_id && <p>Restored from release record #{release.source_release_id}.</p>}
                    {release.restore_allowed && studio.permissions.restore && restoreExpectedLatestReleaseId !== null ? (
                      <Button size="compact" variant="secondary" onClick={(event) => requestRestore(event, release)} disabled={pendingAction !== null || mutationLifecycle.pending}>Review restore record</Button>
                    ) : release.restore_allowed && studio.permissions.restore ? (
                      <small className="cohort-release-restore-reason">Restore unavailable: latest release evidence is unavailable. Reload the cohort and try again.</small>
                    ) : index !== 0 && release.restore_reason ? (
                      <small className="cohort-release-restore-reason">Restore unavailable: {release.restore_reason}</small>
                    ) : null}
                  </li>
                ))}
              </ol>
            )}
          </article>
        </div>
      ) : null}

      {confirmation && studio && (
        <ReleaseConfirmationDialog
          confirmation={confirmation}
          cohortName={studio.cohort.name}
          brandLabel={confirmation.kind === 'restore'
            ? brandEvidenceLabel(confirmation.release?.brand_mode ?? '', confirmation.release?.brand_version_id ?? null)
            : brandEvidenceLabel(studio.candidate?.brand_mode ?? '', studio.candidate?.brand_version_id ?? null)}
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
  pending,
  error,
  onCancel,
  onConfirm,
}: {
  confirmation: Confirmation
  cohortName: string
  brandLabel: string | number
  pending: boolean
  error: string | null
  onCancel: () => void
  onConfirm: () => void
}) {
  const dialogRef = useRef<HTMLElement | null>(null)
  const cancelRef = useRef<HTMLButtonElement | null>(null)

  useEffect(() => {
    cancelRef.current?.focus()
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
    if (event.shiftKey && document.activeElement === first) {
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
      <section ref={dialogRef} className="cohort-release-modal" role="dialog" aria-modal="true" aria-labelledby="cohort-release-modal-title" aria-describedby="cohort-release-modal-copy" onKeyDown={trapFocus}>
        <p className="eyebrow">Final review</p>
        <h3 id="cohort-release-modal-title">{restoring ? `Restore record #${confirmation.release?.release_number}` : 'Seal this release record?'}</h3>
        <p id="cohort-release-modal-copy">This creates immutable audit evidence for {cohortName}. It does not change the brand, assistant, or tools participants use.</p>
        <dl className="cohort-rollout-confirmation-summary">
          <div><dt>Cohort</dt><dd>{cohortName}</dd></div>
          <div><dt>{restoring ? 'Historical brand' : 'Brand version'}</dt><dd>{brandLabel}</dd></div>
        </dl>
        {restoring && <p className="cohort-release-modal-note">A restore preserves the selected historical bundle as a new record. Existing history remains unchanged.</p>}
        {error && <p className="coach-studio-alert is-error" role="alert">{error}</p>}
        <div className="cohort-release-modal-actions">
          <button ref={cancelRef} type="button" className="button button--ghost button--default" onClick={onCancel} disabled={pending}>Cancel</button>
          <Button onClick={onConfirm} disabled={pending}>{pending ? 'Sealing record' : restoring ? 'Seal restore record' : 'Seal release record'}</Button>
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
  if (versionId !== null) return versionId
  if (mode === 'legacy_household_cfo_builtin') return 'Household CFO legacy brand'
  return 'Built-in brand'
}

function releaseErrorMessage(caught: unknown, fallback: string) {
  return caught instanceof Error && caught.message ? caught.message : fallback
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
