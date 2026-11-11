// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { fetchDailyContext, fetchDailyPage, fetchSavingsChallenge, mutateDaily } from '../api'
import type { CheckpointSnapshot, DailyContext } from '../lib/dailyChallenge'
import { setDailyExpectedUser } from '../lib/dailyRecovery'
import type { SavingsChallenge } from '../lib/savingsChallenge'
import { MiaCheckpointCard } from './MiaCheckpointCard'
vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(), fetchSavingsChallenge: vi.fn(), fetchDailyContext: vi.fn(), fetchDailyPage: vi.fn(), mutateDaily: vi.fn() }))

const actor = { user_id: 5, household_id: 8 }
const envelope = { actor_scope: actor, enrollment_id: 11, cohort_id: 2 }
const context = { ...envelope, calendar: { local_today: '2026-12-31', checkpoints: { '30': '2026-12-12', '60': '2027-01-11', '90': '2027-02-10' } } } as unknown as DailyContext
const challenge = (due: number[]) => ({ enrollment: { id: 11 }, accepted_plan: null, projection: null, timeline: { days: [], checkpoints_due: due } }) as unknown as SavingsChallenge
const snapshot = (day: 30 | 60 | 90, over: Partial<CheckpointSnapshot['savings']> = {}) => ({
  calculation_version: 'savings_checkpoint_v1', milestone_day: day, cutoff_on: '2026-12-12', captured_at: '2026-12-31T00:00:00Z', time_zone: 'Pacific/Guam', plan_selection: 'approved_by_cutoff',
  savings: { reported_cents: 12_500, target_cents: 50_000, achieved: false, ...over }, baseline: { version_id: null, coverage_status: 'none', source_evidence_status: 'none' },
  daily: { scope: 'participant_daily_reports', approved_purchase_count: 4, reported_spend_cents: 6_000, completed_check_in_days: 9, no_spend_days: 3, unknown_reported_days: 0, unknown_unreported_days: 21, all_account_completeness: 'unknown', no_spend_discrepancy_days: 0 },
  final_confirmation_status: 'not_applicable',
}) as unknown as CheckpointSnapshot
const draft = (day: 30 | 60 | 90, over: Partial<CheckpointSnapshot['savings']> = {}) => ({ id: 41, lock_version: 0, base_version_id: null, base_head_lock_version: 0, status: 'pending', savings_checkpoint_id: 3, snapshot: snapshot(day, over), reason: null })

beforeEach(() => {
  vi.resetAllMocks(); window.sessionStorage.clear(); setDailyExpectedUser(5)
  vi.mocked(fetchDailyContext).mockResolvedValue(context)
  vi.mocked(fetchDailyPage).mockResolvedValue({ ...envelope, records: [], next_cursor: null } as never)
})
afterEach(cleanup)

it('shows nothing when no checkpoint is due', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([]))
  const { container } = render(<MiaCheckpointCard actor={actor} cohortId={2} onDone={vi.fn()} onOpenCheckpoints={vi.fn()} />)
  await waitFor(() => expect(fetchDailyContext).toHaveBeenCalled())
  expect(container.textContent).toBe('')
})

it('offers a due checkpoint, shows what she set aside and noticed, and approves only after the box and a tap', async () => {
  const onDone = vi.fn()
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([30]))
  vi.mocked(mutateDaily).mockImplementation((async (action: string) => action === 'checkpoint_stage' ? { ...envelope, record: draft(30) } : { ...envelope, record: { id: 5 } }) as never)
  render(<MiaCheckpointCard actor={actor} cohortId={2} onDone={onDone} onOpenCheckpoints={vi.fn()} />)
  await screen.findByRole('heading', { name: 'Day 30 is ready to look back on' })
  expect(mutateDaily).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Look at Day 30' }))
  await screen.findByRole('heading', { name: 'Day 30: here’s your look back' })
  expect(screen.getByText('$125.00')).toBeTruthy()
  expect(screen.getByText('$500')).toBeTruthy()
  expect(screen.getByText('9 days, 3 with no spending')).toBeTruthy()
  expect(screen.getByText('21 days so far, so I don’t know those')).toBeTruthy()
  const approve = screen.getByRole('button', { name: 'Approve Day 30' }) as HTMLButtonElement
  expect(approve.disabled).toBe(true)
  fireEvent.click(screen.getByLabelText('I checked the dates, savings, goal and any gaps shown above.'))
  fireEvent.click(approve)
  await screen.findByRole('heading', { name: 'Biba! Day 30 is done.' })
  const calls = vi.mocked(mutateDaily).mock.calls
  expect(calls.map(call => call[0])).toEqual(['checkpoint_stage', 'checkpoint_approve'])
  expect(calls[0][1]).toMatchObject({ milestone_day: 30, expected_version_id: null, expected_head_lock_version: 0, final_confirmation_accepted: false })
  expect(calls[1][1]).toMatchObject({ draft_id: 41, accepted: true, expected_draft_lock_version: 0 })
  fireEvent.click(screen.getByRole('button', { name: 'Keep going' }))
  expect(onDone).toHaveBeenCalledOnce()
})

it('never shows an unknown total as $0, and Day 90 carries the finished-reporting choice into the review', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([90]))
  vi.mocked(mutateDaily).mockResolvedValue({ ...envelope, record: draft(90, { reported_cents: null }) } as never)
  render(<MiaCheckpointCard actor={actor} cohortId={2} onDone={vi.fn()} onOpenCheckpoints={vi.fn()} />)
  await screen.findByRole('heading', { name: 'Day 90 is ready to look back on' })
  fireEvent.click(screen.getByLabelText(/I’m finished reporting my 90 days/))
  fireEvent.click(screen.getByRole('button', { name: 'Look at Day 90' }))
  await screen.findByText('Nothing reported yet')
  expect(screen.queryByText('$0.00')).toBeNull()
  expect(vi.mocked(mutateDaily).mock.calls[0][1]).toMatchObject({ milestone_day: 90, final_confirmation_accepted: true })
})

it('Not now hides it for the day, and Open in Checkpoints goes to the screen', async () => {
  const open = vi.fn()
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([30]))
  const { container } = render(<MiaCheckpointCard actor={actor} cohortId={2} onDone={vi.fn()} onOpenCheckpoints={open} />)
  await screen.findByRole('heading', { name: 'Day 30 is ready to look back on' })
  fireEvent.click(screen.getByRole('button', { name: 'Open in Checkpoints' }))
  expect(open).toHaveBeenCalledOnce()
  fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
  expect(container.textContent).toBe('')
  cleanup()
  const again = render(<MiaCheckpointCard actor={actor} cohortId={2} onDone={vi.fn()} onOpenCheckpoints={open} />)
  await waitFor(() => expect(fetchDailyContext).toHaveBeenCalledTimes(2))
  expect(again.container.textContent).toBe('')
})
