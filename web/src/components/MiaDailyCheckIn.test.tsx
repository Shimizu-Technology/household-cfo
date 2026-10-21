// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, fetchDailyContext, mutateDaily } from '../api'
import type { DailyContext, DailyDay, DailyInput } from '../lib/dailyChallenge'
import type { DailyReportIntake } from '../lib/savingsChallenge'
import { baselineScope } from '../test/baselineFixtures'
import { dailyContext, dailyDraft, dailyVersion } from '../test/dailyFixtures'
import { MiaDailyPrompt, MiaDailyReportCard } from './MiaDailyCheckIn'

vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), fetchDailyContext: vi.fn(), mutateDaily: vi.fn() }))

const today = '2026-10-21'
function contextFor(date: string, day: Partial<DailyDay> = {}): DailyContext {
  return { ...structuredClone(dailyContext), calendar: { ...dailyContext.calendar, local_today: today, starts_on: '2026-10-01', ends_on: '2026-12-29', phase: 'active', day: 21 }, day: { ...dailyContext.day!, local_on: date, ...day } }
}
const report: DailyReportIntake = { kind: 'daily_report', local_on: today, purchases: [{ amount_cents: 800, merchant: 'Shell', purchased_on: today }, { amount_cents: 2000, merchant: 'Payless', purchased_on: '2026-10-20' }], no_spend: false, feelings: null, counted: false, approval_state: 'unreviewed_input' }
const calls = () => vi.mocked(mutateDaily).mock.calls.map(([action, input, key]) => ({ action, input: input as DailyInput, key }))
let failStageFor: string | null = null
let failApproveOnce = false
let days: Record<string, Partial<DailyDay>> = {}

function renderCard(value: DailyReportIntake = report) {
  const handlers = { onSaved: vi.fn(), onEditInToday: vi.fn(), onDismiss: vi.fn() }
  render(<MiaDailyReportCard report={value} scope={baselineScope} {...handlers} />)
  return { card: screen.getByRole('region', { name: 'Your check-in' }), ...handlers }
}

afterEach(cleanup)
beforeEach(() => {
  vi.clearAllMocks(); failStageFor = null; failApproveOnce = false; days = {}
  vi.mocked(fetchDailyContext).mockImplementation(async (date?: string) => contextFor(date ?? today, days[date ?? today]))
  let draftId = 300
  vi.mocked(mutateDaily).mockImplementation(async (action, input) => {
    if (action === 'purchase_stage') {
      if (failStageFor && input.merchant === failStageFor) throw new ApiRequestError('Use a date within the personal challenge window', { status: 422 })
      draftId += 1
      return { actor_scope: baselineScope, record: { ...dailyDraft, id: draftId, savings_daily_purchase_id: draftId - 100, amount_cents: input.amount_cents as number, merchant: input.merchant as string, purchased_on: input.purchased_on as string }, replayed: false }
    }
    if (action === 'purchase_approve' && failApproveOnce) { failApproveOnce = false; throw new ApiRequestError('Service unavailable', { status: 503 }) }
    return { actor_scope: baselineScope, record: action === 'purchase_approve' ? dailyVersion : { id: 1 }, replayed: false }
  })
})

