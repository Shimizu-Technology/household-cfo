// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ReactElement } from 'react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import * as api from '../api'
import type { CohortExperienceDraft, MethodChallenge, StoredMethodSettings } from '../api'
import { MethodSettingsEditor } from '../components/MethodSettingsEditor'
import { MiaChallengeGoal } from '../components/MiaChallengeGoal'
import { MiaJoinCard } from '../components/MiaJoinCard'
import { SavingsChallengeHome } from '../components/SavingsChallengeHome'
import { ChallengeTimeline } from '../components/ChallengeTimeline'
import { savingsFixture } from '../test/savingsFixtures'
import { savingsStatus } from './coachDailyWords'
import type { CoachDailyPerson } from './coachChallengeApi'
import { challengeCheckpointDays, defaultMethod, methodChanges, methodOf, methodProblems } from './methodSettings'
import { toolChanges, type CoachSettingsReview } from './coachSettingsReview'
import { countedUnderText } from './coachChallengeApi'
import { calendarCheckpoints, challengeRules, savingsFundingChoices, type SavingsChallenge } from './savingsChallenge'

vi.mock('../contexts/brandContextValue', () => ({ useBrand: () => ({ assistantName: 'Mia' }) }))
vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), fetchSavingsChallenge: vi.fn(), fetchSavingsPage: vi.fn(), enrollSavingsChallenge: vi.fn(), updateChallengeChatCard: vi.fn() }))

const short: MethodChallenge = { length_days: 60, checkpoints: 'thirds', suggested_goal_cents: 30_000, counts: 'savings_and_debt' }

// A participant who joined a 60-day program: Day 20, 40 and 60, a $300 suggestion, debt payments count.
function shortChallenge(): SavingsChallenge {
  const fixture = savingsFixture()
  return {
    ...fixture,
    enrollment: { ...fixture.enrollment!, ends_on: '2026-11-29', challenge_length_days: 60, checkpoint_days: [20, 40, 60], suggested_goal_cents: 30_000, goal_counts: 'savings_and_debt' },
    calendar: { ...fixture.calendar!, ends_on: '2026-11-29', length_days: 60, checkpoint_days: [20, 40, 60], checkpoints: { 20: '2026-10-20', 40: '2026-11-09', 60: '2026-11-29' }, suggested_goal_cents: 30_000, goal_counts: 'savings_and_debt' },
    suggested_target_cents: 30_000, extra_debt_payment_cents: 4_000, extra_debt_payment_count: 1,
  }
}

beforeEach(() => { vi.resetAllMocks(); vi.mocked(api.fetchSavingsPage).mockResolvedValue({ records: [], next_cursor: null }) })
afterEach(cleanup)

it('reads a saved method without challenge rules as 90 days in thirds, $500 and savings only', () => {
  const stored: StoredMethodSettings = { ...defaultMethod }
  delete stored.challenge
  const draft = { schema_version: 5, experience_mode: 'savings_challenge', optional_modules: {}, method: stored } as unknown as CohortExperienceDraft
  expect(methodOf(draft).challenge).toEqual({ length_days: 90, checkpoints: 'thirds', suggested_goal_cents: 50_000, counts: 'savings' })
  expect(challengeCheckpointDays(defaultMethod.challenge)).toEqual([30, 60, 90])
  expect(challengeCheckpointDays(short)).toEqual([20, 40, 60])
  expect(challengeCheckpointDays({ ...short, length_days: 100 })).toEqual([33, 67, 100])
  expect(challengeRules(null)).toEqual({ length_days: 90, checkpoint_days: [30, 60, 90], suggested_goal_cents: 50_000, goal_counts: 'savings' })
})

it('checks a coach’s challenge values the way the API does', () => {
  const problems = (challenge: Partial<MethodChallenge>) => methodProblems({ ...defaultMethod, challenge: { ...short, ...challenge } })
  expect(problems({})).toEqual([])
  expect(problems({ length_days: 20 })).toEqual(['Set the challenge to 30–180 days.'])
  expect(problems({ checkpoints: [15, 45] })).toEqual(['Use 1 to 6 check-in days in order, ending on day 60.'])
  expect(problems({ checkpoints: [45, 15, 60] })).toEqual(['Use 1 to 6 check-in days in order, ending on day 60.'])
  expect(problems({ checkpoints: [15, 45, 60] })).toEqual([])
  expect(problems({ suggested_goal_cents: 5_000 })).toEqual(['Suggest a goal in whole dollars from $100 to $5,000.'])
})

