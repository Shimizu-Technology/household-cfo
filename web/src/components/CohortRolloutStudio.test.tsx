// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, type CohortRolloutMutationResponse, type CohortRolloutStudio as CohortRolloutStudioData } from '../api'
import { CohortRolloutStudio } from './CohortRolloutStudio'

const apiMocks = vi.hoisted(() => ({
  advanceCohortRollout: vi.fn(), cancelCohortRollout: vi.fn(), createCohortRolloutRequestId: vi.fn(() => 'rollout-request-1'),
  fetchCohortRolloutStudio: vi.fn(), pauseCohortRollout: vi.fn(), planCohortRollout: vi.fn(), resumeCohortRollout: vi.fn(), rollbackCohortRollout: vi.fn(),
}))

vi.mock('../api', async (importOriginal) => ({ ...await importOriginal<typeof import('../api')>(), ...apiMocks }))

function studioFixture(): CohortRolloutStudioData {
  const activeRelease = { id: 43, release_number: 3, bundle_digest: 'baseline', integrity_valid: true, runtime_compatible: true, released_at: '2026-10-02T01:00:00Z' }
  return {
    cohort: { id: 12, name: 'Tuesday cohort', status: 'active', participant_count: 2 },
    runtime_truth: { changes_participant_runtime: true, participant_runtime_changed: false, message: 'Advanced waves receive the target release immediately.' },
    permissions: { view: true, manage: true, plan: true, actor_role: 'owner', blockers: [], plan_blockers: [] },
    current_roster: {
      digest: 'roster-digest', readiness_digest: 'roster-ready', total_count: 2,
      counts: { ready: 2, awaiting_acceptance: 0, revoked: 0, removed: 0 },
      participants: [{ user_id: 7, full_name: 'Ana Cruz', readiness: 'ready', exposed: null, effective_release: activeRelease }, { user_id: 8, full_name: 'Ben Santos', readiness: 'ready', exposed: null, effective_release: activeRelease }],
    },
    latest_release: { id: 44, release_number: 4, bundle_digest: 'bundle', integrity_valid: true, runtime_compatible: true, released_at: '2026-10-03T01:00:00Z' },
    active_release: activeRelease,
    release_history: { limit: 25, total_count: 4, truncated: false }, releases: [],
    history: { limit: 25, total_count: 0, truncated: false }, open_rollout: null, rollouts: [],
  }
}

