// @vitest-environment jsdom

import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { type CohortInitialLaunch } from '../api'
import { InitialCohortLaunch } from './InitialCohortLaunch'

const apiMocks = vi.hoisted(() => ({
  fetchCohortInitialLaunch: vi.fn(),
  launchCohortRelease: vi.fn(),
  createCohortReleaseRequestId: vi.fn(() => 'first-launch-request'),
}))
vi.mock('../api', async (importOriginal) => ({ ...await importOriginal<typeof import('../api')>(), ...apiMocks }))

const ready: CohortInitialLaunch = {
  cohort: { id: 12, name: 'Mrs. Mel cohort', participant_count: 6 },
  active_release_id: null, release: { id: 41, release_number: 1 }, can_launch: true,
  blockers: [], preview_digest: 'a'.repeat(64),
  message: 'Launching makes the sealed brand, assistant, and tools the default for every participant.',
}
const lifecycle = () => ({ pending: false, begin: vi.fn(() => ({ id: 1, workspaceId: 2 })), isCurrent: vi.fn(() => true), finish: vi.fn() })

beforeEach(() => {
  vi.resetAllMocks()
  apiMocks.createCohortReleaseRequestId.mockReturnValue('first-launch-request')
  apiMocks.fetchCohortInitialLaunch.mockResolvedValue(ready)
  apiMocks.launchCohortRelease.mockResolvedValue({ launch: { ...ready, active_release_id: 41, can_launch: false }, replayed: false })
})
afterEach(cleanup)

describe('InitialCohortLaunch', () => {
  it('requires explicit impact review before launching and records the shown digest', async () => {
    const user = userEvent.setup()
    const onLaunch = vi.fn()
    const mutationLifecycle = lifecycle()
    render(<InitialCohortLaunch cohortId={12} mutationLifecycle={mutationLifecycle} onLaunch={onLaunch} />)
    await user.click(await screen.findByRole('button', { name: 'Review first launch' }))
    expect(screen.getByText(/6 current participants will use this release/)).toBeTruthy()
    expect(document.activeElement).toBe(screen.getByRole('heading', { name: 'Review first cohort launch' }))
    expect(apiMocks.launchCohortRelease).not.toHaveBeenCalled()
    await user.click(screen.getByRole('button', { name: 'Launch cohort now' }))
    await screen.findByRole('heading', { name: 'This cohort is launched' })
    expect(apiMocks.launchCohortRelease).toHaveBeenCalledWith(12, { release_id: 41, preview_digest: ready.preview_digest }, 'first-launch-request')
    expect(onLaunch).toHaveBeenCalledTimes(1)
    expect(mutationLifecycle.finish).toHaveBeenCalled()
    expect(screen.queryByRole('button', { name: 'Review first launch' })).toBeNull()
  })

  it('shows concrete readiness blockers and keeps unauthorized users from launch controls', async () => {
    apiMocks.fetchCohortInitialLaunch.mockResolvedValue({ ...ready, can_launch: false, blockers: ['Seal a release before launching this cohort.'] })
    render(<InitialCohortLaunch cohortId={12} mutationLifecycle={lifecycle()} onLaunch={vi.fn()} />)
    await screen.findByText('Seal a release before launching this cohort.')
    expect(screen.queryByRole('button', { name: 'Review first launch' })).toBeNull()
  })

  it('reloads after a stale failure and requires a fresh review without silently launching again', async () => {
    const user = userEvent.setup()
    apiMocks.launchCohortRelease.mockRejectedValue(new Error('Participants changed. Reload and review again.'))
    render(<InitialCohortLaunch cohortId={12} mutationLifecycle={lifecycle()} onLaunch={vi.fn()} />)
    await user.click(await screen.findByRole('button', { name: 'Review first launch' }))
    await user.click(screen.getByRole('button', { name: 'Launch cohort now' }))
    await screen.findByRole('alert')
    expect(apiMocks.fetchCohortInitialLaunch).toHaveBeenCalledTimes(2)
    expect(apiMocks.launchCohortRelease).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('button', { name: 'Launch cohort now' })).toBeNull()
    expect(screen.getByRole('button', { name: 'Review first launch' })).toBeTruthy()
  })

  it('suppresses a stale mutation response after workspace context changes', async () => {
    const user = userEvent.setup()
    let finish!: (value: { launch: CohortInitialLaunch; replayed: boolean }) => void
    apiMocks.launchCohortRelease.mockImplementation(() => new Promise((resolve) => { finish = resolve }))
    const onLaunch = vi.fn()
    const mutationLifecycle = lifecycle()
    render(<InitialCohortLaunch cohortId={12} mutationLifecycle={mutationLifecycle} onLaunch={onLaunch} />)
    await user.click(await screen.findByRole('button', { name: 'Review first launch' }))
    await user.click(screen.getByRole('button', { name: 'Launch cohort now' }))
    mutationLifecycle.isCurrent.mockReturnValue(false)
    finish({ launch: { ...ready, active_release_id: 41 }, replayed: false })
    await waitFor(() => expect(mutationLifecycle.finish).toHaveBeenCalled())
    expect(onLaunch).not.toHaveBeenCalled()
    expect(screen.queryByText(/Cohort launched/)).toBeNull()
  })

  it('ignores an old cohort load after switching to another cohort', async () => {
    let finish!: (value: CohortInitialLaunch) => void
    apiMocks.fetchCohortInitialLaunch.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve }))
    const mutationLifecycle = lifecycle()
    const onLaunch = vi.fn()
    const rendered = render(<InitialCohortLaunch cohortId={12} mutationLifecycle={mutationLifecycle} onLaunch={onLaunch} />)
    await waitFor(() => expect(apiMocks.fetchCohortInitialLaunch).toHaveBeenCalledTimes(1))
    apiMocks.fetchCohortInitialLaunch.mockResolvedValue({ ...ready, cohort: { ...ready.cohort, id: 13, name: 'Another cohort' } })
    rendered.rerender(<InitialCohortLaunch cohortId={13} mutationLifecycle={mutationLifecycle} onLaunch={onLaunch} />)
    await screen.findByRole('button', { name: 'Review first launch' })
    await act(async () => { finish(ready) })
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Review first launch' }))
    expect(screen.getByText(/Another cohort/)).toBeTruthy()
    expect(screen.queryByText(/Mrs. Mel cohort/)).toBeNull()
  })

  it('lets coaches cancel a review without launching', async () => {
    const user = userEvent.setup()
    render(<InitialCohortLaunch cohortId={12} mutationLifecycle={lifecycle()} onLaunch={vi.fn()} />)
    await user.click(await screen.findByRole('button', { name: 'Review first launch' }))
    await user.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(apiMocks.launchCohortRelease).not.toHaveBeenCalled()
    expect(screen.queryByRole('button', { name: 'Launch cohort now' })).toBeNull()
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Review first launch' }))
  })

  it('rejects a mismatched cohort response without exposing launch controls', async () => {
    apiMocks.fetchCohortInitialLaunch.mockResolvedValue({ ...ready, cohort: { ...ready.cohort, id: 99 } })
    render(<InitialCohortLaunch cohortId={12} mutationLifecycle={lifecycle()} onLaunch={vi.fn()} />)
    await screen.findByRole('alert')
    expect(screen.queryByRole('button', { name: 'Review first launch' })).toBeNull()
    expect(apiMocks.launchCohortRelease).not.toHaveBeenCalled()
  })
})
