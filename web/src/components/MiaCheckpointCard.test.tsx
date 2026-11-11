// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ApiRequestError, fetchDailyContext, fetchDailyPage, fetchDailyRequestStatus, fetchSavingsChallenge, mutateDaily } from '../api'
import type { CheckpointSnapshot, DailyContext } from '../lib/dailyChallenge'
import { setDailyExpectedUser } from '../lib/dailyRecovery'
import type { SavingsChallenge } from '../lib/savingsChallenge'
import { MiaCheckpointCard } from './MiaCheckpointCard'
vi.mock('../api', async original => ({ ...await original<typeof import('../api')>(), fetchSavingsChallenge: vi.fn(), fetchDailyContext: vi.fn(), fetchDailyPage: vi.fn(), fetchDailyRequestStatus: vi.fn(), mutateDaily: vi.fn() }))

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

const tickBox = () => fireEvent.click(screen.getByLabelText('I checked the dates, savings, goal and any gaps shown above.'))
const stageEverything = (over: Partial<CheckpointSnapshot['savings']> = {}) => (async (action: string, input: { milestone_day?: 30 | 60 | 90 }) => action === 'checkpoint_stage' ? { ...envelope, record: draft(input.milestone_day ?? 30, over) } : { ...envelope, record: { id: 5 } }) as never

it('Day 30 then Day 60 in one sitting: Day 60 gets its own request keys and its own checkbox', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([30, 60]))
  vi.mocked(mutateDaily).mockImplementation(stageEverything())
  const props = { actor, cohortId: 2, onDone: vi.fn(), onOpenCheckpoints: vi.fn() }
  const view = render(<MiaCheckpointCard {...props} refreshKey={0} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Look at Day 30' }))
  await screen.findByRole('heading', { name: 'Day 30: here’s your look back' })
  tickBox()
  fireEvent.click(screen.getByRole('button', { name: 'Approve Day 30' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Keep going' }))
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([60]))
  view.rerender(<MiaCheckpointCard {...props} refreshKey={1} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Look at Day 60' }))
  await screen.findByRole('heading', { name: 'Day 60: here’s your look back' })
  fireEvent.click(screen.getByLabelText('I checked the dates, savings, goal and any gaps shown above.'))
  fireEvent.click(screen.getByRole('button', { name: 'Approve Day 60' }))
  await screen.findByRole('heading', { name: 'Biba! Day 60 is done.' })
  const calls = vi.mocked(mutateDaily).mock.calls
  const keysFor = (action: string) => calls.filter(call => call[0] === action).map(call => call[2])
  expect(keysFor('checkpoint_stage')).toHaveLength(2)
  expect(new Set([...keysFor('checkpoint_stage'), ...keysFor('checkpoint_approve')]).size, 'four different keys').toBe(4)
})

it('Day 60 starts with the box unchecked even when Day 30 left it checked', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([30]))
  vi.mocked(mutateDaily).mockImplementation(stageEverything())
  const props = { actor, cohortId: 2, onDone: vi.fn(), onOpenCheckpoints: vi.fn() }
  const view = render(<MiaCheckpointCard {...props} refreshKey={0} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Look at Day 30' }))
  await screen.findByRole('heading', { name: 'Day 30: here’s your look back' })
  tickBox()
  // The next milestone arrives while the Day 30 review is still open (another window approved Day 30).
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([60]))
  view.rerender(<MiaCheckpointCard {...props} refreshKey={1} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Look at Day 60' }))
  await screen.findByRole('heading', { name: 'Day 60: here’s your look back' })
  expect((screen.getByLabelText('I checked the dates, savings, goal and any gaps shown above.') as HTMLInputElement).checked).toBe(false)
  expect((screen.getByRole('button', { name: 'Approve Day 60' }) as HTMLButtonElement).disabled).toBe(true)
})

it('a dropped connection while preparing keeps the same request, shows check and try again, and never leaves her stuck', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([30]))
  vi.mocked(mutateDaily).mockRejectedValueOnce(new TypeError('Failed to fetch')).mockImplementation(stageEverything())
  vi.mocked(fetchDailyRequestStatus).mockResolvedValue({ ...envelope, state: 'not_found' } as never)
  render(<MiaCheckpointCard actor={actor} cohortId={2} onDone={vi.fn()} onOpenCheckpoints={vi.fn()} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Look at Day 30' }))
  await screen.findByText(/I’m not sure that went through/)
  expect(screen.getByRole('alert')).toBeTruthy()
  const check = screen.getByRole('button', { name: 'Check if it saved' })
  fireEvent.click(check)
  await waitFor(() => expect(fetchDailyRequestStatus).toHaveBeenCalledWith('checkpoint_stage', expect.any(String)))
  fireEvent.click(await screen.findByRole('button', { name: 'Try again' }))
  await screen.findByRole('heading', { name: 'Day 30: here’s your look back' })
  const stages = vi.mocked(mutateDaily).mock.calls.filter(call => call[0] === 'checkpoint_stage')
  expect(stages).toHaveLength(2)
  expect(stages[1][2], 'the retry is the same request').toBe(stages[0][2])
  expect(screen.queryByText(/I’m not sure that went through/)).toBeNull()
})

