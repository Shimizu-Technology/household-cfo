// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useState } from 'react'
import type { GoalPortfolio, GoalRecord } from '../api'
import { GoalManager } from './GoalManager'

const apiMocks = vi.hoisted(() => ({
  createGoal: vi.fn(), updateGoal: vi.fn(), archiveGoal: vi.fn(), restoreGoal: vi.fn(),
}))
vi.mock('../api', async (importOriginal) => ({ ...await importOriginal<typeof import('../api')>(), ...apiMocks }))

const portfolio: GoalPortfolio = {
  active_count: 1, archived_count: 0, target_total: 0, progress_total: 0,
  target_known_count: 0, progress_known_count: 0, unknown_target_goal_ids: [1], unknown_progress_goal_ids: [1],
}
function goal(overrides: Partial<GoalRecord> = {}): GoalRecord {
  return { id: 1, label: 'Family trip', goal_type: 'travel', target_amount: null, current_amount: null, target_on: null, priority: 1, active: true, archived_at: null, source_type: 'manual_ui', source_metadata: {}, ...overrides }
}

describe('GoalManager', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    Object.defineProperty(HTMLElement.prototype, 'scrollIntoView', { configurable: true, value: vi.fn() })
    vi.stubGlobal('requestAnimationFrame', (callback: FrameRequestCallback) => window.setTimeout(() => callback(0), 0))
  })
  afterEach(() => { cleanup(); vi.unstubAllGlobals() })

  it('distinguishes unknown amounts from confirmed zero and explains the boundary', () => {
    render(<GoalManager goals={[goal()]} portfolio={portfolio} onChanged={vi.fn()} />)
    expect(screen.getByText('Progress').parentElement?.textContent).toContain('Not entered / Not entered')
    expect(screen.getByText(/never move money or change accounts/)).toBeTruthy()
  })

  it('uses a goal-specific empty state selector', () => {
    const { container } = render(<GoalManager goals={[]} portfolio={{ ...portfolio, active_count: 0, unknown_target_goal_ids: [], unknown_progress_goal_ids: [] }} onChanged={vi.fn()} />)
    expect(container.querySelector('.goal-empty')?.textContent).toContain('No tracked goals yet')
    expect(container.querySelector('.debt-empty')).toBeNull()
  })

  it('focuses invalid target and preserves blank as unknown', async () => {
    const user = userEvent.setup()
    render(<GoalManager goals={[]} portfolio={{ ...portfolio, active_count: 0, unknown_target_goal_ids: [], unknown_progress_goal_ids: [] }} onChanged={vi.fn()} />)
    await user.click(screen.getByRole('button', { name: 'Add a goal' }))
    await user.type(screen.getByPlaceholderText('Family trip'), 'New car')
    const target = screen.getAllByPlaceholderText('Unknown')[0]
    await user.type(target, '-5')
    fireEvent.submit(screen.getByRole('button', { name: 'Add goal' }).closest('form') as HTMLFormElement)
    expect((await screen.findByRole('alert')).textContent).toMatch(/Target amount must be/)
    expect(document.activeElement).toBe(target)
    expect(apiMocks.createGoal).not.toHaveBeenCalled()
  })

  it('keeps a committed goal write clear and returns to Add when the list reload fails', async () => {
    const user = userEvent.setup()
    apiMocks.createGoal.mockResolvedValue(goal({ id: 42, label: 'Tuition' }))
    render(<GoalManager goals={[]} portfolio={{ ...portfolio, active_count: 0 }} onChanged={vi.fn().mockRejectedValue(new Error('refresh failed'))} />)
    await user.click(screen.getByRole('button', { name: 'Add a goal' }))
    await user.type(screen.getByLabelText('Goal name'), 'Tuition')
    await user.click(screen.getByRole('button', { name: 'Add goal' }))
    expect(await screen.findByText(/goal change was saved, but the latest goal list could not reload/)).toBeTruthy()
    expect(screen.queryByText(/could not be saved/)).toBeNull()
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Add a goal' })))
    expect(apiMocks.createGoal).toHaveBeenCalledOnce()
  })

  it('opens the exact goal editor requested by a Mia review', async () => {
    const handled = vi.fn()
    render(<GoalManager goals={[goal(), goal({ id: 2, label: 'Tuition', goal_type: 'education' })]} portfolio={{ ...portfolio, active_count: 2 }} onChanged={vi.fn()} focusRequest={{ key: 1, actionType: 'update_goal', goalId: 2, payload: {} }} onFocusRequestHandled={handled} />)
    const input = await screen.findByDisplayValue('Tuition')
    await waitFor(() => expect(document.activeElement).toBe(input))
    expect(handled).toHaveBeenCalledOnce()
  })

  it('merges proposed goal fields without replacing unrelated saved values', async () => {
    render(<GoalManager
      goals={[goal({ id: 2, label: 'Tuition', goal_type: 'education', target_amount: 8_000, current_amount: 900, target_on: '2028-05-01' })]}
      portfolio={portfolio}
      onChanged={vi.fn()}
      focusRequest={{ key: 3, actionType: 'update_goal', goalId: 2, payload: { current_amount_cents: 125_000, current_amount_known: true, target_amount_cents: 0, target_amount_known: false, target_on: null } }}
    />)

    expect((await screen.findByLabelText('Goal name') as HTMLInputElement).value).toBe('Tuition')
    expect((screen.getByLabelText('Type') as HTMLSelectElement).value).toBe('education')
    const amounts = document.querySelectorAll<HTMLInputElement>('.goal-form input[placeholder="Unknown"]')
    expect(amounts[0].value).toBe('')
    expect(amounts[1].value).toBe('1250')
    expect((document.querySelector('.goal-form input[type="date"]') as HTMLInputElement).value).toBe('')
  })

  it('schedules one focus action when the same request rerenders before the frame runs', async () => {
    const handled = vi.fn()
    const request = { key: 7, actionType: 'update_goal' as const, goalId: 1, payload: {} }
    const { rerender } = render(<GoalManager goals={[goal()]} portfolio={portfolio} onChanged={vi.fn()} focusRequest={request} onFocusRequestHandled={handled} />)
    rerender(<GoalManager goals={[goal()]} portfolio={portfolio} onChanged={vi.fn()} focusRequest={request} onFocusRequestHandled={handled} />)

    await screen.findByDisplayValue('Family trip')
    await waitFor(() => expect(handled).toHaveBeenCalledOnce())
  })

  it('explains a stale Mia goal reference and returns focus to a safe control', async () => {
    const handled = vi.fn()
    render(<GoalManager goals={[]} portfolio={{ ...portfolio, active_count: 0, unknown_target_goal_ids: [], unknown_progress_goal_ids: [] }} onChanged={vi.fn()} focusRequest={{ key: 2, actionType: 'update_goal', goalId: 99, payload: {} }} onFocusRequestHandled={handled} />)

    expect((await screen.findByRole('alert')).textContent).toMatch(/no longer available to edit/i)
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Add a goal' })))
    expect(handled).toHaveBeenCalledOnce()
  })

  it('preserves focus deliberately moved to another field while the updated list is pending', async () => {
    const user = userEvent.setup()
    const original = goal()
    const archived = { ...original, active: false, archived_at: '2026-10-02T00:00:00Z' }
    apiMocks.archiveGoal.mockResolvedValue(archived)
    const onChanged = vi.fn().mockResolvedValue(undefined)
    const view = render(<><input aria-label="Household note" /><GoalManager goals={[original]} portfolio={portfolio} onChanged={onChanged} /></>)
    await user.click(screen.getByRole('button', { name: 'Archive' }))
    await user.click(screen.getByRole('button', { name: 'Confirm archive' }))
    await waitFor(() => expect(onChanged).toHaveBeenCalledOnce())
    await act(async () => { await new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())) })
    const note = screen.getByRole('textbox', { name: 'Household note' })
    await user.click(note)
    await user.type(note, 'Continue planning')

    view.rerender(<><input aria-label="Household note" /><GoalManager goals={[archived]} portfolio={{ ...portfolio, active_count: 0, archived_count: 1 }} onChanged={onChanged} /></>)
    await act(async () => { await new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())) })
    expect(document.activeElement).toBe(note)
    expect((view.container.querySelector('details.debt-archive') as HTMLDetailsElement).open).toBe(false)
    expect(apiMocks.archiveGoal).toHaveBeenCalledOnce()
  })

  it('preserves a second row archive confirmation while the first archive list is pending', async () => {
    const user = userEvent.setup()
    const first = goal({ id: 1, label: 'First record' })
    const second = goal({ id: 2, label: 'Second record' })
    const firstArchived = { ...first, active: false, archived_at: '2026-10-02T00:00:00Z' }
    const secondArchived = { ...second, active: false, archived_at: '2026-10-02T00:00:00Z' }
    apiMocks.archiveGoal.mockResolvedValueOnce(firstArchived).mockResolvedValueOnce(secondArchived)
    const onChanged = vi.fn().mockResolvedValue(undefined)
    const view = render(<GoalManager goals={[first, second]} portfolio={{ ...portfolio, active_count: 2 }} onChanged={onChanged} />)
    await user.click(view.container.querySelector<HTMLButtonElement>('[data-goal-id="1"] [data-goal-action="archive"]')!)
    await user.click(screen.getByRole('button', { name: 'Confirm archive' }))
    await waitFor(() => expect(onChanged).toHaveBeenCalledOnce())
    await act(async () => { await new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())) })

    // Starting another confirmation remembers a new trigger, but must not change
    // the earlier pending action's permission to move focus.
    await user.click(view.container.querySelector<HTMLButtonElement>('[data-goal-id="2"] [data-goal-action="archive"]')!)
    const secondConfirmation = screen.getByRole('button', { name: 'Confirm archive' })
    expect(document.activeElement).toBe(secondConfirmation)
    view.rerender(<GoalManager goals={[firstArchived, second]} portfolio={{ ...portfolio, active_count: 1, archived_count: 1 }} onChanged={onChanged} />)
    await act(async () => { await new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())) })
    expect(document.activeElement).toBe(secondConfirmation)
    expect((view.container.querySelector('details.debt-archive') as HTMLDetailsElement).open).toBe(false)
    expect(apiMocks.archiveGoal).toHaveBeenCalledOnce()

    // The newly confirmed action still receives its own return-focus request.
    await user.click(secondConfirmation)
    await waitFor(() => expect(onChanged).toHaveBeenCalledTimes(2))
    view.rerender(<GoalManager goals={[firstArchived, secondArchived]} portfolio={{ ...portfolio, active_count: 0, archived_count: 2 }} onChanged={onChanged} />)
    await waitFor(() => expect(document.activeElement).toBe(view.container.querySelector('[data-goal-id="2"] [data-goal-action="restore"]')))
    expect(apiMocks.archiveGoal).toHaveBeenCalledTimes(2)
  })

  it('waits for archived and restored goal lists to commit before returning focus', async () => {
    const user = userEvent.setup()
    const original = goal({ target_amount: 5_000, current_amount: 500 })
    const archived = { ...original, active: false, archived_at: '2026-10-02T00:00:00Z' }
    apiMocks.archiveGoal.mockResolvedValue(archived)
    apiMocks.restoreGoal.mockResolvedValue(original)
    const onChanged = vi.fn().mockResolvedValue(undefined)
    const view = render(<GoalManager goals={[original]} portfolio={portfolio} onChanged={onChanged} />)

    await user.click(screen.getByRole('button', { name: 'Archive' }))
    await user.click(screen.getByRole('button', { name: 'Confirm archive' }))
    await waitFor(() => expect(onChanged).toHaveBeenCalledOnce())
    // A resolved refresh does not mean the parent has committed its updated list.
    await act(async () => { await new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())) })
    expect(screen.queryByRole('button', { name: 'Restore' })).toBeNull()

    view.rerender(<GoalManager goals={[archived]} portfolio={{ ...portfolio, active_count: 0, archived_count: 1 }} onChanged={onChanged} />)
    const restore = await screen.findByRole('button', { name: 'Restore' })
    await waitFor(() => expect(document.activeElement).toBe(restore))
    expect(restore.closest('details')?.open).toBe(true)

    await user.click(restore)
    await waitFor(() => expect(onChanged).toHaveBeenCalledTimes(2))
    await act(async () => { await new Promise<void>((resolve) => window.requestAnimationFrame(() => resolve())) })
    expect(screen.queryByRole('button', { name: 'Edit' })).toBeNull()
    view.rerender(<GoalManager goals={[original]} portfolio={portfolio} onChanged={onChanged} />)
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Edit' })))
    expect(apiMocks.archiveGoal).toHaveBeenCalledOnce()
    expect(apiMocks.restoreGoal).toHaveBeenCalledOnce()
  })

  it('restores focus across save archive and restore rerenders', async () => {
    const user = userEvent.setup()
    const original = goal({ target_amount: 5_000, current_amount: 500 })
    apiMocks.updateGoal.mockResolvedValue({ ...original, label: 'Guam trip' })
    apiMocks.archiveGoal.mockResolvedValue({ ...original, label: 'Guam trip', active: false, archived_at: '2026-10-02T00:00:00Z' })
    apiMocks.restoreGoal.mockResolvedValue({ ...original, label: 'Guam trip' })
    function Stateful() {
      const [records, setRecords] = useState([original])
      const [step, setStep] = useState(0)
      async function refresh() {
        if (step === 0) setRecords((items) => items.map((item) => ({ ...item, label: 'Guam trip' })))
        if (step === 1) setRecords((items) => items.map((item) => ({ ...item, active: false, archived_at: '2026-10-02T00:00:00Z' })))
        if (step === 2) setRecords((items) => items.map((item) => ({ ...item, active: true, archived_at: null })))
        setStep((value) => value + 1)
      }
      return <GoalManager goals={records} portfolio={portfolio} onChanged={refresh} />
    }
    render(<Stateful />)
    await user.click(screen.getByRole('button', { name: 'Edit' }))
    const name = screen.getByLabelText('Goal name')
    await user.clear(name); await user.type(name, 'Guam trip')
    await user.click(screen.getByRole('button', { name: 'Save goal' }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Edit' })).toBe(document.activeElement))
    await user.click(screen.getByRole('button', { name: 'Archive' })); await user.click(screen.getByRole('button', { name: 'Confirm archive' }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Restore' })).toBe(document.activeElement))
    await user.click(screen.getByRole('button', { name: 'Restore' }))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Edit' })).toBe(document.activeElement))
  })

  it('reports draft changes and cancellation without treating unknown progress as zero', async () => {
    const user = userEvent.setup()
    const dirty = vi.fn()
    render(<GoalManager goals={[goal()]} portfolio={portfolio} onChanged={vi.fn()} onUnsavedChangesChange={dirty} />)
    await user.click(screen.getByRole('button', { name: 'Edit' }))
    expect(dirty).toHaveBeenLastCalledWith(false)
    await user.type(screen.getByLabelText(/Current progress/), '0')
    expect(dirty).toHaveBeenLastCalledWith(true)
    await user.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(dirty).toHaveBeenLastCalledWith(false)
    expect(apiMocks.updateGoal).not.toHaveBeenCalled()
  })
})
