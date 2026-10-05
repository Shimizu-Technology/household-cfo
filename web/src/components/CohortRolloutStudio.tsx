import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent, type MouseEvent } from 'react'
import {
  ApiRequestError,
  advanceCohortRollout,
  cancelCohortRollout,
  createCohortRolloutRequestId,
  fetchCohortRolloutStudio,
  pauseCohortRollout,
  planCohortRollout,
  resumeCohortRollout,
  rollbackCohortRollout,
} from '../api'
import type { CohortRolloutMutationResponse, CohortRolloutParticipant, CohortRolloutPlanInput, CohortRolloutRecord, CohortRolloutRelease, CohortRolloutStudio as CohortRolloutStudioData, CohortRolloutWave } from '../api'
import {
  cohortRolloutPlanDirty,
  defaultCohortRolloutPlan,
  nextCohortRolloutWaveKey,
  serializeCohortRolloutPlan,
  type CohortRolloutPlanDraft,
} from '../lib/cohortRolloutPlan'
import { Button } from './Button'
import type { CoachWorkspaceMutationLifecycle } from './coachWorkspaceMutationLifecycle'

type Action = 'plan' | 'advance' | 'pause' | 'resume' | 'cancel' | 'rollback'
type Confirmation = { action: Action; requestId: string }