it('a dropped connection while approving offers the same recovery, and Try again finishes without a second save', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([30]))
  vi.mocked(mutateDaily).mockImplementation((async (action: string) => {
    if (action === 'checkpoint_stage') return { ...envelope, record: draft(30) }
    if (vi.mocked(mutateDaily).mock.calls.filter(call => call[0] === 'checkpoint_approve').length === 1) throw new TypeError('Failed to fetch')
    return { ...envelope, record: { id: 5 } }
  }) as never)
  render(<MiaCheckpointCard actor={actor} cohortId={2} onDone={vi.fn()} onOpenCheckpoints={vi.fn()} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Look at Day 30' }))
  await screen.findByRole('heading', { name: 'Day 30: here’s your look back' })
  tickBox()
  fireEvent.click(screen.getByRole('button', { name: 'Approve Day 30' }))
  await screen.findByText(/I’m not sure that went through/)
  expect(screen.getByRole('button', { name: 'Check if it saved' })).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
  await screen.findByRole('heading', { name: 'Biba! Day 30 is done.' })
  const approvals = vi.mocked(mutateDaily).mock.calls.filter(call => call[0] === 'checkpoint_approve')
  expect(approvals).toHaveLength(2)
  expect(approvals[1][2]).toBe(approvals[0][2])
})

it('an out-of-date preview offers a fresh look with new request keys, and Open in Checkpoints', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([30]))
  let approvals = 0
  vi.mocked(mutateDaily).mockImplementation((async (action: string) => {
    if (action === 'checkpoint_stage') return { ...envelope, record: draft(30, approvals ? { reported_cents: 20_000 } : {}) }
    approvals += 1
    throw new ApiRequestError('The private daily record changed. Review the current versions before saving. Nothing changed.', { status: 409 })
  }) as never)
  const open = vi.fn()
  render(<MiaCheckpointCard actor={actor} cohortId={2} onDone={vi.fn()} onOpenCheckpoints={open} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Look at Day 30' }))
  await screen.findByRole('heading', { name: 'Day 30: here’s your look back' })
  tickBox()
  fireEvent.click(screen.getByRole('button', { name: 'Approve Day 30' }))
  await screen.findByRole('alert')
  const openButton = await screen.findByRole('button', { name: 'Open in Checkpoints' })
  expect(screen.queryByRole('button', { name: 'Approve Day 30' }), 'the stale draft cannot be approved again').toBeNull()
  fireEvent.click(openButton)
  expect(open).toHaveBeenCalledOnce()
  fireEvent.click(screen.getByRole('button', { name: 'Look again' }))
  await screen.findByText('$200.00')
  expect(screen.queryByText('$125.00')).toBeNull()
  expect((screen.getByLabelText('I checked the dates, savings, goal and any gaps shown above.') as HTMLInputElement).checked, 'she checks the new numbers herself').toBe(false)
  const stages = vi.mocked(mutateDaily).mock.calls.filter(call => call[0] === 'checkpoint_stage')
  expect(stages[1][2], 'a new preview is a new request').not.toBe(stages[0][2])
})

it('a Try again that comes back out of date puts the card straight into the stale state', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([30]))
  let approvals = 0
  vi.mocked(mutateDaily).mockImplementation((async (action: string) => {
    if (action === 'checkpoint_stage') return { ...envelope, record: draft(30) }
    approvals += 1
    if (approvals === 1) throw new TypeError('Failed to fetch')
    throw new ApiRequestError('The private daily record changed. Review the current versions before saving. Nothing changed.', { status: 409 })
  }) as never)
  const open = vi.fn()
  render(<MiaCheckpointCard actor={actor} cohortId={2} onDone={vi.fn()} onOpenCheckpoints={open} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Look at Day 30' }))
  await screen.findByRole('heading', { name: 'Day 30: here’s your look back' })
  tickBox()
  fireEvent.click(screen.getByRole('button', { name: 'Approve Day 30' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Try again' }))
  const lookAgainButton = await screen.findByRole('button', { name: 'Look again' })
  expect(screen.queryByRole('button', { name: 'Approve Day 30' }), 'the stale preview cannot be approved without another rejected tap').toBeNull()
  expect(screen.queryByRole('button', { name: 'Try again' })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Open in Checkpoints' }))
  expect(open).toHaveBeenCalledOnce()
  expect(approvals, 'one lost request and one retry, nothing else').toBe(2)
  fireEvent.click(lookAgainButton)
  await screen.findByRole('heading', { name: 'Day 30: here’s your look back' })
})

it('a Try again for the preview that is refused for good starts clean instead of reusing the refused request', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([30]))
  vi.mocked(mutateDaily).mockRejectedValueOnce(new TypeError('Failed to fetch')).mockRejectedValueOnce(new ApiRequestError('Not available right now.', { status: 422 })).mockImplementation(stageEverything())
  render(<MiaCheckpointCard actor={actor} cohortId={2} onDone={vi.fn()} onOpenCheckpoints={vi.fn()} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Look at Day 30' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Try again' }))
  await screen.findByRole('alert')
  expect(screen.queryByRole('button', { name: 'Try again' })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Look at Day 30' }))
  await screen.findByRole('heading', { name: 'Day 30: here’s your look back' })
  const stages = vi.mocked(mutateDaily).mock.calls.filter(call => call[0] === 'checkpoint_stage')
  expect(stages).toHaveLength(3)
  expect(stages[2][2], 'the refused request is not sent again').not.toBe(stages[1][2])
})

