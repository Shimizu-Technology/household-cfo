// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, fetchDailyContext, fetchDailyRequestStatus, mutateDaily } from '../api'
import type { DailyContext, DailyDay, DailyInput } from '../lib/dailyChallenge'
import { clearDailyCards, dailyCardNeedsAttention, registerDailyCard, restoreDailyCards } from '../lib/dailyCheckIn'
import { saveDailyRecovery, setDailyExpectedUser } from '../lib/dailyRecovery'
import type { DailyReportIntake } from '../lib/savingsChallenge'
import { baselineScope } from '../test/baselineFixtures'
import { dailyContext, dailyDraft, dailyVersion } from '../test/dailyFixtures'
import { MiaDailyPrompt, MiaDailyReportCard } from './MiaDailyCheckIn'

vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), fetchDailyContext: vi.fn(), mutateDaily: vi.fn(), fetchDailyRequestStatus: vi.fn() }))

const today = '2026-10-21'
function contextFor(date: string, day: Partial<DailyDay> = {}): DailyContext {
  return { ...structuredClone(dailyContext), calendar: { ...dailyContext.calendar, local_today: today, starts_on: '2026-10-01', ends_on: '2026-12-29', phase: 'active', day: 21 }, day: { ...dailyContext.day!, local_on: date, ...day } }
}
const report: DailyReportIntake = { kind: 'daily_report', local_on: today, purchases: [{ amount_cents: 800, merchant: 'Shell', purchased_on: today }, { amount_cents: 2000, merchant: 'Payless', purchased_on: '2026-10-20' }], no_spend: false, feelings: null, counted: false, approval_state: 'unreviewed_input' }
const todayOnly: DailyReportIntake = { ...report, purchases: [report.purchases[0], { ...report.purchases[1], purchased_on: today }] }
const calls = () => vi.mocked(mutateDaily).mock.calls.map(([action, input, key]) => ({ action, input: input as DailyInput, key }))
const actions = () => calls().map((call) => call.action)
let failures: { action: string; merchant?: string; status: number; times: number }[] = []
let days: Record<string, Partial<DailyDay>> = {}
let nonceCount = 0

function renderCard(value: DailyReportIntake = report, nonce = `card-${++nonceCount}`) {
  const handlers = { onSaved: vi.fn(), onEditInToday: vi.fn(), onDismiss: vi.fn() }
  const view = render(<MiaDailyReportCard nonce={nonce} report={value} scope={baselineScope} {...handlers} />)
  return { card: screen.getByRole('region', { name: 'Your check-in' }), nonce, view, ...handlers }
}
async function ready(card: HTMLElement, name = /^Save/) {
  await waitFor(() => expect((within(card).getByRole('button', { name }) as HTMLButtonElement).disabled).toBe(false))
}

afterEach(cleanup)
beforeEach(() => {
  vi.clearAllMocks(); failures = []; days = {}
  sessionStorage.clear(); setDailyExpectedUser(null); setDailyExpectedUser(baselineScope.user_id)
  vi.mocked(fetchDailyContext).mockImplementation(async (date?: string) => contextFor(date ?? today, days[date ?? today]))
  vi.mocked(fetchDailyRequestStatus).mockResolvedValue({ actor_scope: baselineScope, state: 'unknown', can_retry: true })
  let draftId = 300
  vi.mocked(mutateDaily).mockImplementation(async (action, input) => {
    const failure = failures.find((item) => item.action === action && item.times > 0 && (!item.merchant || item.merchant === input.merchant))
    if (failure) { failure.times -= 1; throw new ApiRequestError(failure.status === 422 ? 'Use a date within the personal challenge window' : 'Service unavailable', { status: failure.status }) }
    if (action === 'purchase_stage') {
      draftId += 1
      return { actor_scope: baselineScope, record: { ...dailyDraft, id: draftId, savings_daily_purchase_id: draftId - 100, amount_cents: input.amount_cents as number, merchant: input.merchant as string, purchased_on: input.purchased_on as string }, replayed: false }
    }
    return { actor_scope: baselineScope, record: action === 'purchase_approve' ? dailyVersion : { id: 1 }, replayed: false }
  })
})