export function CohortRolloutStudio({ cohortId, mutationLifecycle, onDirtyChange }: {
  cohortId: number | null
  mutationLifecycle: CoachWorkspaceMutationLifecycle
  onDirtyChange: (dirty: boolean) => void
}) {
  const [studio, setStudio] = useState<CohortRolloutStudioData | null>(null)
  const [draft, setDraft] = useState<CohortRolloutPlanDraft | null>(null)
  const [pendingAction, setPendingAction] = useState<'load' | Action | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [confirmation, setConfirmation] = useState<Confirmation | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [focusVersion, setFocusVersion] = useState(0)
  const [validationErrors, setValidationErrors] = useState<string[]>([])
  const loadRequestRef = useRef(0)
  const loadAbortRef = useRef<AbortController | null>(null)
  const restoreFocusRef = useRef<HTMLElement | null>(null)
  const studioRootRef = useRef<HTMLElement | null>(null)
  const loadFailureRetryRef = useRef<HTMLButtonElement | null>(null)

  const loadStudio = useCallback(async (selectedCohortId: number) => {
    const requestId = ++loadRequestRef.current
    loadAbortRef.current?.abort()
    const abortController = new AbortController()
    loadAbortRef.current = abortController
    setPendingAction('load')
    setError(null)
    try {
      const next = await fetchCohortRolloutStudio(selectedCohortId, abortController.signal)
      if (requestId !== loadRequestRef.current || abortController.signal.aborted) return false
      if (next.cohort.id !== selectedCohortId) throw new Error('Rollout records returned the wrong cohort. Reload and try again.')
      setStudio(next)
      setDraft(next.open_rollout ? null : defaultCohortRolloutPlan(next))
      setValidationErrors([])
      return true
    } catch (caught) {
      if (requestId !== loadRequestRef.current || abortController.signal.aborted) return false
      setStudio(null)
      setDraft(null)
      setError(errorMessage(caught, 'Cohort rollout records could not be loaded.'))
      return false
    } finally {
      if (requestId === loadRequestRef.current) {
        loadAbortRef.current = null
        setPendingAction(null)
      }
    }
  }, [])

  useEffect(() => {
    queueMicrotask(() => {
      loadRequestRef.current += 1
      loadAbortRef.current?.abort()
      setStudio(null)
      setDraft(null)
      setError(null)
      setNotice(null)
      setConfirmation(null)
      if (cohortId) void loadStudio(cohortId)
    })
  }, [cohortId, loadStudio])

  useEffect(() => () => {
    loadRequestRef.current += 1
    loadAbortRef.current?.abort()
    onDirtyChange(false)
  }, [onDirtyChange])

  const dirty = Boolean(studio && draft && !studio.open_rollout && cohortRolloutPlanDirty(studio, draft))
  useEffect(() => onDirtyChange(dirty), [dirty, onDirtyChange])

  const planValidation = useMemo(() => studio && draft ? serializeCohortRolloutPlan(studio, draft) : null, [draft, studio])
  const rollout = studio?.open_rollout ?? null

  function updateWaveName(key: string, name: string) {
    setDraft((current) => current && ({ ...current, waves: current.waves.map((wave) => wave.key === key ? { ...wave, name } : wave) }))
  }

  function addWave() {
    setDraft((current) => {
      if (!current || current.waves.length >= 25) return current
      const key = nextCohortRolloutWaveKey(current)
      const waves = current.waves.length === 1 && current.waves[0].name === 'All participants'
        ? [{ ...current.waves[0], name: 'Wave 1' }]
        : current.waves
      return { ...current, waves: [...waves, { key, name: `Wave ${current.waves.length + 1}` }] }
    })
  }

  function removeWave(key: string) {
    setDraft((current) => {
      if (!current || current.waves.length <= 1) return current
      let waves = current.waves.filter((wave) => wave.key !== key)
      if (waves.length === 1 && /^Wave \d+$/.test(waves[0].name)) waves = [{ ...waves[0], name: 'All participants' }]
      const fallback = waves[0].key
      return {
        waves,
        participantWaveKeys: Object.fromEntries(Object.entries(current.participantWaveKeys).map(([userId, waveKey]) => [userId, waveKey === key ? fallback : waveKey])),
      }
    })
  }

  function assignParticipant(userId: number, waveKey: string) {
    setDraft((current) => current && ({ ...current, participantWaveKeys: { ...current.participantWaveKeys, [userId]: waveKey } }))
  }

  function requestAction(event: MouseEvent<HTMLButtonElement>, action: Action) {
    if (action === 'plan' && planValidation?.errors.length) {
      setValidationErrors(planValidation.errors)
      return
    }
    restoreFocusRef.current = event.currentTarget
    setActionError(null)
    setValidationErrors([])
    setConfirmation({ action, requestId: createCohortRolloutRequestId() })
  }

  const closeConfirmation = useCallback(() => {
    setConfirmation(null)
    setActionError(null)
    window.requestAnimationFrame(() => restoreFocusRef.current?.focus())
  }, [])

  const focusCurrentState = useCallback(() => {
    setFocusVersion((version) => version + 1)
  }, [])

  // Restore focus after React commits the refreshed state. Animation frames
  // can be suspended in background Safari tabs and are not a commit boundary.
  useLayoutEffect(() => {
    if (focusVersion > 0) studioRootRef.current?.querySelector<HTMLElement>('[data-rollout-focus-target]')?.focus()
  }, [focusVersion])

  async function confirmAction() {
    if (!confirmation || !studio || !cohortId || pendingAction || mutationLifecycle.pending) return
    const action = confirmation.action
    const mutation = mutationLifecycle.begin()
    setPendingAction(action)
    setActionError(null)
    try {
      let result: CohortRolloutMutationResponse | null = null
      if (action === 'plan') {
        if (!planValidation?.input) {
          setValidationErrors(planValidation?.errors ?? ['The rollout plan is incomplete.'])
          setConfirmation(null)
          return
        }
        result = await planCohortRollout(cohortId, planValidation.input, confirmation.requestId)
      } else {
        if (!rollout || rollout.latest_transition_id === null) throw new Error('The latest rollout evidence is unavailable. Reload and try again.')
        const compare = transitionInput(rollout)
        if (action === 'advance') result = await advanceCohortRollout(cohortId, rollout.id, { ...compare, readiness_digest: rollout.next_wave_readiness_digest }, confirmation.requestId)
        else if (action === 'pause') result = await pauseCohortRollout(cohortId, rollout.id, compare, confirmation.requestId)
        else if (action === 'resume') result = await resumeCohortRollout(cohortId, rollout.id, compare, confirmation.requestId)
        else if (action === 'cancel') result = await cancelCohortRollout(cohortId, rollout.id, compare, confirmation.requestId)
        if (action === 'rollback') {
          if (!rollout.rollback_candidate) throw new Error('No verified rollback release is available. Reload and review the blockers.')
          result = await rollbackCohortRollout(cohortId, rollout.id, { ...compare, rollback_release_id: rollout.rollback_candidate.id }, confirmation.requestId)
        }
      }
      if (!mutationLifecycle.isCurrent(mutation)) return
      if (!result) throw new Error('The rollout action did not return a result. Reload and try again.')
      setConfirmation(null)
      setNotice(successMessage(action, result, rollout))
      await loadStudio(cohortId)
      focusCurrentState()
    } catch (caught) {
      if (!mutationLifecycle.isCurrent(mutation)) return
      if (caught instanceof ApiRequestError && (caught.status === 409 || caught.status === 403)) {
        setConfirmation(null)
        const refreshed = await loadStudio(cohortId)
        if (refreshed) {
          setError(caught.status === 409
            ? 'Rollout evidence changed before this action completed. Review the refreshed state before trying again.'
            : 'Your rollout permission changed. Review the refreshed state before trying again.')
          focusCurrentState()
        } else {
          window.requestAnimationFrame(() => loadFailureRetryRef.current?.focus())
        }
      } else if (caught instanceof ApiRequestError && caught.status >= 400 && caught.status < 500) {
        setConfirmation(null)
        setError(errorMessage(caught, 'The rollout action was rejected. Review the plan and try again.'))
        window.requestAnimationFrame(() => restoreFocusRef.current?.focus())
      } else {
        setActionError(errorMessage(caught, 'The rollout action could not be completed.'))
      }
    } finally {
      if (mutationLifecycle.isCurrent(mutation)) setPendingAction(null)
      mutationLifecycle.finish(mutation)
    }
  }

  if (!cohortId) return null
  if (pendingAction === 'load' && !studio) return <article className="panel cohort-release-loading" role="status">Checking rollout evidence and participant readiness…</article>
  if (error && !studio) return <div className="coach-studio-alert is-error" role="alert"><span>{error}</span><button ref={loadFailureRetryRef} type="button" onClick={() => void loadStudio(cohortId)}>Retry</button></div>
  if (!studio) return null

  return (
    <section ref={studioRootRef} className="cohort-rollout-studio" aria-busy={pendingAction !== null || mutationLifecycle.pending}>
      {error && <div className="coach-studio-alert is-error" role="alert"><span>{error}</span><button type="button" onClick={() => void loadStudio(cohortId)}>Reload</button></div>}
      {notice && <p className="coach-studio-alert is-success" role="status">{notice}</p>}

      {rollout ? <ActiveRollout rollout={rollout} studio={studio} pending={pendingAction !== null || mutationLifecycle.pending} onAction={requestAction} /> : (
        <PlanBuilder
          studio={studio}
          draft={draft}
          validationErrors={validationErrors}
          pending={pendingAction !== null || mutationLifecycle.pending}
          onWaveNameChange={updateWaveName}
          onAddWave={addWave}
          onRemoveWave={removeWave}
          onAssignParticipant={assignParticipant}
          onReset={() => { setDraft(defaultCohortRolloutPlan(studio)); setValidationErrors([]) }}
          onPlan={(event) => requestAction(event, 'plan')}
        />
      )}

      <RolloutHistory studio={studio} />
      {confirmation && (
        <RolloutConfirmationDialog
          confirmation={confirmation}
          rollout={rollout}
          studio={studio}
          plan={planValidation?.input ?? null}
          pending={pendingAction === confirmation.action}
          error={actionError}
          onCancel={closeConfirmation}
          onConfirm={() => void confirmAction()}
        />
      )}
    </section>
  )
}

