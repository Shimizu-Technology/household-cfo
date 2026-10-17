// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AdminCohort, SavingsChallengeAccess } from '../api'
import { SavingsChallengeAccessPanel } from './SavingsChallengeAccessPanel'

const apiMocks = vi.hoisted(() => ({
  changeSavingsChallengeAccess: vi.fn(),
  createCohortReleaseRequestId: vi.fn(() => 'request-1'),
}))
vi.mock('../api', async (importOriginal) => ({ ...await importOriginal<typeof import('../api')>(), ...apiMocks }))

const base: SavingsChallengeAccess = {
  state: 'ready', label: 'Ready to open', enabled: false, on_hold: true, capacity: 30, participant_count: 8,
  can_open: true, can_pause: false, can_change: true, participants_can_join: false, blockers: [], recent_events: [],
}
const cohortWith = (challenge: Partial<SavingsChallengeAccess>) => ({ id: 7, name: 'BOG pilot', savings_challenge: { ...base, ...challenge } }) as AdminCohort

beforeEach(() => {
  vi.resetAllMocks()
  apiMocks.createCohortReleaseRequestId.mockReturnValue('request-1')
  apiMocks.changeSavingsChallengeAccess.mockResolvedValue({ savings_challenge: { ...base, state: 'open' }, replayed: false })
})
afterEach(cleanup)

describe('SavingsChallengeAccessPanel', () => {
  it('shows status and capacity plainly', () => {
    render(<SavingsChallengeAccessPanel cohort={cohortWith({})} busy={false} onChanged={vi.fn()} />)
    expect(screen.getByRole('status').textContent).toBe('Ready to open')
    expect(screen.getByText(/8 of 30 places/)).toBeTruthy()
  })

  it('lists what participants will experience and requires a reason before opening', async () => {
    const user = userEvent.setup()
    const onChanged = vi.fn()
    render(<SavingsChallengeAccessPanel cohort={cohortWith({})} busy={false} onChanged={onChanged} />)
    await user.click(screen.getByRole('button', { name: 'Open the challenge to participants' }))
    expect(screen.getByText(/Pick a comfortable target/)).toBeTruthy()
    const confirm = screen.getByRole('button', { name: 'Open the challenge' })
    expect(confirm).toHaveProperty('disabled', true)
    await user.type(screen.getByLabelText(/Reason/), 'Kickoff is today')
    await user.click(confirm)
    await waitFor(() => expect(onChanged).toHaveBeenCalled())
    expect(apiMocks.changeSavingsChallengeAccess).toHaveBeenCalledWith(7, 'open', { reason: 'Kickoff is today', expected_state: 'ready' }, 'request-1')
    expect(screen.getByText(/The challenge is open/)).toBeTruthy()
  })

  it('pauses with a reason and without sending an expected state', async () => {
    const user = userEvent.setup()
    render(<SavingsChallengeAccessPanel cohort={cohortWith({ state: 'open', label: 'Open', can_open: false, can_pause: true, enabled: true, on_hold: false })} busy={false} onChanged={vi.fn()} />)
    expect(screen.queryByRole('button', { name: /Open the challenge/ })).toBeNull()
    await user.click(screen.getByRole('button', { name: 'Pause the challenge' }))
    expect(screen.getByText(/no longer be able to/)).toBeTruthy()
    await user.type(screen.getByLabelText(/Reason/), 'Fixing a bug')
    await user.click(screen.getAllByRole('button', { name: 'Pause the challenge' })[0])
    await waitFor(() => expect(apiMocks.changeSavingsChallengeAccess).toHaveBeenCalledWith(7, 'pause', { reason: 'Fixing a bug' }, 'request-1'))
  })

  it('offers Reopen when paused and shows the plain refusal reason without losing the form', async () => {
    const user = userEvent.setup()
    const onChanged = vi.fn()
    apiMocks.changeSavingsChallengeAccess.mockRejectedValue(new Error('Set the cohort status to Enrolling or Active first.'))
    render(<SavingsChallengeAccessPanel cohort={cohortWith({ state: 'paused', label: 'Paused' })} busy={false} onChanged={onChanged} />)
    await user.click(screen.getByRole('button', { name: 'Reopen the challenge' }))
    await user.type(screen.getByLabelText(/Reason/), 'Ready again')
    await user.click(screen.getByRole('button', { name: 'Open the challenge' }))
    expect((await screen.findByRole('alert')).textContent).toContain('Enrolling or Active')
    expect(onChanged).toHaveBeenCalledTimes(1)
  })

  it('shows blockers and hides controls for people who cannot change it', () => {
    render(<SavingsChallengeAccessPanel cohort={cohortWith({ state: 'not_set_up', label: 'Not set up', can_open: false, can_change: false, blockers: ['Seal and launch a release first.'] })} busy={false} onChanged={vi.fn()} />)
    expect(screen.getByText('Seal and launch a release first.')).toBeTruthy()
    expect(screen.queryByRole('button')).toBeNull()
    expect(screen.getByText(/Only a platform administrator/)).toBeTruthy()
  })

  it('lists the audit trail', () => {
    render(<SavingsChallengeAccessPanel cohort={cohortWith({ state: 'open', label: 'Open', recent_events: [{ id: 1, action: 'open', from_state: 'ready', to_state: 'open', reason: 'Kickoff', occurred_at: '2026-10-17T10:00:00Z', actor_name: 'Leon' }] })} busy={false} onChanged={vi.fn()} />)
    expect(screen.getByText(/by Leon/)).toBeTruthy()
    expect(screen.getByText('Kickoff')).toBeTruthy()
  })
})