function activeRolloutStudio(status: 'planned' | 'active' | 'paused' = 'active'): CohortRolloutStudioData {
  const studio = studioFixture()
  studio.permissions.plan = false
  studio.permissions.plan_blockers = ['Another rollout is already open for this cohort.']
  studio.open_rollout = {
    id: 90, status, runtime_mode: 'release_runtime_v2', runtime_blocker: null, target_release: studio.latest_release!, baseline_release: studio.active_release, rollback_release: null,
    rollback_candidate: { id: 43, release_number: 3, bundle_digest: 'prior', integrity_valid: true, runtime_compatible: true, released_at: '2026-10-02T01:00:00Z' },
    planned_by: { id: 5, full_name: 'Coach Mel', role: 'owner' }, planned_at: '2026-10-03T02:00:00Z', activated_at: status === 'planned' ? null : '2026-10-03T03:00:00Z', paused_at: status === 'paused' ? '2026-10-03T04:00:00Z' : null, completed_at: null, cancelled_at: null, rolled_back_at: null,
    current_wave_position: status === 'planned' ? 0 : 1, wave_count: 2, participant_count: 2, latest_transition_id: 101,
    readiness_digest: 'all-ready', next_wave_readiness_digest: 'wave-ready', next_wave_position: status === 'planned' ? 1 : 2,
    permissions: { advance: status !== 'paused', pause: status === 'active', resume: status === 'paused', cancel: status === 'planned', rollback: status !== 'planned', advance_blockers: [], rollback_blockers: status === 'planned' ? ['Only active or paused rollouts can roll back.'] : [] },
    waves: [
      { id: 91, position: 1, name: 'Pilot', active: status !== 'planned', completed: false, participant_count: 1, exposed_count: status === 'planned' ? 0 : 1, exposure_complete: status !== 'planned', counts: { ready: 1, awaiting_acceptance: 0, revoked: 0, removed: 0 }, participants: [{ user_id: 7, full_name: 'Ana Cruz', readiness: 'ready', exposed: status !== 'planned', effective_release: status === 'planned' ? studio.active_release : studio.latest_release }] },
      { id: 92, position: 2, name: 'Everyone else', active: false, completed: false, participant_count: 1, exposed_count: 0, exposure_complete: false, counts: { ready: 1, awaiting_acceptance: 0, revoked: 0, removed: 0 }, participants: [{ user_id: 8, full_name: 'Ben Santos', readiness: 'ready', exposed: false, effective_release: studio.active_release }] },
    ],
    transition_history: { limit: 25, total_count: 1, truncated: false },
    transitions: [{ id: 101, event_type: status === 'planned' ? 'planned' : status === 'paused' ? 'paused' : 'activated', from_status: status === 'planned' ? null : status === 'paused' ? 'active' : 'planned', to_status: status, from_wave_position: 0, to_wave_position: status === 'planned' ? 0 : 1, rollback_release_id: null, readiness_digest: status === 'planned' ? null : 'wave-ready', actor: { id: 5, full_name: 'Coach Mel', role: 'owner' }, occurred_at: '2026-10-03T02:00:00Z', participant_runtime_changed: status === 'active' }],
    participant_runtime_changed: status !== 'planned',
  }
  studio.history = { limit: 25, total_count: 1, truncated: false }
  studio.rollouts = [{
    id: 90, status, runtime_mode: 'release_runtime_v2', runtime_blocker: null, target_release: studio.latest_release!, baseline_release: studio.active_release, rollback_release: null, planned_by: { id: 5, full_name: 'Coach Mel', role: 'owner' }, planned_at: '2026-10-03T02:00:00Z', activated_at: null, paused_at: null, completed_at: null, cancelled_at: null, rolled_back_at: null, current_wave_position: 0, wave_count: 2, participant_count: 2, latest_transition_id: 101, transition_history: { limit: 25, total_count: 1, truncated: false }, participant_runtime_changed: status !== 'planned',
  }]
  return studio
}

function legacyRolloutStudio(): CohortRolloutStudioData {
  const studio = activeRolloutStudio('active')
  const rollout = studio.open_rollout!
  rollout.runtime_mode = 'legacy_record_only_v1'
  rollout.runtime_blocker = 'Finish or roll back this pre-cutover rollout before activating participant runtime.'
  rollout.baseline_release = null
  rollout.participant_runtime_changed = false
  rollout.waves.forEach((wave) => {
    wave.exposed_count = 0
    wave.exposure_complete = false
    wave.participants.forEach((participant) => { participant.exposed = null })
  })
  studio.rollouts[0] = { ...studio.rollouts[0], runtime_mode: 'legacy_record_only_v1', runtime_blocker: rollout.runtime_blocker, baseline_release: null, participant_runtime_changed: false }
  return studio
}

function mutationResponse(eventType: string, participantRuntimeChanged: boolean): CohortRolloutMutationResponse {
  const studio = activeRolloutStudio(eventType === 'planned' ? 'planned' : 'active')
  const rollout = studio.open_rollout!
  const transition = {
    id: 202,
    event_type: eventType,
    from_status: eventType === 'planned' ? null : 'planned',
    to_status: eventType === 'cancelled' ? 'cancelled' : eventType === 'rolled_back' ? 'rolled_back' : eventType === 'paused' ? 'paused' : 'active',
    from_wave_position: 0,
    to_wave_position: eventType === 'planned' || eventType === 'cancelled' ? 0 : 1,
    rollback_release_id: eventType === 'rolled_back' ? rollout.baseline_release?.id ?? null : null,
    readiness_digest: eventType === 'activated' || eventType === 'advanced' ? 'wave-ready' : null,
    actor: { id: 5, full_name: 'Coach Mel', role: 'owner' },
    occurred_at: '2026-10-03T03:00:00Z',
    participant_runtime_changed: participantRuntimeChanged,
  }
  return { rollout, transition, replayed: false, cohort_rollout_studio: studio }
}