function PlanBuilder({ studio, draft, validationErrors, pending, onWaveNameChange, onAddWave, onRemoveWave, onAssignParticipant, onReset, onPlan }: {
  studio: CohortRolloutStudioData
  draft: CohortRolloutPlanDraft | null
  validationErrors: string[]
  pending: boolean
  onWaveNameChange: (key: string, name: string) => void
  onAddWave: () => void
  onRemoveWave: (key: string) => void
  onAssignParticipant: (userId: number, key: string) => void
  onReset: () => void
  onPlan: (event: MouseEvent<HTMLButtonElement>) => void
}) {
  if (!draft) return null
  return (
    <div className="cohort-rollout-plan-layout">
      <article className="panel cohort-rollout-plan">
        <header>
          <div><p className="eyebrow">Plan rollout</p><h3 tabIndex={-1} data-rollout-focus-target>{studio.latest_release ? `Release #${studio.latest_release.release_number}` : 'Release required'}</h3></div>
          <span className={`cohort-release-state ${studio.permissions.plan ? 'is-ready' : ''}`}>{studio.permissions.plan ? 'Ready' : 'Blocked'}</span>
        </header>
        <p>Start with everyone together, or add waves for a smaller first group. Each participant must belong to exactly one wave.</p>
        {studio.active_release && studio.latest_release && (
          <p className="cohort-rollout-runtime-summary"><strong>Active now:</strong> Release #{studio.active_release.release_number} <span aria-hidden="true">→</span> <strong>Rollout target:</strong> Release #{studio.latest_release.release_number}</p>
        )}
        {(studio.permissions.plan_blockers.length > 0 || studio.permissions.blockers.length > 0) && (
          <div className="cohort-release-blockers" role="note"><strong>What needs attention</strong><ul>{[...studio.permissions.blockers, ...studio.permissions.plan_blockers].map((item) => <li key={item}>{item}</li>)}</ul></div>
        )}
        {validationErrors.length > 0 && <div className="coach-studio-alert is-error" role="alert"><span>{validationErrors.join(' ')}</span></div>}

        <div className="cohort-rollout-wave-editor">
          <div className="cohort-rollout-wave-heading"><div><strong>Waves</strong><small>Up to 25 ordered waves</small></div><Button variant="secondary" size="compact" onClick={onAddWave} disabled={pending || draft.waves.length >= 25}>Add wave</Button></div>
          {draft.waves.map((wave, index) => (
            <div className="cohort-rollout-wave-name" key={wave.key}>
              <label><span>Wave {index + 1} name</span><input value={wave.name} maxLength={80} onChange={(event) => onWaveNameChange(wave.key, event.target.value)} disabled={pending} /></label>
              {draft.waves.length > 1 && <button type="button" onClick={() => onRemoveWave(wave.key)} disabled={pending} aria-label={`Remove ${wave.name || `wave ${index + 1}`}`}>Remove</button>}
            </div>
          ))}
        </div>

        <div className="cohort-rollout-roster-editor">
          <header><strong>Participant assignments</strong><span>{studio.current_roster.total_count} total</span></header>
          {studio.current_roster.participants.map((participant) => (
            <div className="cohort-rollout-participant-row" key={participant.user_id}>
              <div><strong>{participant.full_name}</strong><small>{readinessLabel(participant.readiness)} · {effectiveReleaseLabel(participant.effective_release)}</small></div>
              <label><span className="sr-only">Wave for {participant.full_name}</span><select value={draft.participantWaveKeys[participant.user_id] ?? ''} onChange={(event) => onAssignParticipant(participant.user_id, event.target.value)} disabled={pending}>{draft.waves.map((wave, index) => <option key={wave.key} value={wave.key}>{index + 1}. {wave.name || 'Unnamed wave'}</option>)}</select></label>
            </div>
          ))}
        </div>
        <div className="cohort-rollout-plan-actions">
          <Button onClick={onPlan} disabled={pending || !studio.permissions.plan}>Review rollout plan</Button>
          <Button variant="ghost" onClick={onReset} disabled={pending}>Reset to one wave</Button>
        </div>
      </article>
      <RosterReadiness studio={studio} />
    </div>
  )
}