it('names each challenge change in the Go live review', () => {
  expect(methodChanges(defaultMethod, defaultMethod)).toEqual([])
  expect(methodChanges(defaultMethod, { ...defaultMethod, challenge: short })).toEqual([
    'Method: challenge is 60 days with check-ins on day 20, 40, 60 (was 90 days, day 30, 60, 90).',
    'Method: suggested challenge goal is $300 (was $500). People can still choose their own.',
    'Method: extra debt payments now count toward the challenge goal. People already in keep their rule.',
  ])
  expect(methodChanges(defaultMethod, { ...defaultMethod, challenge: { ...defaultMethod.challenge, checkpoints: [15, 45, 90] } })).toEqual([
    'Method: challenge is 90 days with check-ins on day 15, 45, 90 (was 90 days, day 30, 60, 90).',
  ])
})

it('warns at Go live that people already in keep their days when the schedule changes', () => {
  const draft = (challenge: MethodChallenge) => ({ schema_version: 5, experience_mode: 'savings_challenge', optional_modules: {}, method: { ...defaultMethod, challenge } }) as unknown as CohortExperienceDraft
  const item = (running: boolean, challenge: MethodChallenge) => ({ configuration: { draft: draft(challenge), published_version: null }, preview: { modules: [], module_order: [], challenge_running: running } }) as unknown as CoachSettingsReview['tools'][number]
  const warning = 'People already in the challenge keep their days; reports will include both schedules.'
  expect(toolChanges(item(true, short), draft(defaultMethod.challenge))).toContain(warning)
  expect(toolChanges(item(false, short), draft(defaultMethod.challenge))).not.toContain(warning)
  // A new goal alone keeps everyone on one schedule.
  expect(toolChanges(item(true, { ...defaultMethod.challenge, suggested_goal_cents: 100_000 }), draft(defaultMethod.challenge))).not.toContain(warning)
})

it('says what at target counted in a sponsor report', () => {
  expect(countedUnderText(['savings'])).toBe('At target here means new money set aside reached the suggested goal.')
  expect(countedUnderText(['savings_and_debt'])).toMatch(/plus extra payments people reported on a card or loan beyond the minimum, so it doesn’t always mean money saved/)
  expect(countedUnderText(['savings', 'savings_and_debt'])).toMatch(/For people who joined when extra debt payments counted/)
})

it('shows another draft’s check-in days without a remount', () => {
  const days = (checkpoints: number[]) => ({ ...defaultMethod, challenge: { ...short, checkpoints } })
  // A parent that keeps the draft, like the tools editor does.
  const ui = (method: ReturnType<typeof days>): ReactElement => <MethodSettingsEditor method={method} disabled={false} onChange={next => view.rerender(ui(next as ReturnType<typeof days>))} />
  const view = render(ui(days([15, 45, 60])))
  const field = () => screen.getByRole('textbox', { name: /Check-in days/ }) as HTMLInputElement
  expect(field().value).toBe('15, 45, 60')
  // What she is typing stays as typed.
  fireEvent.change(field(), { target: { value: '15, ' } })
  expect(field().value).toBe('15, ')
  // Another draft (a different group, or a reset) shows its own days.
  view.rerender(ui(days([10, 30, 60])))
  expect(field().value).toBe('10, 30, 60')
})

