// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { MiaSavingsReview } from './MiaSavingsReview'
afterEach(cleanup)
it('uses plain contribution words and a local day, with a review before any save', () => {
  const onReview = vi.fn()
  render(<MiaSavingsReview intake={{ kind: 'contribution', amount_cents: 5000, effective_on: '2026-10-21', counted: false, approval_state: 'unreviewed_input' }} today="2026-10-21" onReview={onReview} />)
  expect(screen.getByText('$50.00 set aside · Today')).toBeTruthy()
  expect(screen.getByText(/Check it, then save it to your challenge/)).toBeTruthy()
  expect(screen.getByRole('region').textContent).not.toMatch(/contribution|unreviewed|preview|2026-10-21/i)
  expect(onReview).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Review savings' }))
  expect(onReview).toHaveBeenCalledOnce()
})
it('formats older days without an ISO date', () => {
  render(<MiaSavingsReview intake={{ kind: 'withdrawal', amount_cents: 5000, effective_on: '2026-10-19', counted: false, approval_state: 'unreviewed_input' }} today="2026-10-21" onReview={vi.fn()} />)
  expect(screen.getByText('$50.00 taken out · Mon, Oct 19')).toBeTruthy()
})
