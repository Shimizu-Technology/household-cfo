// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, type CohortRolloutStudio as CohortRolloutStudioData } from '../api'
import { CohortRolloutStudio } from './CohortRolloutStudio'

const apiMocks = vi.hoisted(() => ({
  advanceCohortRollout: vi.fn(), cancelCohortRollout: vi.fn(), createCohortRolloutRequestId: vi.fn(() => 'rollout-request-1'),
  fetchCohortRolloutStudio: vi.fn(), pauseCohortRollout: vi.fn(), planCohortRollout: vi.fn(), resumeCohortRollout: vi.fn(), rollbackCohortRollout: vi.fn(),
}))

vi.mock('../api', async (importOriginal) => ({ ...await importOriginal<typeof import('../api')>(), ...apiMocks }))

function studioFixture(): CohortRolloutStudioData {
  return {
    cohort: { id: 12, name: 'Tuesday cohort', status: 'active', participant_count: 2 },
    runtime_truth: { changes_participant_runtime: false, participant_runtime_changed: false, message: 'Records do not change participant runtime.' },
    permissions: { view: true, manage: true, plan: true, actor_role: 'owner', blockers: [], plan_blockers: [] },
    current_roster: {
      digest: 'roster-digest', readiness_digest: 'roster-ready', total_count: 2,
      counts: { ready: 2, awaiting_acceptance: 0, revoked: 0, removed: 0 },
      participants: [{ user_id: 7, full_name: 'Ana Cruz', readiness: 'ready' }, { user_id: 8, full_name: 'Ben Santos', readiness: 'ready' }],
    },
    latest_release: { id: 44, release_number: 4, bundle_digest: 'bundle', integrity_valid: true, runtime_compatible: true, released_at: '2026-10-03T01:00:00Z' },
    release_history: { limit: 25, total_count: 4, truncated: false }, releases: [],
    history: { limit: 25, total_count: 0, truncated: false }, open_rollout: null, rollouts: [],
  }
}

function activeRolloutStudio(status: 'planned' | 'active' | 'paused' = 'active'): CohortRolloutStudioData {
  const studio = studioFixture()
  studio.permissions.plan = false
  studio.permissions.plan_blockers = ['Another rollout is already open for this cohort.']
  studio.open_rollout = {
    id: 90, status, target_release: studio.latest_release!, rollback_release: null,
    rollback_candidate: { id: 43, release_number: 3, bundle_digest: 'prior', integrity_valid: true, runtime_compatible: true, released_at: '2026-10-02T01:00:00Z' },
    planned_by: { id: 5, full_name: 'Coach Mel', role: 'owner' }, planned_at: '2026-10-03T02:00:00Z', activated_at: status === 'planned' ? null : '2026-10-03T03:00:00Z', paused_at: status === 'paused' ? '2026-10-03T04:00:00Z' : null, completed_at: null, cancelled_at: null, rolled_back_at: null,
    current_wave_position: status === 'planned' ? 0 : 1, wave_count: 2, participant_count: 2, latest_transition_id: 101,
    readiness_digest: 'all-ready', next_wave_readiness_digest: 'wave-ready', next_wave_position: status === 'planned' ? 1 : 2,
    permissions: { advance: status !== 'paused', pause: status === 'active', resume: status === 'paused', cancel: status === 'planned', rollback: status !== 'planned', advance_blockers: [], rollback_blockers: status === 'planned' ? ['Only active or paused rollouts can roll back.'] : [] },
    waves: [
      { id: 91, position: 1, name: 'Pilot', active: status !== 'planned', completed: false, participant_count: 1, counts: { ready: 1, awaiting_acceptance: 0, revoked: 0, removed: 0 }, participants: [{ user_id: 7, full_name: 'Ana Cruz', readiness: 'ready' }] },
      { id: 92, position: 2, name: 'Everyone else', active: false, completed: false, participant_count: 1, counts: { ready: 1, awaiting_acceptance: 0, revoked: 0, removed: 0 }, participants: [{ user_id: 8, full_name: 'Ben Santos', readiness: 'ready' }] },
    ],
    transition_history: { limit: 25, total_count: 1, truncated: false },
    transitions: [{ id: 101, event_type: status === 'planned' ? 'planned' : 'activated', from_status: status === 'planned' ? null : 'planned', to_status: status, from_wave_position: 0, to_wave_position: status === 'planned' ? 0 : 1, rollback_release_id: null, readiness_digest: status === 'planned' ? null : 'wave-ready', actor: { id: 5, full_name: 'Coach Mel', role: 'owner' }, occurred_at: '2026-10-03T02:00:00Z', participant_runtime_changed: false }],
    participant_runtime_changed: false,
  }
  studio.history = { limit: 25, total_count: 1, truncated: false }
  studio.rollouts = [{
    id: 90, status, target_release: studio.latest_release!, rollback_release: null, planned_by: { id: 5, full_name: 'Coach Mel', role: 'owner' }, planned_at: '2026-10-03T02:00:00Z', activated_at: null, paused_at: null, completed_at: null, cancelled_at: null, rolled_back_at: null, current_wave_position: 0, wave_count: 2, participant_count: 2, latest_transition_id: 101, transition_history: { limit: 25, total_count: 1, truncated: false }, participant_runtime_changed: false,
  }]
  return studio
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
  for (const mock of [apiMocks.planCohortRollout, apiMocks.advanceCohortRollout, apiMocks.pauseCohortRollout, apiMocks.resumeCohortRollout, apiMocks.cancelCohortRollout, apiMocks.rollbackCohortRollout]) mock.mockResolvedValue({})
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
    apiMocks.planCohortRollout.mockRejectedValueOnce(new Error('Connection interrupted.')).mockResolvedValueOnce({})
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
    await user.click(screen.getByRole('button', { name: 'Record rollback' }))
    await waitFor(() => expect(apiMocks.rollbackCohortRollout).toHaveBeenCalledWith(12, 90, {
      expected_status: 'active', expected_current_wave_position: 1, expected_latest_transition_id: 101, rollback_release_id: 43,
    }, 'rollout-request-1'))
  })

  it('refreshes stale evidence on a conflict and explains that runtime stays unchanged', async () => {
    const user = userEvent.setup()
    apiMocks.pauseCohortRollout.mockRejectedValue(new ApiRequestError('stale', { status: 409, code: 'cohort_rollout_conflict', errors: [], conflicts: [] }))
    renderStudio(activeRolloutStudio('active'))
    await user.click(await screen.findByRole('button', { name: 'Review pause' }))
    await user.click(screen.getByRole('button', { name: 'Pause rollout' }))
    expect((await screen.findByRole('alert')).textContent).toContain('Rollout evidence changed')
    expect(screen.getByText('Records do not change participant runtime.')).toBeTruthy()
    expect(apiMocks.fetchCohortRolloutStudio).toHaveBeenCalledTimes(2)
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
    { name: 'rollback', initial: activeRolloutStudio('active'), next: studioFixture(), trigger: 'Review rollback', confirm: 'Record rollback' },
  ])('moves focus to the stable new state heading after $name', async ({ initial, next, trigger, confirm }) => {
    const user = userEvent.setup()
    renderStudio(initial, next)
    await user.click(await screen.findByRole('button', { name: trigger }))
    await user.click(screen.getByRole('button', { name: confirm }))
    const heading = await screen.findByRole('heading', { name: 'Release #4' })
    await waitFor(() => expect(document.activeElement).toBe(heading))
  })
})