describe('Mia daily report card', () => {
  it('lists every purchase with plain days and saves them all with one tap, then moves focus to the result', async () => {
    const { card, onSaved } = renderCard()
    expect(within(card).getByText('Check these, then save')).toBeTruthy()
    expect(within(card).getByText('Today')).toBeTruthy()
    expect(within(card).getByText('Yesterday')).toBeTruthy()
    expect((within(card).getByLabelText('Amount for Shell') as HTMLInputElement).value).toBe('8.00')
    expect(card.textContent).not.toMatch(/\d{4}-\d{2}-\d{2}/)
    expect(within(card).getByRole('status').textContent).toBe('')
    expect(mutateDaily).not.toHaveBeenCalled()
    await ready(card)
    fireEvent.click(within(card).getByRole('button', { name: 'Save' }))
    const heading = await within(card).findByRole('heading', { name: 'Saved' })
    await waitFor(() => expect(document.activeElement).toBe(heading))
    expect(actions()).toEqual(['purchase_stage', 'purchase_approve', 'purchase_stage', 'purchase_approve', 'check_in_save', 'check_in_save'])
    expect(calls()[0].input).toEqual({ amount_cents: 800, merchant: 'Shell', purchased_on: today, link_kind: 'manual_new', expected_version_id: null, expected_head_lock_version: 0 })
    expect(calls()[1].input).toMatchObject({ draft_id: 301, accepted: true })
    expect(new Set(calls().map((call) => call.key)).size).toBe(6)
    expect(within(card).queryByRole('button', { name: /^Save/ })).toBeNull()
    expect(onSaved).toHaveBeenCalled()
  })

  it('saves edits and removals exactly as shown, needs a place, and links row errors', async () => {
    const { card } = renderCard({ ...report, purchases: [{ amount_cents: 1200, merchant: '', purchased_on: today }, { amount_cents: 500, merchant: 'Kmart', purchased_on: today }, { amount_cents: 300, merchant: 'Ross', purchased_on: today }] })
    await ready(card)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    const note = within(card).getByText('Add where you spent this.')
    expect(within(card).getByLabelText('Place for purchase 1').getAttribute('aria-describedby')).toBe(note.id)
    expect(mutateDaily).not.toHaveBeenCalled()
    fireEvent.change(within(card).getByLabelText('Place for purchase 1'), { target: { value: 'Kings' } })
    fireEvent.change(within(card).getByLabelText('Amount for Kings'), { target: { value: '12.50' } })
    fireEvent.click(within(card).getByRole('button', { name: 'Remove Kmart' }))
    await waitFor(() => expect(document.activeElement?.getAttribute('aria-label')).toBe('Amount for Ross'))
    fireEvent.click(within(card).getByRole('button', { name: 'Remove Ross' }))
    await waitFor(() => expect(document.activeElement?.getAttribute('aria-label')).toBe('Amount for Kings'))
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByRole('heading', { name: 'Saved to today' })
    expect(calls().filter((call) => call.action === 'purchase_stage').map((call) => [call.input.amount_cents, call.input.merchant])).toEqual([[1250, 'Kings']])
  })

  it('reports partial failure plainly, keeps the card for a new message, and retries only what did not save', async () => {
    failures = [{ action: 'purchase_stage', merchant: 'Payless', status: 422, times: 1 }]
    const { card, nonce } = renderCard(todayOnly)
    await ready(card)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByText('Saved 1 of 2. Payless didn’t save — try again.')
    expect(within(card).getByText('This one didn’t save. Try again.')).toBeTruthy()
    expect(dailyCardNeedsAttention(nonce)).toBe(true)
    vi.mocked(mutateDaily).mockClear()
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByRole('heading', { name: 'Saved to today' })
    expect(calls().filter((call) => call.action.startsWith('purchase')).map((call) => [call.action, call.input.merchant ?? call.input.draft_id])).toEqual([['purchase_stage', 'Payless'], ['purchase_approve', 302]])
    expect(dailyCardNeedsAttention(nonce)).toBe(false)
  })

  it('locks a purchase whose approval was not confirmed and replays the same request instead of saving it again', async () => {
    failures = [{ action: 'purchase_approve', status: 503, times: 1 }]
    const { card } = renderCard({ ...report, purchases: [report.purchases[0]] })
    await ready(card)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByText('Checking… Tap Save to confirm.')
    expect(within(card).getByRole('status').textContent).toContain('We couldn’t confirm Shell saved')
    expect((within(card).getByLabelText('Amount for Shell') as HTMLInputElement).disabled).toBe(true)
    expect((within(card).getByRole('button', { name: 'Remove Shell' }) as HTMLButtonElement).disabled).toBe(true)
    expect((within(card).getByRole('button', { name: 'Not right' }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByRole('heading', { name: 'Saved to today' })
    const approvals = calls().filter((call) => call.action === 'purchase_approve')
    expect(calls().filter((call) => call.action === 'purchase_stage')).toHaveLength(1)
    expect(approvals).toHaveLength(2)
    expect(approvals[1].key).toBe(approvals[0].key)
  })

  it.each([400, 409, 422])('stages afresh after approval refusal %s instead of retrying a stale draft', async (status) => {
    failures = [{ action: 'purchase_approve', status, times: 1 }]
    const { card } = renderCard({ ...report, purchases: [report.purchases[0]] })
    await ready(card)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByText('This one didn’t save. Try again.')
    expect((within(card).getByLabelText('Amount for Shell') as HTMLInputElement).disabled).toBe(false)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByRole('heading', { name: 'Saved to today' })
    expect(actions().filter((action) => action.startsWith('purchase'))).toEqual(['purchase_stage', 'purchase_approve', 'purchase_stage', 'purchase_approve'])
    const stages = calls().filter((call) => call.action === 'purchase_stage')
    expect(stages[1].input).toEqual(stages[0].input)
    expect(stages[1].key).not.toBe(stages[0].key)
  })

  it('never re-stages an edited purchase whose staging result is unknown', async () => {
    failures = [{ action: 'purchase_stage', status: 503, times: 1 }]
    const { card } = renderCard({ ...report, purchases: [report.purchases[0]] })
    await ready(card)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByText('Checking… Tap Save to confirm.')
    expect((within(card).getByLabelText('Place for Shell') as HTMLInputElement).disabled).toBe(true)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByRole('heading', { name: 'Saved to today' })
    const stages = calls().filter((call) => call.action === 'purchase_stage')
    expect(stages).toHaveLength(2)
    expect(stages[1]).toEqual(stages[0])
  })

  it('after a reload mid-save, checks the interrupted approval by its key before Save and never saves it twice', async () => {
    const scope = 'reload:901:77:none'
    const draft = { ...dailyDraft, id: 401, savings_daily_purchase_id: 301, merchant: 'Payless', amount_cents: 2000, purchased_on: today }
    sessionStorage.setItem(`household-cfo:mia-daily-cards:v1:${scope}`, JSON.stringify([{ nonce: 'reload-card', report: todayOnly, state: {
      rows: [{ id: 0, amount: '8.00', merchant: 'Shell', purchased_on: today, status: 'saved', purchaseId: 300 }, { id: 1, amount: '20.00', merchant: 'Payless', purchased_on: today, status: 'saving', draft }],
      feelingThen: 'rushed', feelingNow: '', keys: { 'approve:1:x': 'approve-key' }, phase: 'saving', message: null, switchedToSpending: [], checkedIn: [], noSpendSaved: false,
      unconfirmed: { action: 'purchase_approve', input: { draft_id: 401 }, key: 'approve-key', rowId: 1 } } }]))
    let resolveStatus!: (value: unknown) => void
    vi.mocked(fetchDailyRequestStatus).mockReturnValue(new Promise((done) => { resolveStatus = done }) as never)
    const [entry] = restoreDailyCards(scope)
    registerDailyCard(entry)
    const { card } = renderCard(todayOnly, entry.nonce)
    expect(within(card).getByText('Checking… Tap Save to confirm.')).toBeTruthy()
    await waitFor(() => expect(fetchDailyRequestStatus).toHaveBeenCalledWith('purchase_approve', 'approve-key'))
    expect((within(card).getByRole('button', { name: 'Save to today' }) as HTMLButtonElement).disabled).toBe(true)
    await act(async () => { resolveStatus({ actor_scope: baselineScope, state: 'committed', record: dailyVersion, replayed: true }) })
    await within(card).findByText(/\$20\.00/)
    await ready(card)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByRole('heading', { name: 'Saved to today' })
    expect(actions()).toEqual(['check_in_save', 'reflection_save', 'reflection_save'])
  })

  it.each(['in_flight', 'error'])('keeps new writes blocked after a restored lookup is %s, with a working recheck', async (lookup) => {
    failures = [{ action: 'purchase_approve', status: 503, times: 1 }]
    const first = renderCard({ ...report, purchases: [report.purchases[0]] })
    await ready(first.card)
    fireEvent.click(within(first.card).getByRole('button', { name: 'Save to today' }))
    await within(first.card).findByText('Checking… Tap Save to confirm.')
    first.view.unmount()
    if (lookup === 'error') vi.mocked(fetchDailyRequestStatus).mockRejectedValueOnce(new Error('offline'))
    else vi.mocked(fetchDailyRequestStatus).mockResolvedValueOnce({ actor_scope: baselineScope, state: 'in_flight' })
    const again = renderCard({ ...report, purchases: [report.purchases[0]] }, first.nonce)
    const check = await within(again.card).findByRole('button', { name: 'Check last save' })
    expect((within(again.card).getByRole('button', { name: 'Save to today' }) as HTMLButtonElement).disabled).toBe(true)
    const count = calls().length
    vi.mocked(fetchDailyRequestStatus).mockResolvedValueOnce({ actor_scope: baselineScope, state: 'committed', record: dailyVersion, replayed: true })
    // "Check last save" stays disabled until the automatic lookup settles.
    await waitFor(() => expect((check as HTMLButtonElement).disabled).toBe(false))
    fireEvent.click(check)
    await within(again.card).findByRole('heading', { name: 'Almost done' })
    await ready(again.card)
    expect(calls()).toHaveLength(count)
    fireEvent.click(within(again.card).getByRole('button', { name: 'Save to today' }))
    await within(again.card).findByRole('heading', { name: 'Saved to today' })
    expect(actions().filter((action) => action === 'purchase_approve')).toHaveLength(1)
  })

  it.each(['check_in_save', 'reflection_save'])('reconciles a committed %s after leaving and returning, without another write for it', async (action) => {
    failures = [{ action, status: 503, times: 1 }]
    const value = { ...report, purchases: [report.purchases[0]], feelings: { when_spent: 'rushed', now: null } }
    const first = renderCard(value)
    await ready(first.card)
    fireEvent.click(within(first.card).getByRole('button', { name: 'Save to today' }))
    await within(first.card).findByText('We couldn’t confirm the last save. Tap Save to check — it won’t save twice.')
    expect(dailyCardNeedsAttention(first.nonce)).toBe(true)
    first.view.unmount()
    vi.mocked(fetchDailyRequestStatus).mockResolvedValueOnce({ actor_scope: baselineScope, state: 'committed', record: { id: 1 }, replayed: true })
    const again = renderCard(value, first.nonce)
    await ready(again.card)
    fireEvent.click(within(again.card).getByRole('button', { name: 'Save to today' }))
    await within(again.card).findByRole('heading', { name: 'Saved to today' })
    expect(actions().filter((value) => value === action)).toHaveLength(1)
  })

  it('keeps a failed check-in unfinished and offers a retry without saving purchases again', async () => {
    failures = [{ action: 'check_in_save', status: 422, times: 1 }]
    const { card, nonce } = renderCard({ ...report, purchases: [report.purchases[0]] })
    await ready(card)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByText('Your purchases are saved. The check-in didn’t save — tap Save to finish it.')
    expect(within(card).queryByRole('heading', { name: 'Saved to today' })).toBeNull()
    expect(dailyCardNeedsAttention(nonce)).toBe(true)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByRole('heading', { name: 'Saved to today' })
    expect(actions().filter((value) => value === 'purchase_approve')).toHaveLength(1)
  })

  it('restores progress after leaving Ask Mia and coming back, and a saved card cannot be saved again', async () => {
    failures = [{ action: 'purchase_approve', status: 503, times: 1 }]
    const first = renderCard({ ...report, purchases: [report.purchases[0]] })
    await ready(first.card)
    fireEvent.click(within(first.card).getByRole('button', { name: 'Save to today' }))
    await within(first.card).findByText('Checking… Tap Save to confirm.')
    first.view.unmount()
    const again = renderCard({ ...report, purchases: [report.purchases[0]] }, first.nonce)
    expect(within(again.card).getByText('Checking… Tap Save to confirm.')).toBeTruthy()
    await ready(again.card)
    fireEvent.click(within(again.card).getByRole('button', { name: 'Save to today' }))
    await within(again.card).findByRole('heading', { name: 'Saved to today' })
    again.view.unmount()
    const third = renderCard({ ...report, purchases: [report.purchases[0]] }, first.nonce)
    expect(within(third.card).getByRole('heading', { name: 'Saved to today' })).toBeTruthy()
    expect(within(third.card).queryByRole('button', { name: /^Save/ })).toBeNull()
    expect(calls().filter((call) => call.action === 'purchase_stage')).toHaveLength(1)
    const approvals = calls().filter((call) => call.action === 'purchase_approve')
    expect(new Set(approvals.map((call) => call.key)).size).toBe(1)
  })

  it('stops the remaining save when a scope change clears the card during approval', async () => {
    const original = vi.mocked(mutateDaily).getMockImplementation()!
    let finishApproval!: () => void
    vi.mocked(mutateDaily).mockImplementation((action, input, key) => action === 'purchase_approve'
      ? new Promise((resolve) => { finishApproval = () => resolve({ actor_scope: baselineScope, record: dailyVersion, replayed: false }) })
      : original(action, input, key))
    const value = { ...report, purchases: [report.purchases[0]], feelings: { when_spent: 'rushed', now: null } }
    const first = renderCard(value)
    registerDailyCard({ scope: 'old-program', report: value, nonce: first.nonce })
    await ready(first.card)
    fireEvent.click(within(first.card).getByRole('button', { name: 'Save to today' }))
    await waitFor(() => expect(actions()).toEqual(['purchase_stage', 'purchase_approve']))
    first.view.unmount()
    clearDailyCards('old-program')
    await act(async () => { finishApproval(); await Promise.resolve() })
    expect(actions()).toEqual(['purchase_stage', 'purchase_approve'])
    expect(first.onSaved).not.toHaveBeenCalled()
  })

  it('waits for an earlier unconfirmed daily save from elsewhere before sending anything', async () => {
    const { card } = renderCard({ ...report, purchases: [report.purchases[0]] })
    await ready(card)
    act(() => { saveDailyRecovery({ scope: { ...baselineScope, enrollment_id: 100 }, action: 'check_in_save', key: 'today-form-key', input: {}, working: false, error: null }) })
    expect(await within(card).findByRole('button', { name: 'Check the earlier save first' })).toBeTruthy()
    expect((within(card).getByRole('button', { name: 'Save to today' }) as HTMLButtonElement).disabled).toBe(true)
    expect(within(card).getByRole('status').textContent).toContain('An earlier daily save needs checking first')
    expect(mutateDaily).not.toHaveBeenCalled()
  })

  it('saves optional feelings separately for each saved purchase', async () => {
    const { card } = renderCard({ ...report, purchases: [report.purchases[0]], feelings: { when_spent: 'rushed', now: null } })
    expect((within(card).getByLabelText('How did you feel when you spent?') as HTMLInputElement).value).toBe('rushed')
    fireEvent.change(within(card).getByLabelText('How do you feel now?'), { target: { value: 'fine' } })
    await ready(card)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByRole('heading', { name: 'Saved to today' })
    const reflection = calls().find((call) => call.action === 'reflection_save')!
    expect(reflection.input).toEqual({ purchase_id: 201, expected_version_id: null, expected_head_lock_version: 0, feeling_then: 'rushed', feeling_now: 'fine' })
  })

  it('keeps feelings tucked away when none were mentioned', () => {
    const { card } = renderCard()
    expect(within(card).getByText('Add how you felt (optional)')).toBeTruthy()
  })

  it('records an explicit no-spend day, unless a purchase is already saved for it', async () => {
    const noSpend: DailyReportIntake = { ...report, purchases: [], no_spend: true }
    const first = renderCard(noSpend)
    expect(within(first.card).getByText('No spending today')).toBeTruthy()
    expect(first.card.textContent).not.toMatch(/feel/i)
    await ready(first.card)
    fireEvent.click(within(first.card).getByRole('button', { name: 'Save to today' }))
    await within(first.card).findByRole('heading', { name: 'Saved to today' })
    expect(calls()).toEqual([{ action: 'check_in_save', input: { local_on: today, spending_state: 'no_spend', accepted: true, expected_version_id: null, expected_head_lock_version: 0, reason: '' }, key: expect.any(String) }])
    cleanup(); vi.mocked(mutateDaily).mockClear()
    days[today] = { approved_purchase_count: 1, reported_spend_cents: 800 }
    const second = renderCard(noSpend)
    await within(second.card).findByText('You already saved a purchase for this day, so it can’t be a no-spend day.')
    expect((within(second.card).getByRole('button', { name: 'Save to today' }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('changes a no-spend day to spending only once its purchase is staged, right before approval', async () => {
    days[today] = { spending_state: 'no_spend', check_in_id: 700, check_in_version_id: 701, check_in_lock_version: 1, reported_spend_cents: 0 }
    const { card } = renderCard({ ...report, purchases: [report.purchases[0]] })
    await within(card).findByText('You saved this day as no spending. Saving a purchase changes it to a spending day.')
    await ready(card)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByRole('heading', { name: 'Saved to today' })
    expect(actions()).toEqual(['purchase_stage', 'check_in_save', 'purchase_approve'])
    expect(calls()[1]).toMatchObject({ input: { spending_state: 'spending', expected_version_id: 701, reason: 'Added a purchase in a Mia check-in' } })
  })

  it('says plainly when a no-spend day was changed but its purchase did not save', async () => {
    days[today] = { spending_state: 'no_spend', check_in_id: 700, check_in_version_id: 701, check_in_lock_version: 1, reported_spend_cents: 0 }
    failures = [{ action: 'purchase_approve', status: 409, times: 1 }]
    const { card } = renderCard({ ...report, purchases: [report.purchases[0]] })
    await ready(card)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByText(/Nothing was saved yet\..*This day now shows as a spending day\./)
  })

  it('hands one purchase to Today and keeps the rest in the card, without saving', async () => {
    const { card, onEditInToday } = renderCard(todayOnly)
    fireEvent.click(within(card).getByRole('button', { name: 'Edit in Today' }))
    expect(onEditInToday).toHaveBeenCalledWith({ kind: 'purchase', amount_cents: 800, effective_on: today, merchant: 'Shell', approval_state: 'unreviewed_input', counted: false }, 1)
    expect(within(card).getByRole('status').textContent).toBe('Moved Shell to Today. Payless is still here to save.')
    expect(within(card).queryByLabelText('Amount for Shell')).toBeNull()
    expect(within(card).getByLabelText('Amount for Payless')).toBeTruthy()
    fireEvent.click(within(card).getByRole('button', { name: 'Edit in Today' }))
    expect(onEditInToday).toHaveBeenLastCalledWith(expect.objectContaining({ merchant: 'Payless' }), 0)
    expect(mutateDaily).not.toHaveBeenCalled()
  })

  it('dismisses without saving', () => {
    const { card, onDismiss } = renderCard()
    fireEvent.click(within(card).getByRole('button', { name: 'Not right' }))
    expect(onDismiss).toHaveBeenCalled()
    expect(mutateDaily).not.toHaveBeenCalled()
  })
})

describe('Mia daily prompt', () => {
  it('asks how today went with quick replies', () => {
    const onNoSpend = vi.fn(), onSpent = vi.fn()
    render(<MiaDailyPrompt assistantName="Mia" assistantInitial="M" disabled={false} onNoSpend={onNoSpend} onSpent={onSpent} />)
    expect(screen.getByText(/How was today\? Tell me what you spent and where/)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'No spending today' }))
    fireEvent.click(screen.getByRole('button', { name: 'I spent money' }))
    expect(onNoSpend).toHaveBeenCalledOnce(); expect(onSpent).toHaveBeenCalledOnce()
    expect(screen.queryByText(/You checked in/)).toBeNull()
  })
})
