// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { ChallengeTimeline } from './ChallengeTimeline'
afterEach(cleanup)
it('names unknown, no-spend and deposited days separately and opens the selected day', () => {
  const onDay = vi.fn(), onCheckpoint = vi.fn()
  render(<ChallengeTimeline timeline={{ checkpoints_due: [30], days: [
    { day: 1, local_on: '2026-10-01', check_in: 'unknown', future: false, purchase_count: 0, deposit_cents: null },
    { day: 2, local_on: '2026-10-02', check_in: 'no_spend', future: false, purchase_count: 0, deposit_cents: 2500 },
    { day: 90, local_on: '2026-12-29', check_in: 'unknown', future: true, purchase_count: 0, deposit_cents: null },
  ] }} onDay={onDay} onCheckpoint={onCheckpoint} />)
  expect(screen.getByRole('list', { name: 'Day symbols' }).textContent).toBe('✓ Checked in○ No spending+ Set aside· Not checked in')
  expect(screen.getByText('Swipe for all 90 days')).toBeTruthy()
  const unknown = screen.getByRole('button', { name: /Day 1,.*Not checked in/ })
  expect(unknown.textContent).not.toContain('$0')
  const saved = screen.getByRole('button', { name: /Day 2,.*No spending; \$25.00 set aside/ })
  fireEvent.click(saved); expect(onDay).toHaveBeenCalledWith('2026-10-02')
  expect((screen.getByRole('button', { name: /Day 90,.*Ahead/ }) as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(screen.getByRole('button', { name: 'Day 30 ready to review' })); expect(onCheckpoint).toHaveBeenCalledOnce()
})
