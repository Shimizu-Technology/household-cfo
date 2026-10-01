// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
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

  it('opens the exact goal editor requested by a Mia review', async () => {
    const handled = vi.fn()
    render(<GoalManager goals={[goal(), goal({ id: 2, label: 'Tuition', goal_type: 'education' })]} portfolio={{ ...portfolio, active_count: 2 }} onChanged={vi.fn()} focusRequest={{ key: 1, actionType: 'update_goal', goalId: 2 }} onFocusRequestHandled={handled} />)
    const input = await screen.findByDisplayValue('Tuition')
    await waitFor(() => expect(document.activeElement).toBe(input))
    expect(handled).toHaveBeenCalledOnce()
  })

  it('schedules one focus action when the same request rerenders before the frame runs', async () => {
    const handled = vi.fn()
    const request = { key: 7, actionType: 'update_goal' as const, goalId: 1 }
    const { rerender } = render(<GoalManager goals={[goal()]} portfolio={portfolio} onChanged={vi.fn()} focusRequest={request} onFocusRequestHandled={handled} />)
    rerender(<GoalManager goals={[goal()]} portfolio={portfolio} onChanged={vi.fn()} focusRequest={request} onFocusRequestHandled={handled} />)

    await screen.findByDisplayValue('Family trip')
    await waitFor(() => expect(handled).toHaveBeenCalledOnce())
  })

  it('explains a stale Mia goal reference and returns focus to a safe control', async () => {
    const handled = vi.fn()
    render(<GoalManager goals={[]} portfolio={{ ...portfolio, active_count: 0, unknown_target_goal_ids: [], unknown_progress_goal_ids: [] }} onChanged={vi.fn()} focusRequest={{ key: 2, actionType: 'update_goal', goalId: 99 }} onFocusRequestHandled={handled} />)

    expect((await screen.findByRole('alert')).textContent).toMatch(/no longer available to edit/i)
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Add a goal' })))
    expect(handled).toHaveBeenCalledOnce()
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
})