function ActiveRollout({ rollout, studio, pending, onAction }: {
  rollout: CohortRolloutRecord
  studio: CohortRolloutStudioData
  pending: boolean
  onAction: (event: MouseEvent<HTMLButtonElement>, action: Action) => void
}) {
  const status = titleize(rollout.status)
  const nextPosition = rollout.next_wave_position
  const runtimeModeSupported = rollout.runtime_mode === 'release_runtime_v2' || rollout.runtime_mode === 'legacy_record_only_v1'
  const legacy = rollout.runtime_mode === 'legacy_record_only_v1'
  const advanceLabel = rollout.status === 'planned' ? 'Review and start rollout' : nextPosition ? `Review wave ${nextPosition}` : 'Review and complete rollout'
  return <div className="cohort-rollout-active-layout">
    <article className="panel cohort-rollout-current">
      <header><div><p className="eyebrow">Current rollout</p><h3 tabIndex={-1} data-rollout-focus-target>Release #{rollout.target_release.release_number}</h3></div><span className={`cohort-rollout-status is-${rollout.status}`}>{status}</span></header>
      {!runtimeModeSupported ? (
        <div className="cohort-rollout-legacy" role="alert"><strong>Update required before rollout changes</strong><p>This app does not recognize runtime mode “{rollout.runtime_mode}”. Reload after updating the app; no lifecycle action is available from this screen.</p></div>
      ) : legacy ? (
        <div className="cohort-rollout-legacy" role="note"><strong>Pre-cutover rollout · record only</strong><p>{rollout.runtime_blocker ?? 'This legacy rollout cannot activate participant release runtime. Close it before planning a runtime rollout.'}</p></div>
      ) : (
        <div className="cohort-rollout-runtime-summary" role="status"><strong>Captured baseline:</strong> {releaseLabel(rollout.baseline_release)} · {brandEvidenceLabel(rollout.baseline_release)} <span aria-hidden="true">→</span> <strong>Target:</strong> Release #{rollout.target_release.release_number} · {brandEvidenceLabel(rollout.target_release)}</div>
      )}
      <div className="cohort-rollout-progress" aria-label={rolloutProgressLabel(rollout)}>
        {rollout.waves.map((wave) => <span key={wave.id} className={wave.completed ? 'is-complete' : wave.active ? 'is-active' : ''}><i />Wave {wave.position}</span>)}
      </div>
      <div className="cohort-rollout-wave-list">
        {rollout.waves.map((wave) => <section key={wave.id} className={wave.active ? 'is-active' : wave.completed ? 'is-complete' : ''}>
          <header><div><strong>{wave.position}. {wave.name}</strong><small>{wave.participant_count} participant{wave.participant_count === 1 ? '' : 's'}{rollout.runtime_mode === 'release_runtime_v2' && (wave.active || wave.completed) ? ` · ${wave.exposed_count}/${wave.participant_count} exposed` : ''}</small></div><b>{waveStateLabel(wave, rollout.runtime_mode)}</b></header>
          <ul>{wave.participants.map((participant) => <li key={participant.user_id}><span>{participant.full_name}</span><small>{readinessLabel(participant.readiness)} · {participantExposureLabel(participant, rollout.target_release.release_number, rollout.runtime_mode)}</small></li>)}</ul>
        </section>)}
      </div>
      {rollout.permissions.advance_blockers.length > 0 && <div className="cohort-release-blockers" role="note"><strong>Before the next wave</strong><ul>{rollout.permissions.advance_blockers.map((item) => <li key={item}>{item}</li>)}</ul></div>}
      {runtimeModeSupported && <div className="cohort-rollout-lifecycle-actions">
        {rollout.permissions.advance && <Button onClick={(event) => onAction(event, 'advance')} disabled={pending}>{advanceLabel}</Button>}
        {rollout.permissions.pause && <Button variant="secondary" onClick={(event) => onAction(event, 'pause')} disabled={pending}>Review pause</Button>}
        {rollout.permissions.resume && <Button onClick={(event) => onAction(event, 'resume')} disabled={pending}>Review resume</Button>}
        {rollout.permissions.cancel && <Button variant="danger" onClick={(event) => onAction(event, 'cancel')} disabled={pending}>Review cancellation</Button>}
        {rollout.permissions.rollback && <Button variant="danger" onClick={(event) => onAction(event, 'rollback')} disabled={pending}>Review rollback</Button>}
      </div>}
      {rollout.permissions.rollback_blockers.length > 0 && rollout.status !== 'planned' && <small className="cohort-rollout-action-note">Rollback unavailable: {rollout.permissions.rollback_blockers.join(' ')}</small>}
      <p className="cohort-rollout-runtime-note">{!runtimeModeSupported ? 'Lifecycle changes are blocked until this app understands the returned runtime mode.' : legacy ? 'Legacy lifecycle actions close this pre-cutover record without changing participant runtime.' : studio.runtime_truth.message}</p>
    </article>
    <article className="panel cohort-rollout-transition-history">
      <header><div><p className="eyebrow">Decision history</p><h3>{historyLabel(rollout.transition_history.total_count, rollout.transitions.length, rollout.transition_history.truncated, 'event')}</h3></div></header>
      <ol>{rollout.transitions.map((transition) => <li key={transition.id}><strong>{titleize(transition.event_type)}</strong><small>{formatDate(transition.occurred_at)} · {transition.actor?.full_name ?? 'System record'}</small><span>{titleize(transition.to_status)}{transition.to_wave_position > 0 ? ` · Wave ${transition.to_wave_position}` : ''} · {rollout.runtime_mode === 'release_runtime_v2' ? transition.participant_runtime_changed ? 'Runtime changed' : 'Runtime unchanged' : rollout.runtime_mode === 'legacy_record_only_v1' ? 'Legacy record only' : 'Runtime mode unavailable'}</span></li>)}</ol>
    </article>
  </div>
}

