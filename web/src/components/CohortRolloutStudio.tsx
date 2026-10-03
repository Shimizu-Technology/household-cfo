import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent, type MouseEvent } from 'react'
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
import type { CohortRolloutPlanInput, CohortRolloutRecord, CohortRolloutStudio as CohortRolloutStudioData } from '../api'
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
  const [validationErrors, setValidationErrors] = useState<string[]>([])
  const loadRequestRef = useRef(0)
  const loadAbortRef = useRef<AbortController | null>(null)
  const restoreFocusRef = useRef<HTMLElement | null>(null)
  const studioRootRef = useRef<HTMLElement | null>(null)

  const loadStudio = useCallback(async (selectedCohortId: number) => {
    const requestId = ++loadRequestRef.current
    loadAbortRef.current?.abort()
    const abortController = new AbortController()
    loadAbortRef.current = abortController
    setPendingAction('load')
    setError(null)
    try {
      const next = await fetchCohortRolloutStudio(selectedCohortId, abortController.signal)
      if (requestId !== loadRequestRef.current || abortController.signal.aborted) return
      if (next.cohort.id !== selectedCohortId) throw new Error('Rollout records returned the wrong cohort. Reload and try again.')
      setStudio(next)
      setDraft(next.open_rollout ? null : defaultCohortRolloutPlan(next))
      setValidationErrors([])
    } catch (caught) {
      if (requestId !== loadRequestRef.current || abortController.signal.aborted) return
      setStudio(null)
      setDraft(null)
      setError(errorMessage(caught, 'Cohort rollout records could not be loaded.'))
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
    window.requestAnimationFrame(() => studioRootRef.current?.querySelector<HTMLElement>('[data-rollout-focus-target]')?.focus())
  }, [])

  async function confirmAction() {
    if (!confirmation || !studio || !cohortId || pendingAction || mutationLifecycle.pending) return
    const action = confirmation.action
    const mutation = mutationLifecycle.begin()
    setPendingAction(action)
    setActionError(null)
    try {
      if (action === 'plan') {
        if (!planValidation?.input) {
          setValidationErrors(planValidation?.errors ?? ['The rollout plan is incomplete.'])
          setConfirmation(null)
          return
        }
        await planCohortRollout(cohortId, planValidation.input, confirmation.requestId)
      } else {
        if (!rollout || rollout.latest_transition_id === null) throw new Error('The latest rollout evidence is unavailable. Reload and try again.')
        const compare = transitionInput(rollout)
        if (action === 'advance') await advanceCohortRollout(cohortId, rollout.id, { ...compare, readiness_digest: rollout.next_wave_readiness_digest }, confirmation.requestId)
        if (action === 'pause') await pauseCohortRollout(cohortId, rollout.id, compare, confirmation.requestId)
        if (action === 'resume') await resumeCohortRollout(cohortId, rollout.id, compare, confirmation.requestId)
        if (action === 'cancel') await cancelCohortRollout(cohortId, rollout.id, compare, confirmation.requestId)
        if (action === 'rollback') {
          if (!rollout.rollback_candidate) throw new Error('No verified rollback release is available. Reload and review the blockers.')
          await rollbackCohortRollout(cohortId, rollout.id, { ...compare, rollback_release_id: rollout.rollback_candidate.id }, confirmation.requestId)
        }
      }
      if (!mutationLifecycle.isCurrent(mutation)) return
      setConfirmation(null)
      setNotice(successMessage(action))
      await loadStudio(cohortId)
      focusCurrentState()
    } catch (caught) {
      if (!mutationLifecycle.isCurrent(mutation)) return
      if (caught instanceof ApiRequestError && (caught.status === 409 || caught.status === 403)) {
        setConfirmation(null)
        await loadStudio(cohortId)
        setError(caught.status === 409
          ? 'Rollout evidence changed before this action completed. Review the refreshed state before trying again.'
          : 'Your rollout permission changed. Review the refreshed state before trying again.')
        window.requestAnimationFrame(() => restoreFocusRef.current?.focus())
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
  if (error && !studio) return <div className="coach-studio-alert is-error" role="alert"><span>{error}</span><button type="button" onClick={() => void loadStudio(cohortId)}>Retry</button></div>
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
              <div><strong>{participant.full_name}</strong><small>{readinessLabel(participant.readiness)}</small></div>
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
  const advanceLabel = rollout.status === 'planned' ? 'Review and start rollout' : nextPosition ? `Review wave ${nextPosition}` : 'Review and complete rollout'
  return <div className="cohort-rollout-active-layout">
    <article className="panel cohort-rollout-current">
      <header><div><p className="eyebrow">Current rollout</p><h3 tabIndex={-1} data-rollout-focus-target>Release #{rollout.target_release.release_number}</h3></div><span className={`cohort-rollout-status is-${rollout.status}`}>{status}</span></header>
      <div className="cohort-rollout-progress" aria-label={`Wave ${rollout.current_wave_position} of ${rollout.wave_count} completed`}>
        {rollout.waves.map((wave) => <span key={wave.id} className={wave.completed ? 'is-complete' : wave.active ? 'is-active' : ''}><i />Wave {wave.position}</span>)}
      </div>
      <div className="cohort-rollout-wave-list">
        {rollout.waves.map((wave) => <section key={wave.id} className={wave.active ? 'is-active' : wave.completed ? 'is-complete' : ''}>
          <header><div><strong>{wave.position}. {wave.name}</strong><small>{wave.participant_count} participant{wave.participant_count === 1 ? '' : 's'}</small></div><b>{wave.completed ? 'Complete' : wave.active ? 'Current' : 'Waiting'}</b></header>
          <ul>{wave.participants.map((participant) => <li key={participant.user_id}><span>{participant.full_name}</span><small>{readinessLabel(participant.readiness)}</small></li>)}</ul>
        </section>)}
      </div>
      {rollout.permissions.advance_blockers.length > 0 && <div className="cohort-release-blockers" role="note"><strong>Before the next wave</strong><ul>{rollout.permissions.advance_blockers.map((item) => <li key={item}>{item}</li>)}</ul></div>}
      <div className="cohort-rollout-lifecycle-actions">
        {rollout.permissions.advance && <Button onClick={(event) => onAction(event, 'advance')} disabled={pending}>{advanceLabel}</Button>}
        {rollout.permissions.pause && <Button variant="secondary" onClick={(event) => onAction(event, 'pause')} disabled={pending}>Review pause</Button>}
        {rollout.permissions.resume && <Button onClick={(event) => onAction(event, 'resume')} disabled={pending}>Review resume</Button>}
        {rollout.permissions.cancel && <Button variant="danger" onClick={(event) => onAction(event, 'cancel')} disabled={pending}>Review cancellation</Button>}
        {rollout.permissions.rollback && <Button variant="danger" onClick={(event) => onAction(event, 'rollback')} disabled={pending}>Review rollback</Button>}
      </div>
      {rollout.permissions.rollback_blockers.length > 0 && rollout.status !== 'planned' && <small className="cohort-rollout-action-note">Rollback unavailable: {rollout.permissions.rollback_blockers.join(' ')}</small>}
      <p className="cohort-rollout-runtime-note">{studio.runtime_truth.message}</p>
    </article>
    <article className="panel cohort-rollout-transition-history">
      <header><div><p className="eyebrow">Decision history</p><h3>{historyLabel(rollout.transition_history.total_count, rollout.transitions.length, rollout.transition_history.truncated, 'event')}</h3></div></header>
      <ol>{rollout.transitions.map((transition) => <li key={transition.id}><strong>{titleize(transition.event_type)}</strong><small>{formatDate(transition.occurred_at)} · {transition.actor?.full_name ?? 'System record'}</small><span>{titleize(transition.to_status)}{transition.to_wave_position > 0 ? ` · Wave ${transition.to_wave_position}` : ''}</span></li>)}</ol>
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
    {studio.rollouts.length === 0 ? <div className="cohort-release-empty"><strong>No rollout records yet.</strong><p>A reviewed plan will appear here.</p></div> : <ol>{studio.rollouts.map((rollout) => <li key={rollout.id}><div><strong>Release #{rollout.target_release.release_number}</strong><small>{formatDate(rollout.planned_at)} · {rollout.planned_by?.full_name ?? 'System record'}</small></div><span className={`cohort-rollout-status is-${rollout.status}`}>{titleize(rollout.status)}</span><p>{rollout.wave_count} wave{rollout.wave_count === 1 ? '' : 's'} · {rollout.participant_count} participant{rollout.participant_count === 1 ? '' : 's'}</p></li>)}</ol>}
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
    cancelRef.current?.focus()
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
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus() }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus() }
  }
  const copy = confirmationCopy(confirmation.action, rollout, studio)
  const details = confirmationDetails(confirmation.action, rollout, studio, plan)
  return <div className="cohort-release-modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget && !pending) onCancel() }}>
    <section ref={dialogRef} className="cohort-release-modal" role="dialog" aria-modal="true" aria-labelledby="cohort-rollout-modal-title" aria-describedby="cohort-rollout-modal-copy" onKeyDown={trapFocus}>
      <p className="eyebrow">Final review</p><h3 id="cohort-rollout-modal-title">{copy.title}</h3><p id="cohort-rollout-modal-copy">{copy.body}</p>
      <dl className="cohort-rollout-confirmation-summary">
        <div><dt>Cohort</dt><dd>{studio.cohort.name}</dd></div>
        {details.map((detail) => <div key={`${detail.label}-${detail.value}`}><dt>{detail.label}</dt><dd>{detail.value}</dd></div>)}
        <div><dt>Participant runtime</dt><dd>Unchanged in this phase</dd></div>
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
  if (action === 'plan') return { title: 'Record this rollout plan?', body: `This locks the wave assignments for release #${studio.latest_release?.release_number}. You can cancel the plan before it starts.`, confirm: 'Record rollout plan', danger: false }
  if (action === 'advance') return { title: rollout?.status === 'planned' ? 'Start this rollout?' : rollout?.next_wave_position ? `Advance to wave ${rollout.next_wave_position}?` : 'Complete this rollout?', body: 'The current roster and readiness evidence will be checked again before this decision is recorded.', confirm: rollout?.status === 'planned' ? 'Start rollout' : rollout?.next_wave_position ? `Advance to wave ${rollout.next_wave_position}` : 'Complete rollout', danger: false }
  if (action === 'pause') return { title: 'Pause this rollout?', body: 'The rollout stays paused until an authorized owner or reviewer resumes or rolls it back.', confirm: 'Pause rollout', danger: false }
  if (action === 'resume') return { title: 'Resume this rollout?', body: 'This returns the rollout to its current wave. Readiness is checked again before advancing.', confirm: 'Resume rollout', danger: false }
  if (action === 'cancel') return { title: 'Cancel this rollout plan?', body: 'Cancellation is final for this unstarted plan. Its audit history remains available.', confirm: 'Cancel rollout plan', danger: true }
  return { title: `Roll back to release #${rollout?.rollback_candidate?.release_number}?`, body: 'This records a rollback decision and closes this rollout. Its full wave and decision history remains available.', confirm: 'Record rollback', danger: true }
}

function confirmationDetails(action: Action, rollout: CohortRolloutRecord | null, studio: CohortRolloutStudioData, plan: CohortRolloutPlanInput | null) {
  if (action === 'plan' && plan) {
    return [
      { label: 'Target release', value: `Release #${studio.latest_release?.release_number ?? 'unavailable'}` },
      { label: 'Wave count', value: `${plan.waves.length}` },
      ...plan.waves.map((wave, index) => ({
        label: `Wave ${index + 1}`,
        value: `${wave.name} · ${wave.user_ids.length} participant${wave.user_ids.length === 1 ? '' : 's'}`,
      })),
    ]
  }
  if (!rollout) return []
  if (action === 'advance') {
    const wave = rollout.waves.find((candidate) => candidate.position === rollout.next_wave_position)
    return wave ? [
      { label: rollout.status === 'planned' ? 'Starting wave' : 'Advancing to', value: `${wave.position}. ${wave.name}` },
      { label: 'Participants', value: `${wave.participant_count}` },
      { label: 'Target release', value: `Release #${rollout.target_release.release_number}` },
    ] : [
      { label: 'Decision', value: 'Complete rollout' },
      { label: 'Completed waves', value: `${rollout.wave_count}` },
      { label: 'Target release', value: `Release #${rollout.target_release.release_number}` },
    ]
  }
  if (action === 'rollback') return [
    { label: 'Rollback to', value: `Release #${rollout.rollback_candidate?.release_number ?? 'unavailable'}` },
    { label: 'Current target', value: `Release #${rollout.target_release.release_number}` },
  ]
  if (action === 'cancel') return [
    { label: 'Target release', value: `Release #${rollout.target_release.release_number}` },
    { label: 'Plan size', value: `${rollout.wave_count} wave${rollout.wave_count === 1 ? '' : 's'} · ${rollout.participant_count} participant${rollout.participant_count === 1 ? '' : 's'}` },
  ]
  const currentWave = rollout.waves.find((wave) => wave.position === rollout.current_wave_position)
  return [
    { label: 'Decision', value: titleize(action) },
    ...(currentWave ? [{ label: 'Current wave', value: `${currentWave.position}. ${currentWave.name} · ${currentWave.participant_count} participant${currentWave.participant_count === 1 ? '' : 's'}` }] : []),
    { label: 'Target release', value: `Release #${rollout.target_release.release_number}` },
  ]
}

function successMessage(action: Action) {
  const actionName = action === 'plan' ? 'Rollout plan recorded' : action === 'advance' ? 'Rollout progress recorded' : action === 'pause' ? 'Rollout paused' : action === 'resume' ? 'Rollout resumed' : action === 'cancel' ? 'Rollout cancelled' : 'Rollback recorded'
  return `${actionName}. Participant runtime did not change.`
}
function historyLabel(total: number, shown: number, truncated: boolean, noun: string) { return truncated ? `${shown} of ${total} ${noun}s` : `${total} ${noun}${total === 1 ? '' : 's'}` }
function readinessLabel(value: string) { return titleize(value) }
function titleize(value: string) { return value.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase()) }
function errorMessage(caught: unknown, fallback: string) { return caught instanceof Error && caught.message ? caught.message : fallback }
function formatDate(value: string) { const date = new Date(value); return !value || Number.isNaN(date.getTime()) ? 'Time unavailable' : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date) }