function renderStudio(studio = studioFixture(), reloadStudio = studio) {
  const mutationLifecycle = { pending: false, begin: vi.fn(() => ({ id: 1, workspaceId: 2 })), isCurrent: vi.fn(() => true), finish: vi.fn() }
  const onDirtyChange = vi.fn()
  apiMocks.fetchCohortRolloutStudio.mockResolvedValueOnce(studio).mockResolvedValue(reloadStudio)
  render(<CohortRolloutStudio cohortId={12} mutationLifecycle={mutationLifecycle} onDirtyChange={onDirtyChange} />)
  return { mutationLifecycle, onDirtyChange }
}

beforeEach(() => {
  vi.clearAllMocks()
  apiMocks.createCohortRolloutRequestId.mockReturnValue('rollout-request-1')
  apiMocks.planCohortRollout.mockResolvedValue(mutationResponse('planned', false))
  apiMocks.advanceCohortRollout.mockResolvedValue(mutationResponse('advanced', true))
  apiMocks.pauseCohortRollout.mockResolvedValue(mutationResponse('paused', false))
  apiMocks.resumeCohortRollout.mockResolvedValue(mutationResponse('resumed', false))
  apiMocks.cancelCohortRollout.mockResolvedValue(mutationResponse('cancelled', false))
  apiMocks.rollbackCohortRollout.mockResolvedValue(mutationResponse('rolled_back', true))
})
afterEach(cleanup)