function RosterReadiness({ studio }: { studio: CohortRolloutStudioData }) {
  const counts = studio.current_roster.counts
  return <article className="panel cohort-rollout-roster-readiness">
    <header><div><p className="eyebrow">Roster readiness</p><h3>{counts.ready} of {studio.current_roster.total_count} ready</h3></div></header>
    <dl><div><dt>Ready</dt><dd>{counts.ready}</dd></div><div><dt>Awaiting acceptance</dt><dd>{counts.awaiting_acceptance}</dd></div><div><dt>Revoked</dt><dd>{counts.revoked}</dd></div><div><dt>Removed</dt><dd>{counts.removed}</dd></div></dl>
    <p>Readiness is checked again when each wave advances. A changed roster or invitation state requires a fresh review.</p>
  </article>
}

function RolloutHistory({ studio }: { studio: CohortRolloutStudioData }) {
  return <article className="panel cohort-rollout-history">
    <header><div><p className="eyebrow">Rollout history</p><h3>{historyLabel(studio.history.total_count, studio.rollouts.length, studio.history.truncated, 'rollout')}</h3></div></header>
    {studio.rollouts.length === 0 ? <div className="cohort-release-empty"><strong>No rollout records yet.</strong><p>A reviewed plan will appear here.</p></div> : <ol>{studio.rollouts.map((rollout) => <li key={rollout.id}><div><strong>Release #{rollout.target_release.release_number}</strong><small>{formatDate(rollout.planned_at)} · {rollout.planned_by?.full_name ?? 'System record'}</small></div><span className={`cohort-rollout-status is-${rollout.status}`}>{titleize(rollout.status)}</span><p>{rollout.wave_count} wave{rollout.wave_count === 1 ? '' : 's'} · {rollout.participant_count} participant{rollout.participant_count === 1 ? '' : 's'} · {rollout.runtime_mode === 'release_runtime_v2' ? rollout.participant_runtime_changed ? 'Runtime exposure recorded' : 'Runtime ready' : rollout.runtime_mode === 'legacy_record_only_v1' ? 'Legacy record only' : 'Runtime mode unavailable'}</p></li>)}</ol>}
  </article>
}

function RolloutConfirmationDialog({ confirmation, rollout, studio, plan, pending, error, onCancel, onConfirm }: {
  confirmation: Confirmation
  rollout: CohortRolloutRecord | null
  studio: CohortRolloutStudioData
  plan: CohortRolloutPlanInput | null
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
    const escape = (event: globalThis.KeyboardEvent) => { if (event.key === 'Escape' && !pending) onCancel() }
    document.addEventListener('keydown', escape)
    return () => document.removeEventListener('keydown', escape)
  }, [onCancel, pending])
  function trapFocus(event: KeyboardEvent<HTMLElement>) {
    if (event.key !== 'Tab') return
    const focusable = Array.from(dialogRef.current?.querySelectorAll<HTMLElement>('button:not(:disabled), [href], input:not(:disabled), select:not(:disabled), [tabindex]:not([tabindex="-1"])') ?? [])
    if (!focusable.length) return
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (document.activeElement === dialogRef.current) { event.preventDefault(); (event.shiftKey ? last : first).focus() }
    else if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus() }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus() }
  }
  const copy = confirmationCopy(confirmation.action, rollout, studio)
  const details = confirmationDetails(confirmation.action, rollout, studio, plan)
  return <div className="cohort-release-modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget && !pending) onCancel() }}>
    <section ref={dialogRef} className="cohort-release-modal" tabIndex={-1} role="dialog" aria-modal="true" aria-labelledby="cohort-rollout-modal-title" aria-describedby="cohort-rollout-modal-copy" onKeyDown={trapFocus}>
      <p className="eyebrow">Final review</p><h3 id="cohort-rollout-modal-title">{copy.title}</h3><p id="cohort-rollout-modal-copy">{copy.body}</p>
      <dl className="cohort-rollout-confirmation-summary">
        <div><dt>Cohort</dt><dd>{studio.cohort.name}</dd></div>
        {details.map((detail) => <div key={`${detail.label}-${detail.value}`}><dt>{detail.label}</dt><dd>{detail.value}</dd></div>)}
      </dl>
      {error && <p className="coach-studio-alert is-error" role="alert">{error}</p>}
      <div className="cohort-release-modal-actions"><button ref={cancelRef} type="button" className="button button--ghost button--default" onClick={onCancel} disabled={pending}>Cancel</button><Button variant={copy.danger ? 'danger' : 'primary'} onClick={onConfirm} disabled={pending}>{pending ? 'Recording decision…' : copy.confirm}</Button></div>
    </section>
  </div>
}