it('lets a coach set the length, check-in days, suggested goal and what counts', async () => {
  const user = userEvent.setup()
  const onChange = vi.fn()
  const { rerender } = render(<MethodSettingsEditor method={defaultMethod} disabled={false} onChange={onChange} />)
  const challenge = screen.getByRole('group', { name: 'Savings challenge' })
  expect((within(challenge).getByRole('spinbutton', { name: /Runs for/ }) as HTMLInputElement).value).toBe('90')
  expect((within(challenge).getByRole('spinbutton', { name: /Suggested goal/ }) as HTMLInputElement).value).toBe('500')
  const checkIns = screen.getByRole('group', { name: 'Challenge check-ins' })
  expect(within(checkIns).getByRole('radio', { name: /Every third of the challenge Day 30, 60 and 90/ })).toHaveProperty('checked', true)
  fireEvent.change(within(challenge).getByRole('spinbutton', { name: /Runs for/ }), { target: { value: '60' } })
  expect(onChange).toHaveBeenLastCalledWith({ ...defaultMethod, challenge: { ...defaultMethod.challenge, length_days: 60 } })

  rerender(<MethodSettingsEditor method={{ ...defaultMethod, challenge: { ...defaultMethod.challenge, length_days: 60 } }} disabled={false} onChange={onChange} />)
  expect(within(checkIns).getByText('Day 20, 40 and 60')).toBeTruthy()
  await user.click(within(checkIns).getByRole('radio', { name: /Choose the days/ }))
  expect(onChange).toHaveBeenLastCalledWith({ ...defaultMethod, challenge: { ...defaultMethod.challenge, length_days: 60, checkpoints: [20, 40, 60] } })

  const counts = screen.getByRole('group', { name: 'What counts toward the goal' })
  expect(within(counts).getByRole('radio', { name: /New money set aside/ })).toHaveProperty('checked', true)
  await user.click(within(counts).getByRole('radio', { name: /New money and extra debt payments/ }))
  expect(onChange.mock.lastCall?.[0].challenge.counts).toBe('savings_and_debt')
})

it('shows the default challenge: Day 30, 60 and 90 of 90, an extra debt payment tracked separately', async () => {
  vi.mocked(api.fetchSavingsChallenge).mockResolvedValue(savingsFixture())
  render(<SavingsChallengeHome onAskMia={vi.fn()} onReviewStatements={vi.fn()} />)
  const calendar = await screen.findByRole('region', { name: 'Personal challenge calendar' })
  expect(within(calendar).getAllByRole('listitem').map(item => item.querySelector('strong')?.textContent)).toEqual(['Day 30', 'Day 60', 'Day 90'])
  expect(screen.getByText(/Day 4 of 90/)).toBeTruthy()
  expect(savingsFundingChoices('savings').find(option => option.value === 'extra_debt_payment')).toEqual({ value: 'extra_debt_payment', label: 'Extra payment on a card or loan — tracked separately', eligible: false })
})

it('shows a 60-day enrollment its own days, length, and that extra debt payments count', async () => {
  vi.mocked(api.fetchSavingsChallenge).mockResolvedValue(shortChallenge())
  render(<SavingsChallengeHome onAskMia={vi.fn()} onReviewStatements={vi.fn()} />)
  const calendar = await screen.findByRole('region', { name: 'Personal challenge calendar' })
  expect(within(calendar).getAllByRole('listitem').map(item => item.querySelector('strong')?.textContent)).toEqual(['Day 20', 'Day 40', 'Day 60'])
  expect(screen.getByText(/Day 4 of 60 · next check-in Day 20/)).toBeTruthy()
  expect(screen.getByText('Includes $40.00 in extra debt payments.')).toBeTruthy()
  expect((screen.getByLabelText('Target in US dollars') as HTMLInputElement).value).toBe('300.00')
  expect(screen.getByText('$300 is the suggested target. You can pick a smaller amount, or decide later.')).toBeTruthy()
  const source = screen.getByRole('combobox', { name: 'Where did this money come from?' })
  expect(within(source).getByRole('option', { name: 'Extra payment on a card or loan, beyond the minimum' })).toBeTruthy()
  expect(calendarCheckpoints(shortChallenge().calendar!)).toEqual([{ day: 20, date: '2026-10-20' }, { day: 40, date: '2026-11-09' }, { day: 60, date: '2026-11-29' }])
})