it('Check if it saved shows the preview when the lost request had been staged', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([30]))
  vi.mocked(mutateDaily).mockRejectedValueOnce(new TypeError('Failed to fetch'))
  vi.mocked(fetchDailyRequestStatus).mockResolvedValue({ ...envelope, state: 'committed', record: draft(30), replayed: true } as never)
  render(<MiaCheckpointCard actor={actor} cohortId={2} onDone={vi.fn()} onOpenCheckpoints={vi.fn()} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Look at Day 30' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Check if it saved' }))
  await screen.findByRole('heading', { name: 'Day 30: here’s your look back' })
  expect(screen.getByText('$125.00')).toBeTruthy()
  expect(screen.queryByText(/I’m not sure that went through/)).toBeNull()
  expect(vi.mocked(mutateDaily).mock.calls.filter(call => call[0] === 'checkpoint_stage'), 'the look back was not asked for twice').toHaveLength(1)
  expect((screen.getByRole('button', { name: 'Approve Day 30' }) as HTMLButtonElement).disabled, 'she still has to check the box').toBe(true)
})

it('Check if it saved completes the review when the lost request had been the approval', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([30]))
  vi.mocked(mutateDaily).mockImplementation((async (action: string) => {
    if (action === 'checkpoint_stage') return { ...envelope, record: draft(30) }
    throw new TypeError('Failed to fetch')
  }) as never)
  vi.mocked(fetchDailyRequestStatus).mockResolvedValue({ ...envelope, state: 'committed', record: { id: 5 }, replayed: true } as never)
  const onDone = vi.fn()
  render(<MiaCheckpointCard actor={actor} cohortId={2} onDone={onDone} onOpenCheckpoints={vi.fn()} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Look at Day 30' }))
  await screen.findByRole('heading', { name: 'Day 30: here’s your look back' })
  tickBox()
  fireEvent.click(screen.getByRole('button', { name: 'Approve Day 30' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Check if it saved' }))
  await screen.findByRole('heading', { name: 'Biba! Day 30 is done.' })
  expect(screen.queryByRole('button', { name: 'Approve Day 30' })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Keep going' }))
  expect(onDone).toHaveBeenCalledOnce()
  expect(vi.mocked(mutateDaily).mock.calls.filter(call => call[0] === 'checkpoint_approve'), 'checking never sends the approval again').toHaveLength(1)
})

it('a failed first load says so and offers Try again, instead of looking like nothing is due', async () => {
  vi.mocked(fetchSavingsChallenge).mockRejectedValueOnce(new TypeError('Failed to fetch')).mockResolvedValue(challenge([30]))
  render(<MiaCheckpointCard actor={actor} cohortId={2} onDone={vi.fn()} onOpenCheckpoints={vi.fn()} />)
  const alert = await screen.findByRole('alert')
  expect(alert.textContent).toContain('couldn’t check whether a review is due')
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
  await screen.findByRole('heading', { name: 'Day 30 is ready to look back on' })
  expect(screen.queryByRole('alert')).toBeNull()
})

it('a Day 30 already approved elsewhere does not hide Day 60 when it becomes due', async () => {
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([30]))
  vi.mocked(fetchDailyPage).mockResolvedValue({ ...envelope, records: [{ milestone_day: 30, current_version: { id: 1 }, current_version_id: 1, lock_version: 1 }], next_cursor: null } as never)
  const onDone = vi.fn()
  const props = { actor, cohortId: 2, onDone, onOpenCheckpoints: vi.fn() }
  const view = render(<MiaCheckpointCard {...props} refreshKey={0} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Look at Day 30' }))
  await waitFor(() => expect(onDone).toHaveBeenCalledOnce())
  expect(view.container.textContent, 'Day 30 is finished, so nothing is offered for it').toBe('')
  vi.mocked(fetchSavingsChallenge).mockResolvedValue(challenge([60]))
  vi.mocked(fetchDailyPage).mockResolvedValue({ ...envelope, records: [], next_cursor: null } as never)
  view.rerender(<MiaCheckpointCard {...props} refreshKey={1} />)
  await screen.findByRole('heading', { name: 'Day 60 is ready to look back on' })
})