function transitionInput(rollout: CohortRolloutRecord) {
  if (rollout.latest_transition_id === null) throw new Error('Latest transition evidence is unavailable.')
  return { expected_status: rollout.status, expected_current_wave_position: rollout.current_wave_position, expected_latest_transition_id: rollout.latest_transition_id }
}

function confirmationCopy(action: Action, rollout: CohortRolloutRecord | null, studio: CohortRolloutStudioData) {
  if (action === 'plan') return { title: 'Record this rollout plan?', body: `This locks the wave assignments for release #${studio.latest_release?.release_number}. Planning does not change participant runtime; the first wave changes when you start it.`, confirm: 'Record rollout plan', danger: false }
  const legacy = rollout?.runtime_mode !== 'release_runtime_v2'
  if (action === 'advance') {
    const wave = rollout?.waves.find((candidate) => candidate.position === rollout.next_wave_position)
    const completing = !wave
    const body = legacy
      ? 'This pre-cutover action only advances the legacy record. It does not change participant runtime.'
      : completing
        ? `Completing makes release #${rollout?.target_release.release_number} the cohort default immediately.`
        : `This immediately moves ${wave.participant_count} participant${wave.participant_count === 1 ? '' : 's'} in ${wave.name} to release #${rollout?.target_release.release_number}.`
    return { title: rollout?.status === 'planned' ? 'Start this rollout?' : wave ? `Advance to wave ${wave.position}?` : 'Complete this rollout?', body, confirm: rollout?.status === 'planned' ? 'Start rollout' : wave ? `Advance to wave ${wave.position}` : 'Complete rollout', danger: false }
  }
  if (action === 'pause') return { title: 'Pause this rollout?', body: 'Pausing does not change anyone’s current release. The rollout stays paused until an authorized owner or reviewer resumes or rolls it back.', confirm: 'Pause rollout', danger: false }
  if (action === 'resume') return { title: 'Resume this rollout?', body: 'Resuming does not change anyone’s current release. Readiness is checked again before the next wave advances.', confirm: 'Resume rollout', danger: false }
  if (action === 'cancel') return { title: 'Cancel this rollout plan?', body: 'Cancellation is final for this unstarted plan and does not change participant runtime. Its audit history remains available.', confirm: 'Cancel rollout plan', danger: true }
  return legacy
    ? { title: 'Close this pre-cutover rollout?', body: 'This records a legacy rollback and closes the pre-cutover rollout without changing participant runtime.', confirm: 'Record legacy rollback', danger: true }
    : { title: `Roll back to release #${rollout?.rollback_candidate?.release_number}?`, body: `This immediately restores captured baseline release #${rollout?.baseline_release?.release_number} for every still-current enrollment exposed by this rollout.`, confirm: 'Roll back participant runtime', danger: true }
}

