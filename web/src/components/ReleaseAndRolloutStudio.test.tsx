// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ReleaseAndRolloutStudio } from './ReleaseAndRolloutStudio'

vi.mock('./CohortReleaseStudio', () => ({ CohortReleaseStudio: ({ beforeReleaseAction, onReleaseChange }: { beforeReleaseAction?: () => boolean; onReleaseChange?: () => void }) => <div>Release content<button type="button" onClick={() => { if (beforeReleaseAction?.() !== false) onReleaseChange?.() }}>Simulate saved version</button></div> }))
vi.mock('./InitialCohortLaunch', () => ({ InitialCohortLaunch: () => <div>First launch review</div> }))
vi.mock('./CohortRolloutStudio', () => ({ CohortRolloutStudio: ({ onDirtyChange }: { onDirtyChange: (dirty: boolean) => void }) => <label>Plan note<input aria-label="Plan note" onChange={(event) => onDirtyChange(Boolean(event.target.value))} /></label> }))

const cohorts = [
  { id: 12, name: 'Tuesday cohort', status: 'active' as const, assignable: true, blocked_reason: null, persona_assignment: null },
  { id: 13, name: 'Thursday cohort', status: 'enrolling' as const, assignable: true, blocked_reason: null, persona_assignment: null },
]

afterEach(() => { cleanup(); vi.restoreAllMocks() })

describe('ReleaseAndRolloutStudio', () => {
  it('leads with a group action and leaves lifecycle details in the relevant step', () => {
    render(<ReleaseAndRolloutStudio cohorts={cohorts} cohortsLoading={false} mutationLifecycle={{ pending: false, begin: vi.fn(), isCurrent: vi.fn(), finish: vi.fn() }} selectedCohortId={12} onSelectedCohortIdChange={vi.fn()} onDirtyChange={vi.fn()} />)
    expect(screen.getByRole('heading', { name: 'Launch or update your group' })).toBeTruthy()
    expect(screen.queryByText(/captured baseline/)).toBeNull()
    expect(screen.getByRole('tabpanel', { name: /Review settings Prepare a version/ }).getAttribute('tabindex')).toBe('0')
  })

  it('supports tab keyboard navigation and preserves an in-progress plan between subviews', async () => {
    const user = userEvent.setup()
    render(<ReleaseAndRolloutStudio cohorts={cohorts} cohortsLoading={false} mutationLifecycle={{ pending: false, begin: vi.fn(), isCurrent: vi.fn(), finish: vi.fn() }} selectedCohortId={12} onSelectedCohortIdChange={vi.fn()} onDirtyChange={vi.fn()} />)
    const releaseTab = screen.getByRole('tab', { name: /Review settings Prepare a version/ })
    const rolloutTab = screen.getByRole('tab', { name: /Update group Choose who goes first/ })
    releaseTab.focus()
    await user.keyboard('{ArrowRight}')
    expect(document.activeElement).toBe(rolloutTab)
    expect(rolloutTab.getAttribute('aria-selected')).toBe('true')
    expect(screen.getByRole('tabpanel', { name: /Update group Choose who goes first/ }).getAttribute('tabindex')).toBe('0')
    await user.type(screen.getByLabelText('Plan note'), 'Pilot first')
    rolloutTab.focus()
    await user.keyboard('{Home}')
    expect(document.activeElement).toBe(releaseTab)
    await user.keyboard('{End}')
    expect((screen.getByLabelText('Plan note') as HTMLInputElement).value).toBe('Pilot first')
  })

  it('does not discard a dirty rollout draft when cohort switching is declined', async () => {
    const user = userEvent.setup()
    const changeCohort = vi.fn()
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
    render(<ReleaseAndRolloutStudio cohorts={cohorts} cohortsLoading={false} mutationLifecycle={{ pending: false, begin: vi.fn(), isCurrent: vi.fn(), finish: vi.fn() }} selectedCohortId={12} onSelectedCohortIdChange={changeCohort} onDirtyChange={vi.fn()} />)
    await user.click(screen.getByRole('tab', { name: /Update group Choose who goes first/ }))
    await user.type(screen.getByLabelText('Plan note'), 'Keep this')
    fireEvent.change(screen.getByRole('combobox', { name: 'Group' }), { target: { value: '13' } })
    expect(confirm).toHaveBeenCalledWith('Discard the update plan you have not saved and switch groups?')
    expect(changeCohort).not.toHaveBeenCalled()
    expect((screen.getByRole('combobox', { name: 'Group' }) as HTMLSelectElement).value).toBe('12')
  })

  it('guards a release mutation from silently resetting a dirty rollout plan', async () => {
    const user = userEvent.setup()
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
    const onDirtyChange = vi.fn()
    render(<ReleaseAndRolloutStudio cohorts={cohorts} cohortsLoading={false} mutationLifecycle={{ pending: false, begin: vi.fn(), isCurrent: vi.fn(), finish: vi.fn() }} selectedCohortId={12} onSelectedCohortIdChange={vi.fn()} onDirtyChange={onDirtyChange} />)
    await user.click(screen.getByRole('tab', { name: /Update group Choose who goes first/ }))
    await user.type(screen.getByLabelText('Plan note'), 'Pilot first')
    await user.click(screen.getByRole('tab', { name: /Review settings Prepare a version/ }))
    await user.click(screen.getByRole('button', { name: 'Simulate saved version' }))
    expect(confirm).toHaveBeenCalledWith('Preparing a new version will reset the update plan you have not saved. Continue and discard that plan after the version is saved?')
    expect((screen.getByLabelText('Plan note') as HTMLInputElement).value).toBe('Pilot first')

    confirm.mockReturnValue(true)
    await user.click(screen.getByRole('button', { name: 'Simulate saved version' }))
    await user.click(screen.getByRole('tab', { name: /Update group Choose who goes first/ }))
    expect((screen.getByLabelText('Plan note') as HTMLInputElement).value).toBe('')
    expect(onDirtyChange).toHaveBeenLastCalledWith(false)
  })
})
