// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fetchDocumentSourceReview, mutateStatementReview } from '../api'
import { participantReviewFixture, sourceReviewFixture } from '../../e2e/sourceReviewFixtures'
import type { SourceReview } from '../lib/sourceReview'
import { bindStatementReviewActor, setStatementReviewExpectedUser } from '../lib/statementReviewRecovery'
import { StatementSourceReview } from './StatementSourceReview'
vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), fetchDocumentSourceReview: vi.fn(), mutateStatementReview: vi.fn() }))
const fetchReview = vi.mocked(fetchDocumentSourceReview)
const mutate = vi.mocked(mutateStatementReview)
const mount = () => render(<StatementSourceReview importId={1203} revisionId={88} refreshKey="first" />)
const region = () => screen.getByRole('region', { name: 'Statement review' })
afterEach(() => cleanup())
beforeEach(() => {
  sessionStorage.clear(); setStatementReviewExpectedUser(null); setStatementReviewExpectedUser(901); bindStatementReviewActor({ user_id: 901, household_id: 77 })
  fetchReview.mockReset(); fetchReview.mockImplementation(async (_id, _revision, page, filter) => participantReviewFixture(page, filter))
  mutate.mockReset(); mutate.mockResolvedValue({ record: {}, replayed: false })
})

describe('statement review a participant can finish', () => {
  it('opens with one summary line: how many lines, which account, which dates, and how many need a look', async () => {
    mount()
    expect(await screen.findByRole('heading', { name: '137 lines from Fictional checking, Sep 1–30.' })).toBeTruthy()
    expect(screen.getByText('127 look right. 10 need a quick look.')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Change' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Approve the other 127' })).toBeTruthy()
    expect(fetchReview).toHaveBeenCalledWith(1203, 88, 1, 'all', expect.any(AbortSignal))
  })

  it('approves exactly the lines that looked right, in one request that names them', async () => {
    mount()
    fireEvent.click(await screen.findByRole('button', { name: 'Approve the other 127' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    const [importId, revisionId, action, input] = mutate.mock.calls[0]
    expect([importId, revisionId, action]).toEqual([1203, 88, 'approve_lines'])
    const sent = input as { expect_ready_ids: number[]; lines: Array<{ event_id: number; decision: string }> }
    expect(sent.lines).toHaveLength(127)
    expect(new Set(sent.lines.map((line) => line.decision))).toEqual(new Set(['as_read']))
    expect(sent.lines.map((line) => line.event_id)).toEqual(sent.expect_ready_ids)
    // The refund, transfer and card payment are never part of "the rest".
    expect(sent.expect_ready_ids).not.toContain(4000)
    expect(sent.expect_ready_ids).not.toContain(4001)
    expect(sent.expect_ready_ids).not.toContain(4002)
  })

  it('puts the lines that need an answer first, each with one question and its answers', async () => {
    mount()
    const list = await screen.findByRole('list', { name: 'Lines that need a quick look' })
    const items = within(list).getAllByRole('listitem')
    expect(items).toHaveLength(10)
    expect(within(items[0]).getByText('Is this a refund?')).toBeTruthy()
    expect(within(items[0]).getByRole('button', { name: 'Yes: Fictional entry 1' })).toBeTruthy()
    expect(within(items[1]).getByText('Did this move between your own accounts?')).toBeTruthy()
    expect(within(items[3]).getByText('We couldn’t read this line clearly.')).toBeTruthy()
    fireEvent.click(within(items[1]).getByRole('button', { name: 'Yes: Fictional entry 2' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    expect(mutate.mock.calls[0][3]).toEqual({ lines: [{ event_id: 4001, decision: 'as_read' }] })
  })

  it('opens a line in a sheet to fix it and sends the corrected facts', async () => {
    mount()
    const list = await screen.findByRole('list', { name: 'Lines that need a quick look' })
    fireEvent.click(within(list).getAllByRole('button', { name: /^Fix it: / })[0])
    const sheet = await screen.findByRole('dialog')
    expect(within(sheet).getByRole('heading', { name: 'Fictional entry 131' })).toBeTruthy()
    fireEvent.change(within(sheet).getByLabelText('Name'), { target: { value: 'Payless' } })
    fireEvent.change(within(sheet).getByLabelText('Date'), { target: { value: '2026-09-16' } })
    fireEvent.change(within(sheet).getByLabelText('Amount'), { target: { value: '12.5' } })
    fireEvent.change(within(sheet).getByLabelText(/^Category/), { target: { value: '10' } })
    fireEvent.click(within(sheet).getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    expect(mutate.mock.calls[0][3]).toEqual({ lines: [{ event_id: 4130, decision: 'edited', edit: { kind: 'spending', merchant: 'Payless', posted_on: '2026-09-16', amount_cents: 1250, category_id: 10 } }] })
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull())
  })

  it('refuses an amount that is not a number instead of saving it as zero', async () => {
    mount()
    const list = await screen.findByRole('list', { name: 'Lines that need a quick look' })
    fireEvent.click(within(list).getAllByRole('button', { name: /^Fix it: / })[0])
    const sheet = await screen.findByRole('dialog')
    fireEvent.change(within(sheet).getByLabelText('Amount'), { target: { value: 'twelve' } })
    fireEvent.click(within(sheet).getByRole('button', { name: 'Save' }))
    expect((await within(sheet).findByRole('alert')).textContent).toBe('Enter the amount, like 12.50.')
    expect(mutate).not.toHaveBeenCalled()
  })

  it('asks what kind of account it is before anything is saved when the file does not say', async () => {
    const data = participantReviewFixture()
    data.accounts[0].account_basis = 'unknown'; data.revision.accounts[0].account_basis = 'unknown'
    data.participant_review!.accounts[0].approved = null
    fetchReview.mockResolvedValue(data)
    mount()
    expect(await screen.findByText('Is Fictional checking · ••1234 a bank account or a credit card?')).toBeTruthy()
    expect(screen.queryByRole('button', { name: /^Approve the other/ })).toBeNull()
    expect((screen.getAllByRole('button', { name: /^Yes: / })[0] as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(screen.getByRole('button', { name: 'Credit card' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    expect(mutate.mock.calls[0][3]).toEqual({ lines: [], accounts: [{ source_account_id: 501, account_basis: 'liability' }] })
  })

  it('keeps the full list one tap away as a table and opens a line from it', async () => {
    mount()
    const summary = await screen.findByText('See all 137 lines')
    const table = screen.getByRole('table')
    expect(within(table).getAllByRole('columnheader').map((header) => header.textContent)).toEqual(['Line', 'Date', 'Amount', 'Category'])
    expect(within(table).getAllByRole('row')).toHaveLength(51)
    expect(summary.closest('details')?.open).toBe(false)
    fireEvent.click(within(table).getByRole('button', { name: 'Fictional entry 4' }))
    expect(await screen.findByRole('dialog')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Close' }))
    fireEvent.click(screen.getByRole('button', { name: 'Later lines' }))
    await screen.findByRole('button', { name: 'Fictional entry 51' })
    expect(fetchReview).toHaveBeenLastCalledWith(1203, 88, 2, 'all', expect.any(AbortSignal))
  })

  it('says plainly when the totals do not add up, and when the file prints none', async () => {
    const data = participantReviewFixture(); data.participant_review!.plan.totals_check = 'mismatch'
    fetchReview.mockResolvedValue(data)
    const view = mount()
    expect(await screen.findByText(/The totals on this statement don’t add up/)).toBeTruthy()
    view.unmount(); cleanup()
    fetchReview.mockResolvedValue(participantReviewFixture())
    mount()
    expect(await screen.findByText(/This file doesn’t show totals/)).toBeTruthy()
  })

  it('shows a finished statement as saved and offers the next step', async () => {
    const data = participantReviewFixture(); const plan = data.participant_review!.plan
    plan.done = 137; plan.ready_event_ids = []; plan.attention = []
    fetchReview.mockResolvedValue(data)
    const next = vi.fn()
    render(<StatementSourceReview importId={1203} revisionId={88} refreshKey="done" onDone={{ label: 'Open your spending snapshot', run: next }} />)
    expect(await screen.findByText('All 137 lines are saved.')).toBeTruthy()
    expect(screen.queryByRole('button', { name: /^Approve/ })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Open your spending snapshot' }))
    expect(next).toHaveBeenCalled()
  })

  it('uses plain words only', async () => {
    mount()
    await screen.findByRole('heading', { level: 5 })
    fireEvent.click(screen.getByText('See all 137 lines'))
    expect(region().textContent).not.toMatch(/statement line \d|explicit batch|participant review|coverage|source|projection|reconcil|proposal|revision|extraction|unresolved|informational|posted/i)
  })

  it('fails closed on a wrong revision and retries without showing stale lines', async () => {
    const wrong = sourceReviewFixture(); wrong.revision.id = 99
    fetchReview.mockResolvedValueOnce(wrong)
    mount()
    expect((await screen.findByRole('alert')).textContent).toContain('Try again')
    expect(screen.queryByRole('table')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByRole('table')).toBeTruthy()
  })

  it('does not open a review the server sent without a plan', async () => {
    const data = participantReviewFixture(); delete (data.participant_review as { plan?: unknown }).plan
    fetchReview.mockResolvedValueOnce(data as SourceReview)
    mount()
    expect((await screen.findByRole('alert')).textContent).toContain('isn’t available right now')
  })

  it('keeps the summary and questions on screen while another page of lines loads', async () => {
    mount()
    fireEvent.click(await screen.findByText('See all 137 lines'))
    let finish!: (data: SourceReview) => void
    fetchReview.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve }))
    fireEvent.click(screen.getByRole('button', { name: 'Later lines' }))
    expect(await screen.findByText('Loading lines…')).toBeTruthy()
    expect(screen.getByRole('heading', { level: 5 })).toBeTruthy()
    expect(screen.getByRole('list', { name: 'Lines that need a quick look' })).toBeTruthy()
    expect(screen.queryByRole('table')).toBeNull()
    finish(participantReviewFixture(2))
    expect(await screen.findByRole('button', { name: 'Fictional entry 51' })).toBeTruthy()
  })

  it('keeps the lines on screen while a saved answer is read back', async () => {
    mount()
    await screen.findByRole('table')
    let finish!: (data: SourceReview) => void
    fetchReview.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve }))
    fireEvent.click(screen.getByRole('button', { name: 'Approve the other 127' }))
    await waitFor(() => expect(fetchReview).toHaveBeenCalledTimes(2))
    expect(screen.getByRole('table')).toBeTruthy()
    finish(participantReviewFixture())
  })
})