function confirmationDetails(action: Action, rollout: CohortRolloutRecord | null, studio: CohortRolloutStudioData, plan: CohortRolloutPlanInput | null) {
  if (action === 'plan' && plan) {
    return [
      { label: 'Target release', value: `Release #${studio.latest_release?.release_number ?? 'unavailable'}` },
      { label: 'Target brand', value: brandEvidenceLabel(studio.latest_release) },
      { label: 'Wave count', value: `${plan.waves.length}` },
      ...plan.waves.map((wave, index) => ({
        label: `Wave ${index + 1}`,
        value: `${wave.name} · ${wave.user_ids.length} participant${wave.user_ids.length === 1 ? '' : 's'}`,
      })),
      { label: 'Runtime effect', value: 'None until the first wave starts' },
    ]
  }
  if (!rollout) return []
  if (action === 'advance') {
    const wave = rollout.waves.find((candidate) => candidate.position === rollout.next_wave_position)
    return wave ? [
      { label: rollout.status === 'planned' ? 'Starting wave' : 'Advancing to', value: `${wave.position}. ${wave.name}` },
      { label: 'Participants', value: `${wave.participant_count}` },
      { label: 'Target release', value: `Release #${rollout.target_release.release_number}` },
      { label: 'Target brand', value: brandEvidenceLabel(rollout.target_release) },
      { label: 'Runtime effect', value: rollout.runtime_mode === 'release_runtime_v2' ? 'This wave changes immediately' : 'Legacy record only · no runtime change' },
    ] : [
      { label: 'Decision', value: 'Complete rollout' },
      { label: 'Completed waves', value: `${rollout.wave_count}` },
      { label: 'Target release', value: `Release #${rollout.target_release.release_number}` },
      { label: 'Target brand', value: brandEvidenceLabel(rollout.target_release) },
      { label: 'Runtime effect', value: rollout.runtime_mode === 'release_runtime_v2' ? 'Becomes the cohort default immediately' : 'Legacy record only · no runtime change' },
    ]
  }
  if (action === 'rollback') return [
    { label: 'Rollback to', value: `Release #${rollout.rollback_candidate?.release_number ?? 'unavailable'}` },
    { label: 'Rollback brand', value: brandEvidenceLabel(rollout.rollback_candidate) },
    { label: 'Current target', value: `Release #${rollout.target_release.release_number}` },
    { label: 'Runtime effect', value: rollout.runtime_mode === 'release_runtime_v2' ? 'Still-current exposed enrollments return to baseline' : 'Legacy record only · no runtime change' },
  ]
  if (action === 'cancel') return [
    { label: 'Target release', value: `Release #${rollout.target_release.release_number}` },
    { label: 'Target brand', value: brandEvidenceLabel(rollout.target_release) },
    { label: 'Plan size', value: `${rollout.wave_count} wave${rollout.wave_count === 1 ? '' : 's'} · ${rollout.participant_count} participant${rollout.participant_count === 1 ? '' : 's'}` },
    { label: 'Runtime effect', value: 'No change' },
  ]
  const currentWave = rollout.waves.find((wave) => wave.position === rollout.current_wave_position)
  return [
    { label: 'Decision', value: titleize(action) },
    ...(currentWave ? [{ label: 'Current wave', value: `${currentWave.position}. ${currentWave.name} · ${currentWave.participant_count} participant${currentWave.participant_count === 1 ? '' : 's'}` }] : []),
    { label: 'Target release', value: `Release #${rollout.target_release.release_number}` },
    { label: 'Target brand', value: brandEvidenceLabel(rollout.target_release) },
    { label: 'Runtime effect', value: 'No change' },
  ]
}

function brandEvidenceLabel(release: CohortRolloutRelease | null | undefined) {
  if (!release) return 'Unavailable'
  if (release.brand_version_id !== null) return `Brand version ${release.brand_version_id}`
  if (release.brand_mode === 'legacy_household_cfo_builtin') return 'Household CFO legacy brand'
  return 'Built-in brand'
}