describe('CohortRolloutStudio', () => {
  it('starts with one all-participant wave and builds selectable waves without drag and drop', async () => {
    const user = userEvent.setup()
    const { onDirtyChange } = renderStudio()
    expect(await screen.findByDisplayValue('All participants')).toBeTruthy()
    expect(screen.getAllByRole('combobox').map((select) => (select as HTMLSelectElement).value)).toEqual(['wave-1', 'wave-1'])
    await user.click(screen.getByRole('button', { name: 'Add wave' }))
    const names = screen.getAllByRole('textbox')
    await user.clear(names[1]); await user.type(names[1], 'Later group')
    await user.selectOptions(screen.getByRole('combobox', { name: 'Wave for Ben Santos' }), 'wave-2')
    await waitFor(() => expect(onDirtyChange).toHaveBeenLastCalledWith(true))
    await user.click(screen.getByRole('button', { name: 'Review rollout plan' }))
    const dialog = screen.getByRole('dialog', { name: 'Record this rollout plan?' })
    expect(within(dialog).getByText('Release #4')).toBeTruthy()
    expect(within(dialog).getByText('Wave 1 · 1 participant')).toBeTruthy()
    expect(within(dialog).getByText('Later group · 1 participant')).toBeTruthy()
    await user.click(within(dialog).getByRole('button', { name: 'Record rollout plan' }))
    await waitFor(() => expect(apiMocks.planCohortRollout).toHaveBeenCalledWith(12, {
      target_release_id: 44, expected_latest_release_id: 44, expected_roster_digest: 'roster-digest',
      waves: [{ name: 'Wave 1', user_ids: [7] }, { name: 'Later group', user_ids: [8] }],
    }, 'rollout-request-1'))
  })

  it('focuses and traps the confirmation, then reuses its stable key after an uncertain failure', async () => {
    const user = userEvent.setup()
    apiMocks.planCohortRollout.mockRejectedValueOnce(new Error('Connection interrupted.')).mockResolvedValueOnce(mutationResponse('planned', false))
    renderStudio()
    const review = await screen.findByRole('button', { name: 'Review rollout plan' })
    await user.click(review)
    const dialog = screen.getByRole('dialog', { name: 'Record this rollout plan?' })
    const cancel = within(dialog).getByRole('button', { name: 'Cancel' })
    const confirm = within(dialog).getByRole('button', { name: 'Record rollout plan' })
    expect(document.activeElement).toBe(cancel)
    await user.tab({ shift: true }); expect(document.activeElement).toBe(confirm)
    await user.click(confirm)
    expect((await screen.findByRole('alert')).textContent).toContain('Connection interrupted.')
    await user.click(confirm)
    await waitFor(() => expect(apiMocks.planCohortRollout).toHaveBeenCalledTimes(2))
    expect(apiMocks.planCohortRollout.mock.calls.map((call) => call[2])).toEqual(['rollout-request-1', 'rollout-request-1'])
  })

  it('submits exact compare-and-swap evidence for advance and rollback', async () => {
    const user = userEvent.setup()
    renderStudio(activeRolloutStudio('active'))
    await user.click(await screen.findByRole('button', { name: 'Review wave 2' }))
    const advanceDialog = screen.getByRole('dialog', { name: 'Advance to wave 2?' })
    expect(within(advanceDialog).getByText('2. Everyone else')).toBeTruthy()
    expect(within(advanceDialog).getByText('1', { selector: 'dd' })).toBeTruthy()
    await user.click(within(advanceDialog).getByRole('button', { name: 'Advance to wave 2' }))
    await waitFor(() => expect(apiMocks.advanceCohortRollout).toHaveBeenCalledWith(12, 90, {
      expected_status: 'active', expected_current_wave_position: 1, expected_latest_transition_id: 101, readiness_digest: 'wave-ready',
    }, 'rollout-request-1'))

    apiMocks.fetchCohortRolloutStudio.mockResolvedValue(activeRolloutStudio('active'))
    await screen.findByRole('button', { name: 'Review rollback' })
    await user.click(screen.getByRole('button', { name: 'Review rollback' }))
    await user.click(screen.getByRole('button', { name: 'Roll back participant runtime' }))
    await waitFor(() => expect(apiMocks.rollbackCohortRollout).toHaveBeenCalledWith(12, 90, {
      expected_status: 'active', expected_current_wave_position: 1, expected_latest_transition_id: 101, rollback_release_id: 43,
    }, 'rollout-request-1'))
  })

  it('states the immediate runtime decision before start and reports the returned exposure result', async () => {
    const user = userEvent.setup()
    renderStudio(activeRolloutStudio('planned'), activeRolloutStudio('active'))
    await user.click(await screen.findByRole('button', { name: 'Review and start rollout' }))
    const dialog = screen.getByRole('dialog', { name: 'Start this rollout?' })
    expect(within(dialog).getByText('This immediately moves 1 participant in Pilot to release #4.')).toBeTruthy()
    expect(within(dialog).getByText('This wave changes immediately')).toBeTruthy()
    await user.click(within(dialog).getByRole('button', { name: 'Start rollout' }))
    expect(await screen.findByText('Pilot is now using Release #4. 1 participant changed immediately.')).toBeTruthy()
    expect(screen.getByText(/Ready · Exposed · Release #4/)).toBeTruthy()
    expect(screen.getByText(/Ready · Not exposed · Using Release #3/)).toBeTruthy()
  })

  it('explains and completes the cohort-default promotion from returned transition evidence', async () => {
    const user = userEvent.setup()
    const initial = activeRolloutStudio('active')
    initial.open_rollout!.next_wave_position = null
    const completed = mutationResponse('completed', true)
    completed.transition.to_status = 'completed'
    completed.transition.to_wave_position = 2
    completed.rollout.status = 'completed'
    apiMocks.advanceCohortRollout.mockResolvedValue(completed)
    renderStudio(initial, studioFixture())

    await user.click(await screen.findByRole('button', { name: 'Review and complete rollout' }))
    const dialog = screen.getByRole('dialog', { name: 'Complete this rollout?' })
    expect(within(dialog).getByText('Completing makes release #4 the cohort default immediately.')).toBeTruthy()
    expect(within(dialog).getByText('Becomes the cohort default immediately')).toBeTruthy()
    await user.click(within(dialog).getByRole('button', { name: 'Complete rollout' }))
    expect(await screen.findByText('Rollout completed. Release #4 is now the cohort default.')).toBeTruthy()
  })

  it('marks a pre-cutover rollout as record only and never presents exposure as live', async () => {
    const user = userEvent.setup()
    renderStudio(legacyRolloutStudio())
    expect(await screen.findByText('Pre-cutover rollout · record only')).toBeTruthy()
    expect(screen.getByText('Finish or roll back this pre-cutover rollout before activating participant runtime.')).toBeTruthy()
    expect(screen.getAllByText(/Legacy record · Using Release/)).toHaveLength(2)
    expect(screen.queryByText(/Exposed · Release/)).toBeNull()

    await user.click(screen.getByRole('button', { name: 'Review wave 2' }))
    const dialog = screen.getByRole('dialog', { name: 'Advance to wave 2?' })
    expect(within(dialog).getByText('This pre-cutover action only advances the legacy record. It does not change participant runtime.')).toBeTruthy()
    expect(within(dialog).getByText('Legacy record only · no runtime change')).toBeTruthy()
  })

  it('fails an unknown future runtime mode closed without live-runtime claims or controls', async () => {
    const studio = activeRolloutStudio('active')
    const rollout = studio.open_rollout!
    ;(rollout as unknown as { runtime_mode: string }).runtime_mode = 'future_mode'
    rollout.runtime_blocker = null
    rollout.waves.forEach((wave) => wave.participants.forEach((participant) => { participant.exposed = true }))
    renderStudio(studio)

    expect(await screen.findByText('Update required before rollout changes')).toBeTruthy()
    expect(screen.getByText(/does not recognize runtime mode “future_mode”/)).toBeTruthy()
    expect(screen.queryByText('Live now')).toBeNull()
    expect(screen.queryByText(/Exposed · Release/)).toBeNull()
    expect(screen.queryByText('Runtime changed')).toBeNull()
    expect(screen.getByText(/Active · Wave 1 · Runtime mode unavailable/)).toBeTruthy()
    expect(screen.getAllByText(/Runtime unavailable · Using Release/)).toHaveLength(2)
    expect(screen.getByText('Lifecycle changes are blocked until this app understands the returned runtime mode.')).toBeTruthy()
    expect(screen.queryByRole('button', { name: /Review|rollout/i })).toBeNull()
  })

  it.each([
    { status: 'planned', label: '0 of 2 waves started' },
    { status: 'active', label: 'Wave 1 of 2 active' },
    { status: 'paused', label: 'Wave 1 of 2 paused' },
  ] as const)('announces truthful rollout progress while $status', async ({ status, label }) => {
    renderStudio(activeRolloutStudio(status))
    expect(await screen.findByLabelText(label)).toBeTruthy()
  })

  it('refreshes stale evidence on a conflict and explains that runtime stays unchanged', async () => {
    const user = userEvent.setup()
    apiMocks.pauseCohortRollout.mockRejectedValue(new ApiRequestError('stale', { status: 409, code: 'cohort_rollout_conflict', errors: [], conflicts: [] }))
    renderStudio(activeRolloutStudio('active'))
    await user.click(await screen.findByRole('button', { name: 'Review pause' }))
    await user.click(screen.getByRole('button', { name: 'Pause rollout' }))
    expect((await screen.findByRole('alert')).textContent).toContain('Rollout evidence changed')
    expect(screen.getByText('Advanced waves receive the target release immediately.')).toBeTruthy()
    expect(apiMocks.fetchCohortRolloutStudio).toHaveBeenCalledTimes(2)
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('heading', { name: 'Release #4' })))
  })

  it('preserves a failed conflict refresh error and focuses its retry control', async () => {
    const user = userEvent.setup()
    apiMocks.fetchCohortRolloutStudio.mockReset()
      .mockResolvedValueOnce(activeRolloutStudio('active'))
      .mockRejectedValueOnce(new Error('Refresh connection failed.'))
    apiMocks.pauseCohortRollout.mockRejectedValue(new ApiRequestError('stale', { status: 409, code: 'cohort_rollout_conflict', errors: [], conflicts: [] }))
    render(<CohortRolloutStudio cohortId={12} mutationLifecycle={{ pending: false, begin: vi.fn(() => ({ id: 1, workspaceId: 2 })), isCurrent: vi.fn(() => true), finish: vi.fn() }} onDirtyChange={vi.fn()} />)

    await user.click(await screen.findByRole('button', { name: 'Review pause' }))
    await user.click(screen.getByRole('button', { name: 'Pause rollout' }))

    expect((await screen.findByRole('alert')).textContent).toContain('Refresh connection failed.')
    const retry = screen.getByRole('button', { name: 'Retry' })
    await waitFor(() => expect(document.activeElement).toBe(retry))
    expect(screen.queryByText(/Rollout evidence changed before this action completed/)).toBeNull()
  })

  it('preserves an edited plan after an ordinary validation rejection', async () => {
    const user = userEvent.setup()
    apiMocks.planCohortRollout.mockRejectedValue(new ApiRequestError('Wave names were rejected.', { status: 422, code: 'cohort_rollout_invalid' }))
    renderStudio()
    await screen.findByDisplayValue('All participants')
    await user.click(screen.getByRole('button', { name: 'Add wave' }))
    const names = screen.getAllByRole('textbox')
    await user.clear(names[1]); await user.type(names[1], 'Later group')
    await user.selectOptions(screen.getByRole('combobox', { name: 'Wave for Ben Santos' }), 'wave-2')
    await user.click(screen.getByRole('button', { name: 'Review rollout plan' }))
    await user.click(screen.getByRole('button', { name: 'Record rollout plan' }))

    expect((await screen.findByRole('alert')).textContent).toContain('Wave names were rejected.')
    expect(screen.getAllByRole('textbox').map((field) => (field as HTMLInputElement).value)).toEqual(['Wave 1', 'Later group'])
    expect((screen.getByRole('combobox', { name: 'Wave for Ben Santos' }) as HTMLSelectElement).value).toBe('wave-2')
    expect(apiMocks.fetchCohortRolloutStudio).toHaveBeenCalledTimes(1)
  })

  it.each([
    { name: 'plan', initial: studioFixture(), next: activeRolloutStudio('planned'), trigger: 'Review rollout plan', confirm: 'Record rollout plan' },
    { name: 'cancel', initial: activeRolloutStudio('planned'), next: studioFixture(), trigger: 'Review cancellation', confirm: 'Cancel rollout plan' },
    { name: 'rollback', initial: activeRolloutStudio('active'), next: studioFixture(), trigger: 'Review rollback', confirm: 'Roll back participant runtime' },
  ])('moves focus to the stable new state heading after $name', async ({ initial, next, trigger, confirm }) => {
    const user = userEvent.setup()
    renderStudio(initial, next)
    await user.click(await screen.findByRole('button', { name: trigger }))
    await user.click(screen.getByRole('button', { name: confirm }))
    const heading = await screen.findByRole('heading', { name: 'Release #4' })
    await waitFor(() => expect(document.activeElement).toBe(heading))
  })
})
