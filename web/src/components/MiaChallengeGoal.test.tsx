// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { MiaChallengeGoal } from './MiaChallengeGoal'
import { updateChallengeChatCard } from '../api'
import type { ChallengeChatCard } from '../lib/challengeChatCards'
vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(), updateChallengeChatCard: vi.fn() }))
const card: ChallengeChatCard = { id: 1, kind: 'goal', status: 'pending', lock_version: 0, enrollment_id: 10, message_id: 20, input: { target_cents: 50000, expected_plan_version_id: null }, state: {} }
beforeEach(() => vi.resetAllMocks())
afterEach(cleanup)
it('sends explicit consent only after Yes and retains the same identity for a failed response retry', async () => {
  const onDone = vi.fn()
  vi.mocked(updateChallengeChatCard).mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({ record: { ...card, status: 'closed', state: { approved_plan_version_id: 90 } }, challenge: {} as never })
  render(<MiaChallengeGoal card={card} onDone={onDone} onChangeAmount={vi.fn()} />)
  expect(updateChallengeChatCard).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Yes, set my goal to $500.00' }))
  await screen.findByRole('alert')
  const yes = screen.getByRole('button', { name: 'Yes, set my goal to $500.00' })
  await waitFor(() => expect((yes as HTMLButtonElement).disabled).toBe(false)); fireEvent.click(yes)
  await screen.findByText('Goal saved: $500.00')
  expect(onDone).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Done' })); expect(onDone).toHaveBeenCalledOnce()
  expect(vi.mocked(updateChallengeChatCard).mock.calls).toEqual([[1, { action: 'approve_goal', expected_lock_version: 0, accepted: true }], [1, { action: 'approve_goal', expected_lock_version: 0, accepted: true }]])
})
it('reviews a custom amount without approving the original proposal', () => {
  const change = vi.fn()
  render(<MiaChallengeGoal card={card} onDone={vi.fn()} onChangeAmount={change} />)
  fireEvent.click(screen.getByRole('button', { name: 'Change amount' }))
  fireEvent.change(screen.getByLabelText('New goal in dollars'), { target: { value: '400' } })
  fireEvent.click(screen.getByRole('button', { name: 'Review this amount' }))
  expect(change).toHaveBeenCalledWith('400'); expect(updateChallengeChatCard).not.toHaveBeenCalled()
})

it('does not announce success for a closed proposal without a recorded approval', async () => {
  vi.mocked(updateChallengeChatCard).mockResolvedValue({ record: { ...card, status: 'closed' }, challenge: {} as never })
  render(<MiaChallengeGoal card={card} onDone={vi.fn()} onChangeAmount={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: 'Yes, set my goal to $500.00' }))
  await screen.findByRole('alert')
  expect(screen.queryByText('Goal saved: $500.00')).toBeNull()
})