function successMessage(action: Action, result: CohortRolloutMutationResponse, previousRollout: CohortRolloutRecord | null) {
  const transition = result.transition
  const rollout = result.rollout
  const runtimeEnabled = rollout.runtime_mode === 'release_runtime_v2'
  if (transition.event_type === 'planned') return `Rollout plan recorded for Release #${rollout.target_release.release_number}. Participant runtime did not change.`
  if (transition.event_type === 'activated' || transition.event_type === 'advanced') {
    const wave = rollout.waves.find((candidate) => candidate.position === transition.to_wave_position)
    if (runtimeEnabled && transition.participant_runtime_changed && wave) return `${wave.name} is now using Release #${rollout.target_release.release_number}. ${wave.exposed_count} participant${wave.exposed_count === 1 ? '' : 's'} changed immediately.`
    return `Legacy rollout progress recorded${wave ? ` for ${wave.name}` : ''}. Participant runtime did not change.`
  }
  if (transition.event_type === 'completed') {
    return runtimeEnabled && transition.participant_runtime_changed
      ? `Rollout completed. Release #${rollout.target_release.release_number} is now the cohort default.`
      : 'Legacy rollout completed. Participant runtime did not change.'
  }
  if (transition.event_type === 'rolled_back') {
    return runtimeEnabled && transition.participant_runtime_changed
      ? `Rollback completed. Still-current exposed enrollments now use ${releaseLabel(rollout.baseline_release)}.`
      : 'Legacy rollback record completed. Participant runtime did not change.'
  }
  const actionName = action === 'pause' ? 'Rollout paused' : action === 'resume' ? 'Rollout resumed' : action === 'cancel' ? 'Rollout cancelled' : titleize(transition.event_type)
  const target = previousRollout?.target_release.release_number ?? rollout.target_release.release_number
  return `${actionName} for Release #${target}. Participant runtime did not change.`
}
function waveStateLabel(wave: CohortRolloutWave, runtimeMode: string) {
  if (runtimeMode !== 'release_runtime_v2' && runtimeMode !== 'legacy_record_only_v1') return 'Unavailable'
  if (runtimeMode === 'release_runtime_v2' && (wave.active || wave.completed) && !wave.exposure_complete) return 'Exposure incomplete'
  if (wave.completed) return runtimeMode === 'release_runtime_v2' ? 'Exposed' : 'Complete'
  if (wave.active) return runtimeMode === 'release_runtime_v2' ? 'Live now' : 'Current'
  return 'Waiting'
}
function participantExposureLabel(participant: CohortRolloutParticipant, targetReleaseNumber: number, runtimeMode: string) {
  if (runtimeMode !== 'release_runtime_v2' && runtimeMode !== 'legacy_record_only_v1') return `Runtime unavailable · ${effectiveReleaseLabel(participant.effective_release)}`
  if (runtimeMode === 'legacy_record_only_v1') return `Legacy record · ${effectiveReleaseLabel(participant.effective_release)}`
  if (participant.exposed === true) return `Exposed · Release #${targetReleaseNumber}`
  if (participant.exposed === false) return `Not exposed · ${effectiveReleaseLabel(participant.effective_release)}`
  return `Exposure unavailable · ${effectiveReleaseLabel(participant.effective_release)}`
}
function rolloutProgressLabel(rollout: CohortRolloutRecord) {
  if (rollout.status === 'planned') return `0 of ${rollout.wave_count} waves started`
  if (rollout.status === 'active') return `Wave ${rollout.current_wave_position} of ${rollout.wave_count} active`
  if (rollout.status === 'paused') return `Wave ${rollout.current_wave_position} of ${rollout.wave_count} paused`
  if (rollout.status === 'completed') return `${rollout.wave_count} of ${rollout.wave_count} waves completed`
  return `Wave ${rollout.current_wave_position} of ${rollout.wave_count} · ${titleize(rollout.status)}`
}
function effectiveReleaseLabel(release: CohortRolloutRelease | null) { return release ? `Using Release #${release.release_number}` : 'No active release' }
function releaseLabel(release: CohortRolloutRelease | null) { return release ? `Release #${release.release_number}` : 'No active release' }
function historyLabel(total: number, shown: number, truncated: boolean, noun: string) { return truncated ? `${shown} of ${total} ${noun}s` : `${total} ${noun}${total === 1 ? '' : 's'}` }
function readinessLabel(value: string) { return titleize(value) }
function titleize(value: string) { return value.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase()) }
function errorMessage(caught: unknown, fallback: string) { return caught instanceof Error && caught.message ? caught.message : fallback }
function formatDate(value: string) { const date = new Date(value); return !value || Number.isNaN(date.getTime()) ? 'Time unavailable' : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date) }
