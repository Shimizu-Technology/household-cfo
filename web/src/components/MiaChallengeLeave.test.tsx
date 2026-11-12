// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { MiaChallengeLeave } from './MiaChallengeLeave'
import { updateChallengeChatCard, type MiaMessage } from '../api'
import type { ChallengeChatCard } from '../lib/challengeChatCards'
vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(), updateChallengeChatCard: vi.fn() }))
const card: ChallengeChatCard = { id: 1, kind: 'leave', status: 'pending', lock_version: 0, enrollment_id: 10, message_id: 20, input: { intents: ['leave', 'pause'] }, state: {} }
const message = { id: 21, role: 'assistant', content: "I've let your coach know you'd like to pause." } as MiaMessage
beforeEach(() => vi.resetAllMocks())
afterEach(cleanup)
it('shares only the explicitly chosen intent and retries with the same card', async () => {
  const done = vi.fn(), confirmed = vi.fn()
  vi.mocked(updateChallengeChatCard).mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({ record: { ...card, status: 'closed', state: { leave_intent: 'pause' } }, assistant_message: message })
  render(<MiaChallengeLeave card={card} onDone={done} onConfirmed={confirmed} />)
  expect(updateChallengeChatCard).not.toHaveBeenCalled()
  const button = screen.getByRole('button', { name: 'Let my coach know I’d like to pause' })
  fireEvent.click(button)
  await screen.findByRole('alert')
  expect(confirmed).not.toHaveBeenCalled()
  await waitFor(() => expect((button as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(button)
  await waitFor(() => expect(confirmed).toHaveBeenCalledWith(message))
  expect(done).toHaveBeenCalledOnce()
  expect(vi.mocked(updateChallengeChatCard).mock.calls).toEqual([[1, { action: 'request_leave', intent: 'pause', expected_lock_version: 0, accepted: true }], [1, { action: 'request_leave', intent: 'pause', expected_lock_version: 0, accepted: true }]])
})
it('Not now closes without sharing an intent', async () => {
  const confirmed = vi.fn(), done = vi.fn()
  vi.mocked(updateChallengeChatCard).mockResolvedValue({ record: { ...card, status: 'closed' } })
  render(<MiaChallengeLeave card={card} onDone={done} onConfirmed={confirmed} />)
  fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
  await waitFor(() => expect(done).toHaveBeenCalledOnce())
  expect(confirmed).not.toHaveBeenCalled()
  expect(updateChallengeChatCard).toHaveBeenCalledWith(1, { action: 'dismiss', expected_lock_version: 0 })
})
it('does not report success for a closed card without a matching sent intent', async () => {
  const confirmed = vi.fn()
  vi.mocked(updateChallengeChatCard).mockResolvedValue({ record: { ...card, status: 'closed' } })
  render(<MiaChallengeLeave card={card} onDone={vi.fn()} onConfirmed={confirmed} />)
  fireEvent.click(screen.getByRole('button', { name: 'Let my coach know I’d like to leave' }))
  await screen.findByRole('alert')
  expect(confirmed).not.toHaveBeenCalled()
})

it('does not insert an old program confirmation after its card unmounts', async () => {
  let finish!: (value: Awaited<ReturnType<typeof updateChallengeChatCard>>) => void
  vi.mocked(updateChallengeChatCard).mockReturnValue(new Promise(resolve => { finish = resolve }))
  const confirmed = vi.fn(), done = vi.fn()
  const view = render(<MiaChallengeLeave card={card} onDone={done} onConfirmed={confirmed} />)
  fireEvent.click(screen.getByRole('button', { name: 'Let my coach know I’d like to pause' }))
  view.unmount()
  finish({ record: { ...card, status: 'closed', state: { leave_intent: 'pause' } }, assistant_message: message })
  await Promise.resolve()
  expect(confirmed).not.toHaveBeenCalled()
  expect(done).not.toHaveBeenCalled()
})
