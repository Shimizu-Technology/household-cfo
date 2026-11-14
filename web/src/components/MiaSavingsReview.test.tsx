// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { updateChallengeChatCard } from '../api'
import type { ChallengeChatCard } from '../lib/challengeChatCards'
import type { SavingsIntake } from '../lib/savingsChallenge'
import { MiaSavingsReview } from './MiaSavingsReview'
vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(), updateChallengeChatCard: vi.fn() }))
const intake = (over: Partial<SavingsIntake> = {}): SavingsIntake => ({ kind: 'contribution', amount_cents: 5000, effective_on: '2026-10-21', counted: false, approval_state: 'unreviewed_input', new_money_confirmation_required: true, ...over })
const card = (input: SavingsIntake): ChallengeChatCard => ({ id: 4, kind: 'savings', status: 'pending', lock_version: 2, enrollment_id: 10, message_id: 20, input, state: {} })
beforeEach(() => vi.resetAllMocks())
afterEach(cleanup)

it('uses plain contribution words and a local day, with a review before any save', () => {
  const onReview = vi.fn()
  render(<MiaSavingsReview intake={intake()} today="2026-10-21" onReview={onReview} />)
  expect(screen.getByText('$50 set aside · Today')).toBeTruthy()
  expect(screen.getByText(/Check it, then save it to your challenge/)).toBeTruthy()
  expect(screen.getByRole('region').textContent).not.toMatch(/contribution|unreviewed|preview|2026-10-21/i)
  expect(onReview).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Review savings' }))
  expect(onReview).toHaveBeenCalledOnce()
})

it('formats older days without an ISO date', () => {
  render(<MiaSavingsReview intake={intake({ kind: 'withdrawal', effective_on: '2026-10-19' })} today="2026-10-21" onReview={vi.fn()} />)
  expect(screen.getByText('$50 taken out · Mon, Oct 19')).toBeTruthy()
})

it('approves a saving in the card only after the new-money box and Yes, and keeps Open in Savings', async () => {
  const onApproved = vi.fn(); const onReview = vi.fn()
  const saved = intake()
  vi.mocked(updateChallengeChatCard).mockResolvedValue({ record: { ...card(saved), status: 'closed' }, challenge: {} as never })
  render(<MiaSavingsReview intake={saved} card={card(saved)} today="2026-10-21" onReview={onReview} onApproved={onApproved} />)
  const yes = screen.getByRole('button', { name: 'Yes, add $50' }) as HTMLButtonElement
  expect(yes.disabled).toBe(true)
  fireEvent.click(screen.getByLabelText(/new money I set aside after expenses/))
  expect(yes.disabled).toBe(false)
  fireEvent.click(yes)
  await screen.findByText('$50 added')
  expect(updateChallengeChatCard).toHaveBeenCalledWith(4, { action: 'approve_savings', expected_lock_version: 2, accepted: true, new_money_confirmed: true })
  fireEvent.click(screen.getByRole('button', { name: 'Done' }))
  expect(onApproved).toHaveBeenCalledOnce()
  expect(onReview).not.toHaveBeenCalled()
})

it('takes a withdrawal out without a new-money box, and a correction says what it replaces', async () => {
  const withdrawal = intake({ kind: 'withdrawal' })
  vi.mocked(updateChallengeChatCard).mockResolvedValue({ record: { ...card(withdrawal), status: 'closed' }, challenge: {} as never })
  const { unmount } = render(<MiaSavingsReview intake={withdrawal} card={card(withdrawal)} today="2026-10-21" onReview={vi.fn()} />)
  expect(screen.queryByRole('checkbox')).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Yes, take out $50' }))
  await screen.findByText('$50 taken out')
  expect(updateChallengeChatCard).toHaveBeenCalledWith(4, { action: 'approve_savings', expected_lock_version: 2, accepted: true })
  unmount()
  const fix = intake({ amount_cents: 1500, correction: { id: 1, lock_version: 0, current_approved_version_id: 3, current_approved_version: { signed_cents: 2000 } } as never })
  render(<MiaSavingsReview intake={fix} card={card(fix)} today="2026-10-21" onReview={vi.fn()} />)
  expect(screen.getByText('Replace $20 with $15 · Today')).toBeTruthy()
  expect(screen.queryByRole('checkbox')).toBeNull()
  expect(screen.getByRole('button', { name: 'Yes, change it to $15' })).toBeTruthy()
})

it('shows a refused approval plainly and can try again', async () => {
  const saved = intake()
  vi.mocked(updateChallengeChatCard).mockRejectedValueOnce(new Error('offline'))
  render(<MiaSavingsReview intake={saved} card={card(saved)} today="2026-10-21" onReview={vi.fn()} />)
  fireEvent.click(screen.getByLabelText(/new money I set aside/))
  fireEvent.click(screen.getByRole('button', { name: 'Yes, add $50' }))
  await screen.findByRole('alert')
  await waitFor(() => expect((screen.getByRole('button', { name: 'Yes, add $50' }) as HTMLButtonElement).disabled).toBe(false))
})

it('sends her to Savings when the day is still unknown or there is no saved card', () => {
  const onReview = vi.fn()
  render(<MiaSavingsReview intake={intake({ effective_on: '', date_required: true })} card={card(intake())} today="2026-10-21" onReview={onReview} />)
  expect(screen.queryByRole('button', { name: /^Yes/ })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Review savings' }))
  expect(onReview).toHaveBeenCalledOnce()
})

it('fix2 exposes the saved savings status and focuses an inert result', async () => {
  const saved = intake()
  vi.mocked(updateChallengeChatCard).mockResolvedValue({ record: { ...card(saved), status: 'closed' }, challenge: {} as never })
  render(<MiaSavingsReview intake={saved} card={card(saved)} today="2026-10-21" onReview={vi.fn()} />)
  fireEvent.click(screen.getByLabelText(/new money I set aside/))
  const yes = screen.getByRole('button', { name: 'Yes, add $50' }); yes.focus(); fireEvent.click(yes)
  const status = await screen.findByRole('status')
  expect(status.textContent).toBe('Saved to your challenge. Your total is up to date.')
  expect(status.closest('details')).toBeNull()
  await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('heading', { name: '$50 added' })))
})