it('offers a new joiner the program’s length, check-in days, goal and rule', async () => {
  const fixture = savingsFixture(false)
  vi.mocked(api.fetchSavingsChallenge).mockResolvedValue({ ...fixture, suggested_target_cents: 30_000, offer: { ...fixture.offer!, personal_ends_on: '2026-12-02', challenge_length_days: 60, checkpoint_days: [20, 40, 60], suggested_goal_cents: 30_000, goal_counts: 'savings_and_debt' } })
  render(<MiaJoinCard onJoined={vi.fn()} onDone={vi.fn()} />)
  await screen.findByRole('heading', { name: 'Join the 60-day savings challenge' })
  expect(screen.getByText(/Your 60 days: Sun, Oct 4 – Wed, Dec 2/)).toBeTruthy()
  expect(screen.getByText(/Check-ins on Day 20, 40 and 60\. New money you set aside counts toward your goal, and so do extra payments/)).toBeTruthy()
  cleanup()
  render(<SavingsChallengeHome onAskMia={vi.fn()} onReviewStatements={vi.fn()} />)
  await screen.findByText('Join the 60-day savings challenge')
  expect(screen.getByText(/A \$300 cushion can keep surprises off the card/)).toBeTruthy()
})

it('starts the target at her program’s suggested goal right after she joins on Home', async () => {
  const fixture = savingsFixture(false)
  vi.mocked(api.fetchSavingsChallenge).mockResolvedValue({ ...fixture, suggested_target_cents: 30_000, offer: { ...fixture.offer!, late_start_acceptance_required: false, challenge_length_days: 60, checkpoint_days: [20, 40, 60], suggested_goal_cents: 30_000, goal_counts: 'savings_and_debt' } })
  vi.mocked(api.enrollSavingsChallenge).mockResolvedValue({ record: {} as never, replayed: false, challenge: shortChallenge() })
  render(<SavingsChallengeHome onAskMia={vi.fn()} onReviewStatements={vi.fn()} />)
  await screen.findByText('Join the 60-day savings challenge')
  fireEvent.click(screen.getByLabelText('I’ve read this and accept joining the challenge.'))
  fireEvent.click(screen.getByRole('button', { name: 'Accept and join' }))
  await screen.findByRole('region', { name: 'Personal challenge calendar' })
  expect((screen.getByLabelText('Target in US dollars') as HTMLInputElement).value).toBe('300.00')
})

it('says the goal is over her own challenge length in the chat card', async () => {
  render(<MiaChallengeGoal card={{ id: 1, kind: 'goal', status: 'pending', lock_version: 0, enrollment_id: 10, message_id: 20, input: { target_cents: 21_429, expected_plan_version_id: null, weekly_cents: 2_500 }, state: {}, challenge_length_days: 60 }} onDone={vi.fn()} onChangeAmount={vi.fn()} />)
  expect(screen.getByRole('heading', { name: '$214.29 over your 60 days?' })).toBeTruthy()
  expect(screen.getByText(/\$25 a week × 60 days ÷ 7 = \$214\.29/)).toBeTruthy()
  cleanup()
  render(<MiaChallengeGoal card={{ id: 1, kind: 'goal', status: 'pending', lock_version: 0, enrollment_id: 10, message_id: 20, input: { target_cents: 50_000, expected_plan_version_id: null }, state: {} }} onDone={vi.fn()} onChangeAmount={vi.fn()} />)
  expect(screen.getByRole('heading', { name: '$500 over your 90 days?' })).toBeTruthy()
})

it('counts a 60-day timeline and shows each person’s own day to the coach', () => {
  render(<ChallengeTimeline timeline={{ checkpoints_due: [], days: Array.from({ length: 60 }, (_, index) => ({ day: index + 1, local_on: '2026-10-01', check_in: 'unknown' as const, future: true, purchase_count: 0, deposit_cents: null })) }} />)
  expect(screen.getByText('Swipe for all 60 days')).toBeTruthy()
  const row = { enrollment_id: 5, membership_status: 'joined', setup_status: 'plan_reviewed', check_in: { local_on: '2026-10-04', completed: true, availability: 'available' }, challenge: { day: 4, length_days: 60, checkpoint_days: [20, 40, 60] } } as unknown as CoachDailyPerson
  expect(savingsStatus(row)).toBe('Checked in today · Target confirmed · Day 4 of 60')
  expect(savingsStatus({ ...row, challenge: { day: 4, length_days: 90, checkpoint_days: [30, 60, 90] } })).toBe('Checked in today · Target confirmed · Day 4 of 90')
  expect(savingsStatus({ ...row, challenge: { day: 60, length_days: 60, checkpoint_days: [20, 40, 60], finished: true } })).toBe('Checked in today · Target confirmed · Finished')
})