describe('Mia daily report card', () => {
  it('lists every purchase with plain days and saves them all with one tap', async () => {
    const { card, onSaved } = renderCard()
    expect(within(card).getByText('Check these, then save')).toBeTruthy()
    expect(within(card).getByText('Today')).toBeTruthy()
    expect(within(card).getByText('Yesterday')).toBeTruthy()
    expect((within(card).getByLabelText('Amount for Shell') as HTMLInputElement).value).toBe('8.00')
    expect(card.textContent).not.toMatch(/\d{4}-\d{2}-\d{2}/)
    expect(mutateDaily).not.toHaveBeenCalled()
    await waitFor(() => expect(fetchDailyContext).toHaveBeenCalledTimes(2))
    fireEvent.click(within(card).getByRole('button', { name: 'Save' }))
    await within(card).findByText('Saved')
    expect(calls().map((call) => call.action)).toEqual(['purchase_stage', 'purchase_approve', 'purchase_stage', 'purchase_approve', 'check_in_save', 'check_in_save'])
    expect(calls()[0].input).toEqual({ amount_cents: 800, merchant: 'Shell', purchased_on: today, link_kind: 'manual_new', expected_version_id: null, expected_head_lock_version: 0 })
    expect(calls()[1].input).toMatchObject({ draft_id: 301, accepted: true })
    expect(calls()[4].input).toEqual({ local_on: today, spending_state: 'spending', accepted: true, expected_version_id: null, expected_head_lock_version: 0, reason: '' })
    expect(new Set(calls().map((call) => call.key)).size).toBe(6)
    expect(onSaved).toHaveBeenCalled()
  })

  it('saves edits and removals exactly as shown, and needs a place for each purchase', async () => {
    const { card } = renderCard({ ...report, purchases: [{ amount_cents: 1200, merchant: '', purchased_on: today }, { amount_cents: 500, merchant: 'Kmart', purchased_on: today }] })
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    expect(within(card).getByText('Add where you spent this.')).toBeTruthy()
    expect(mutateDaily).not.toHaveBeenCalled()
    fireEvent.change(within(card).getByLabelText('Place for purchase 1'), { target: { value: 'Kings' } })
    fireEvent.change(within(card).getByLabelText('Amount for Kings'), { target: { value: '12.50' } })
    fireEvent.click(within(card).getByRole('button', { name: 'Remove Kmart' }))
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByText('Saved to today')
    expect(calls().filter((call) => call.action === 'purchase_stage').map((call) => [call.input.amount_cents, call.input.merchant])).toEqual([[1250, 'Kings']])
  })

  it('reports partial failure plainly and retries only what did not save', async () => {
    failStageFor = 'Payless'
    const { card } = renderCard({ ...report, purchases: [report.purchases[0], { ...report.purchases[1], purchased_on: today }] })
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByText('Saved 1 of 2. Payless didn’t save — try again.')
    expect(within(card).getByText('This one didn’t save. Try again.')).toBeTruthy()
    failStageFor = null
    vi.mocked(mutateDaily).mockClear()
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByText('Saved to today')
    expect(calls().filter((call) => call.action.startsWith('purchase')).map((call) => [call.action, call.input.merchant ?? call.input.draft_id])).toEqual([['purchase_stage', 'Payless'], ['purchase_approve', 302]])
  })

  it('retries an interrupted approval with the same request key, never a second purchase', async () => {
    failApproveOnce = true
    const { card } = renderCard({ ...report, purchases: [report.purchases[0]] })
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByText(/Nothing was saved yet/)
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByText('Saved to today')
    const approvals = calls().filter((call) => call.action === 'purchase_approve')
    expect(calls().filter((call) => call.action === 'purchase_stage')).toHaveLength(1)
    expect(approvals).toHaveLength(2)
    expect(approvals[1].key).toBe(approvals[0].key)
  })

  it('saves optional feelings separately for each saved purchase', async () => {
    const { card } = renderCard({ ...report, purchases: [report.purchases[0]], feelings: { when_spent: 'rushed', now: null } })
    expect((within(card).getByLabelText('How did you feel when you spent?') as HTMLInputElement).value).toBe('rushed')
    fireEvent.change(within(card).getByLabelText('How do you feel now?'), { target: { value: 'fine' } })
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByText('Saved to today')
    const reflection = calls().find((call) => call.action === 'reflection_save')!
    expect(reflection.input).toEqual({ purchase_id: 201, expected_version_id: null, expected_head_lock_version: 0, feeling_then: 'rushed', feeling_now: 'fine' })
    expect(reflection.input).not.toHaveProperty('amount_cents')
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
    await waitFor(() => expect(fetchDailyContext).toHaveBeenCalled())
    fireEvent.click(within(first.card).getByRole('button', { name: 'Save to today' }))
    await within(first.card).findByText('Saved to today')
    expect(calls()).toEqual([{ action: 'check_in_save', input: { local_on: today, spending_state: 'no_spend', accepted: true, expected_version_id: null, expected_head_lock_version: 0, reason: '' }, key: expect.any(String) }])
    cleanup(); vi.mocked(mutateDaily).mockClear()
    days[today] = { approved_purchase_count: 1, reported_spend_cents: 800 }
    const second = renderCard(noSpend)
    await within(second.card).findByText('You already saved a purchase for this day, so it can’t be a no-spend day.')
    expect((within(second.card).getByRole('button', { name: 'Save to today' }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('changes a saved no-spend day to spending when the participant saves a purchase on it', async () => {
    days[today] = { spending_state: 'no_spend', check_in_id: 700, check_in_version_id: 701, check_in_lock_version: 1, reported_spend_cents: 0 }
    const { card } = renderCard({ ...report, purchases: [report.purchases[0]] })
    await within(card).findByText('You saved this day as no spending. Saving a purchase changes it to a spending day.')
    fireEvent.click(within(card).getByRole('button', { name: 'Save to today' }))
    await within(card).findByText('Saved to today')
    expect(calls()[0]).toMatchObject({ action: 'check_in_save', input: { spending_state: 'spending', expected_version_id: 701, reason: 'Added a purchase in a Mia check-in' } })
  })

  it('hands the first purchase to Today or dismisses without saving', () => {
    const { card, onEditInToday, onDismiss } = renderCard()
    fireEvent.click(within(card).getByRole('button', { name: 'Edit in Today' }))
    expect(onEditInToday).toHaveBeenCalledWith({ kind: 'purchase', amount_cents: 800, effective_on: today, merchant: 'Shell', approval_state: 'unreviewed_input', counted: false })
    fireEvent.click(within(card).getByRole('button', { name: 'Not right' }))
    expect(onDismiss).toHaveBeenCalled()
    expect(mutateDaily).not.toHaveBeenCalled()
  })
})

describe('Mia daily prompt', () => {
  it('asks how today went with quick replies, and drops no-spend once checked in', () => {
    const onNoSpend = vi.fn(), onSpent = vi.fn()
    const view = render(<MiaDailyPrompt assistantName="Mia" assistantInitial="M" checkedIn={false} disabled={false} onNoSpend={onNoSpend} onSpent={onSpent} />)
    expect(screen.getByText(/How was today\? Tell me what you spent and where/)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'No spending today' }))
    fireEvent.click(screen.getByRole('button', { name: 'I spent money' }))
    expect(onNoSpend).toHaveBeenCalledOnce(); expect(onSpent).toHaveBeenCalledOnce()
    view.rerender(<MiaDailyPrompt assistantName="Mia" assistantInitial="M" checkedIn disabled={false} onNoSpend={onNoSpend} onSpent={onSpent} />)
    expect(screen.queryByRole('button', { name: 'No spending today' })).toBeNull()
  })
})
