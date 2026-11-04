// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, fetchDocumentSourceReview, mutateStatementReview } from '../api'
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
  mutate.mockReset(); mutate.mockResolvedValue({ result: { approved: 0, left_out: 0, unchanged: 0, complete: false } })
})

describe('statement review a participant can finish', () => {
  it('keeps an unsaved category answer and lets her retry it', async () => {
    const data = participantReviewFixture()
    const item = data.participant_review!.plan.attention[0]
    item.kind = 'no_category'; item.question = 'What was this for?'; item.answers = [{ id: 'edit', label: 'Choose one' }]
    fetchReview.mockResolvedValue(data)
    mutate.mockRejectedValueOnce(new ApiRequestError('This part of your program is not available right now.', { status: 403, code: 'savings_challenge_unavailable' }))
    mount()
    const choice = await screen.findByRole('combobox', { name: `Category for ${item.merchant}` }) as HTMLSelectElement
    fireEvent.change(choice, { target: { value: '10' } })
    const retry = await screen.findByRole('button', { name: 'Try saving this answer again' })
    expect(choice.value).toBe('10')
    fireEvent.click(retry)
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(2))
    expect(mutate.mock.calls[1][3]).toEqual(mutate.mock.calls[0][3])
  })
  it('keeps the review and an open answer when the program temporarily cannot save', async () => {
    mutate.mockRejectedValueOnce(new ApiRequestError('This part of your program is not available right now.', { status: 403, code: 'savings_challenge_unavailable' }))
    mount()
    const list = await screen.findByRole('list', { name: 'Lines that need a quick look' })
    fireEvent.click(within(list).getAllByRole('button', { name: /^Fix it: / })[0])
    const sheet = await screen.findByRole('dialog')
    fireEvent.change(within(sheet).getByLabelText('Name'), { target: { value: 'Payless' } })
    fireEvent.change(within(sheet).getByLabelText('Date'), { target: { value: '2026-09-16' } })
    fireEvent.change(within(sheet).getByLabelText('Amount'), { target: { value: '12.5' } })
    fireEvent.change(within(sheet).getByLabelText(/^Category/), { target: { value: '10' } })
    fireEvent.click(within(sheet).getByRole('button', { name: 'Save' }))
    expect((await within(sheet).findByRole('alert')).textContent).toContain('not available right now')
    expect((within(sheet).getByLabelText('Name') as HTMLInputElement).value).toBe('Payless')
    expect(screen.getByRole('heading', { name: '137 lines from Fictional checking, Sep 1–30.' })).toBeTruthy()
  })
  it('opens with one summary line: how many lines, which account, which dates, and how many need a look', async () => {
    mount()
    expect(await screen.findByRole('heading', { name: '137 lines from Fictional checking, Sep 1–30.' })).toBeTruthy()
    expect(screen.getByText('127 look right. 10 need a quick look. We’ll approve them 100 at a time.')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Change' })).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Approve these 100' })).toBeTruthy()
    expect(fetchReview).toHaveBeenCalledWith(1203, 88, 1, 'all', expect.any(AbortSignal))
  })

  it('approves exactly the lines that looked right, in one request that names them', async () => {
    mount()
    fireEvent.click(await screen.findByRole('button', { name: 'Approve these 100' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    const [importId, revisionId, action, input] = mutate.mock.calls[0]
    expect([importId, revisionId, action]).toEqual([1203, 88, 'approve_lines'])
    const sent = input as { expect_ready_ids: number[]; paged?: boolean; lines: Array<{ event_id: number; decision: string; shown?: { event_type: string; category_id: number | null } }> }
    // 127 look right; one request saves one page of 100 and says it is a page.
    expect(sent.paged).toBe(true)
    expect(sent.lines).toHaveLength(100)
    expect(new Set(sent.lines.map((line) => line.decision))).toEqual(new Set(['as_read']))
    // Each line carries the kind and category she was shown, so a category she never saw cannot be saved.
    const shown = new Map(participantReviewFixture().participant_review!.plan.ready.map((line) => [line.event_id, { event_type: line.event_type, category_id: line.category_id }]))
    expect(sent.lines.every((line) => JSON.stringify(line.shown) === JSON.stringify(shown.get(line.event_id)))).toBe(true)
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
    expect(mutate.mock.calls[0][3]).toEqual({ lines: [{ event_id: 4001, decision: 'as_read', shown: { event_type: 'transfer', category_id: null } }] })
  })

  it('says what she was shown when she calls a possible copy a different charge, and says nothing for leaving it out', async () => {
    const data = participantReviewFixture(); const plan = data.participant_review!.plan
    plan.attention = [{ event_id: 4007, kind: 'duplicate', event_type: 'purchase', question: 'Is this the same charge as one you already have?', answers: [{ id: 'leave_out', label: 'Same charge' }, { id: 'different', label: 'Different charge' }],
      merchant: 'Island Table', posted_on: '2026-09-05', signed_amount_cents: -6720, category_id: 31, category_name: 'Dining out' }]
    fetchReview.mockResolvedValue(data)
    mount()
    const item = (await screen.findByRole('list', { name: 'Lines that need a quick look' })).querySelector('li')!
    fireEvent.click(within(item).getByRole('button', { name: 'Different charge: Island Table' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    expect(mutate.mock.calls[0][3]).toEqual({ lines: [{ event_id: 4007, decision: 'different', shown: { event_type: 'purchase', category_id: 31 } }] })
    await waitFor(() => expect((within(item).getByRole('button', { name: 'Same charge: Island Table' }) as HTMLButtonElement).disabled).toBe(false))
    fireEvent.click(within(item).getByRole('button', { name: 'Same charge: Island Table' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(2))
    expect(mutate.mock.calls[1][3]).toEqual({ lines: [{ event_id: 4007, decision: 'leave_out' }] })
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

  it('reopens the account sheet with the type she already approved when the file never said', async () => {
    const data = participantReviewFixture(); data.accounts[0].account_basis = 'unknown'; data.revision.accounts[0].account_basis = 'unknown'
    data.participant_review!.accounts[0].approved!.tracked_account.account_basis = 'liability'
    fetchReview.mockResolvedValue(data)
    mount()
    fireEvent.click(await screen.findByRole('button', { name: 'Change' }))
    const sheet = await screen.findByRole('dialog')
    expect((within(sheet).getByLabelText(/bank account or a credit card|Type/i) as HTMLSelectElement).value).toBe('liability')
  })

  it('says Unknown, not Pending, for an amount that could not be read, in the list as in the questions', async () => {
    mount()
    await screen.findByRole('table')
    fireEvent.click(screen.getByText('See all 137 lines'))
    fireEvent.click(screen.getByRole('button', { name: 'Later lines' }))
    await screen.findByRole('button', { name: 'Fictional entry 51' })
    fireEvent.click(screen.getByRole('button', { name: 'Later lines' }))
    const row = (await screen.findByRole('button', { name: 'Fictional entry 131' })).closest('tr')!
    expect(within(row).getByText('Unknown')).toBeTruthy()
    expect(region().textContent).not.toContain('Pending')
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
    data.participant_review!.accounts[0].approved = null; data.participant_review!.accounts[0].last4 = '1234'
    fetchReview.mockResolvedValue(data)
    mount()
    expect(await screen.findByText('Is Fictional checking ····1234 a bank account or a credit card?')).toBeTruthy()
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

  it('asks one plain question when the statement cannot show nothing is missing, and sends only her answer', async () => {
    const data = participantReviewFixture(); data.participant_review!.plan.coverage = { question: 'Your statement shows 27 lines and we found 26. Is anything missing?', answer: null }
    fetchReview.mockResolvedValue(data)
    mount()
    expect(await screen.findByText('Your statement shows 27 lines and we found 26. Is anything missing?')).toBeTruthy()
    // Approving without answering says nothing about coverage on her behalf.
    fireEvent.click(screen.getByRole('button', { name: 'Approve these 100' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    expect(mutate.mock.calls[0][3]).not.toHaveProperty('coverage_answer')
    await waitFor(() => expect((screen.getByRole('button', { name: 'Nothing’s missing' }) as HTMLButtonElement).disabled).toBe(false))
    // Her answer rides with the next save, as hers. It is only said to be recorded once the server says so.
    fireEvent.click(screen.getByRole('button', { name: 'Something’s missing' }))
    expect(screen.getByRole('button', { name: 'Something’s missing' }).getAttribute('aria-pressed')).toBe('true')
    expect(screen.queryByText(/We’ll keep this statement marked as not finished/)).toBeNull()
    expect(mutate).toHaveBeenCalledTimes(1)
    const list = screen.getByRole('list', { name: 'Lines that need a quick look' })
    fetchReview.mockResolvedValue({ ...data, participant_review: { ...data.participant_review!, plan: { ...data.participant_review!.plan, coverage: { ...data.participant_review!.plan.coverage, answer: 'something_missing' } } } })
    fireEvent.click(within(list).getAllByRole('button', { name: /^Yes: / })[0])
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(2))
    expect(mutate.mock.calls[1][3]).toMatchObject({ coverage_answer: 'something_missing' })
    expect(await screen.findByText(/We’ll keep this statement marked as not finished/)).toBeTruthy()
  })

  it('saves her answer straight away when every line is already saved, and holds the next step until she answers', async () => {
    const data = participantReviewFixture(); const plan = data.participant_review!.plan
    plan.done = 137; plan.ready = []; plan.ready_event_ids = []; plan.attention = []
    fetchReview.mockResolvedValue(data)
    render(<StatementSourceReview importId={1203} revisionId={88} refreshKey="done" next={[{ label: 'See what Mia notices', run: vi.fn() }]} />)
    expect(await screen.findByText('All 137 lines are saved.')).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'See what Mia notices' })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Nothing’s missing' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    expect(mutate.mock.calls[0][3]).toEqual({ lines: [], coverage_answer: 'nothing_missing' })
    // The server has not said it recorded the answer yet, so nothing moves on.
    expect(screen.queryByRole('button', { name: 'See what Mia notices' })).toBeNull()
  })

  it('opens the next step only after the save that records her answer, and keeps her answer with a retry when saving fails', async () => {
    const data = participantReviewFixture(); const plan = data.participant_review!.plan
    plan.done = 137; plan.ready = []; plan.ready_event_ids = []; plan.attention = []
    plan.coverage = { question: 'The totals on your statement don’t add up with the lines we found. Is anything missing?', answer: null }
    fetchReview.mockResolvedValue(data)
    mutate.mockRejectedValueOnce(new ApiRequestError('This source is incomplete', { status: 422 }))
    render(<StatementSourceReview importId={1203} revisionId={88} refreshKey="retry" next={[{ label: 'See what Mia notices', run: vi.fn() }]} />)
    fireEvent.click(await screen.findByRole('button', { name: 'Something’s missing' }))
    expect(await screen.findByText('We couldn’t save your answer yet. Please try again.')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Something’s missing' }).getAttribute('aria-pressed')).toBe('true')
    expect(screen.queryByRole('button', { name: 'See what Mia notices' })).toBeNull()
    fetchReview.mockResolvedValue({ ...data, participant_review: { ...data.participant_review!, plan: { ...plan, coverage: { ...plan.coverage, answer: 'something_missing' } } } })
    fireEvent.click(within(screen.getByText('We couldn’t save your answer yet. Please try again.').closest('div')!).getByRole('button', { name: 'Try again' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(2))
    expect(mutate.mock.calls[1][3]).toEqual({ lines: [], coverage_answer: 'something_missing' })
    expect(await screen.findByRole('button', { name: 'See what Mia notices' })).toBeTruthy()
    expect(screen.queryByText('We couldn’t save your answer yet. Please try again.')).toBeNull()
  })

  it('asks nothing when the statement reconciles', async () => {
    const data = participantReviewFixture(); data.participant_review!.plan.coverage = { question: null, answer: null }; data.participant_review!.plan.totals_check = 'matches'
    fetchReview.mockResolvedValue(data)
    mount()
    await screen.findByRole('heading', { level: 5 })
    expect(screen.queryByRole('button', { name: 'Nothing’s missing' })).toBeNull()
    expect(screen.queryByText(/Is anything missing/)).toBeNull()
  })

  it('opens a line that looks right on the category the list shows for it, and a line that needs a look on the plan’s kind', async () => {
    const data = participantReviewFixture(); const plan = data.participant_review!.plan
    plan.ready[3] = { ...plan.ready[3], category_id: 31, category_name: 'Dining out', as_before: true }
    data.participant_review!.categories = [{ id: 10, name: 'Groceries' }, { id: 31, name: 'Dining out' }]
    fetchReview.mockResolvedValue(data)
    mount()
    await screen.findByText('1 uses a category you chose before: Dining out.')
    fireEvent.click(screen.getByRole('button', { name: `Fictional entry ${plan.ready[3].event_id - 4000 + 1}` }))
    const sheet = await screen.findByRole('dialog')
    expect((within(sheet).getByLabelText('Category') as HTMLSelectElement).value).toBe('31')
  })

  it('shows the category a line will be saved with, including one that comes only from her history', async () => {
    const data = participantReviewFixture(); const plan = data.participant_review!.plan
    plan.ready[3] = { ...plan.ready[3], category_id: 31, category_name: 'Dining out', as_before: true }
    data.participant_review!.categories = [{ id: 10, name: 'Groceries' }, { id: 31, name: 'Dining out' }]
    fetchReview.mockResolvedValue(data)
    mount()
    expect(await screen.findByText('1 uses a category you chose before: Dining out.')).toBeTruthy()
    const row = screen.getByRole('button', { name: `Fictional entry ${plan.ready[3].event_id - 4000 + 1}` }).closest('tr')!
    expect(within(row).getByText('Dining out · as before')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Approve these 100' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    const sent = mutate.mock.calls[0][3] as { lines: Array<{ event_id: number; shown: { category_id: number | null } }> }
    expect(sent.lines.find((line) => line.event_id === plan.ready[3].event_id)?.shown.category_id).toBe(31)
  })

  it('shows a finished statement as saved and offers the next step', async () => {
    const data = participantReviewFixture(); const plan = data.participant_review!.plan
    plan.done = 137; plan.ready_event_ids = []; plan.ready = []; plan.attention = []; plan.coverage = { question: null, answer: null }
    fetchReview.mockResolvedValue(data)
    const snapshot = vi.fn(); const mia = vi.fn()
    render(<StatementSourceReview importId={1203} revisionId={88} refreshKey="done" next={[{ label: 'See what Mia notices', run: mia }, { label: 'Open your spending snapshot', run: snapshot }]} />)
    expect(await screen.findByText('All 137 lines are saved.')).toBeTruthy()
    expect(screen.queryByRole('button', { name: /^Approve/ })).toBeNull()
    // What Mia notices is the main step; the snapshot is quieter.
    expect(screen.getByRole('button', { name: 'See what Mia notices' }).className).toContain('button--primary')
    expect(screen.getByRole('button', { name: 'Open your spending snapshot' }).className).toContain('button--secondary')
    fireEvent.click(screen.getByRole('button', { name: 'See what Mia notices' }))
    expect(mia).toHaveBeenCalled(); expect(snapshot).not.toHaveBeenCalled()
  })

  it('approves a long statement 100 lines at a time, each request naming exactly the lines of its page', async () => {
    const data = participantReviewFixture(); const plan = data.participant_review!.plan
    plan.ready = Array.from({ length: 1_000 }, (_, index) => ({ event_id: 10_000 + index, event_type: 'purchase' as const, category_id: 10, category_name: 'Groceries', as_before: false })); plan.ready_event_ids = plan.ready.map((line) => line.event_id); plan.attention = []; plan.total = 1_000
    fetchReview.mockResolvedValue(data)
    mount()
    expect(await screen.findByText('All 1,000 look right. We’ll approve them 100 at a time.')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Approve these 100' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    const sent = mutate.mock.calls[0][3] as { expect_ready_ids: number[]; paged?: boolean; lines: Array<{ event_id: number; decision: string }> }
    expect(sent.paged).toBe(true)
    expect(sent.lines).toHaveLength(100)
    expect(sent.expect_ready_ids).toEqual(plan.ready_event_ids.slice(0, 100))
    expect(sent.lines.map((line) => line.event_id)).toEqual(sent.expect_ready_ids)
  })

  it('says a long save can take a minute while it saves, then stops saying it', async () => {
    const data = participantReviewFixture(); data.participant_review!.plan.ready = Array.from({ length: 1_000 }, (_, index) => ({ event_id: 10_000 + index, event_type: 'purchase' as const, category_id: 10, category_name: 'Groceries', as_before: false }))
    fetchReview.mockResolvedValue(data)
    let finish: (value: { result: { approved: number; left_out: number; unchanged: number; complete: boolean } }) => void = () => {}
    mutate.mockReturnValueOnce(new Promise((resolve) => { finish = resolve }))
    mount()
    fireEvent.click(await screen.findByRole('button', { name: 'Approve these 100' }))
    expect(await screen.findByText('Saving 100 lines. This can take a minute.')).toBeTruthy()
    finish({ result: { approved: 0, left_out: 0, unchanged: 0, complete: false } })
    await waitFor(() => expect(screen.queryByText('Saving 100 lines. This can take a minute.')).toBeNull())
  })

  it('does not call a statement paged when it fits on one page', async () => {
    const data = participantReviewFixture(); const plan = data.participant_review!.plan
    plan.ready = plan.ready.slice(0, 27); plan.ready_event_ids = plan.ready.map((line) => line.event_id)
    fetchReview.mockResolvedValue(data)
    mount()
    fireEvent.click(await screen.findByRole('button', { name: 'Approve the other 27' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    expect(mutate.mock.calls[0][3]).not.toHaveProperty('paged')
  })

  it('asks "Still Dining out?" with Yes and Change, and Yes confirms that category without changing what kind of line it is', async () => {
    const data = participantReviewFixture(); const plan = data.participant_review!.plan
    plan.attention = [{ event_id: 4005, kind: 'still_category', event_type: 'fee', question: 'Still Dining out?', answers: [{ id: 'keep', label: 'Yes' }, { id: 'edit', label: 'Change' }],
      merchant: 'Island Table', posted_on: '2026-09-05', signed_amount_cents: -6720, category_id: 31, category_name: 'Dining out' }]
    data.participant_review!.categories = [{ id: 31, name: 'Dining out' }, { id: 32, name: 'Groceries' }]
    fetchReview.mockResolvedValue(data)
    mount()
    const item = (await screen.findByRole('list', { name: 'Lines that need a quick look' })).querySelector('li')!
    expect(within(item).getByText('Still Dining out?')).toBeTruthy()
    fireEvent.click(within(item).getByRole('button', { name: 'Yes: Island Table' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    expect(mutate.mock.calls[0][3]).toEqual({ lines: [{ event_id: 4005, decision: 'as_read', shown: { event_type: 'fee', category_id: 31 } }] })
    fireEvent.click(within(item).getByRole('button', { name: 'Change: Island Table' }))
    const sheet = await screen.findByRole('dialog')
    expect((within(sheet).getByLabelText('Category') as HTMLSelectElement).value).toBe('31')
  })

  it('never names the account with a system label, and asks about an unnamed account plainly', async () => {
    const data = participantReviewFixture(); data.accounts[0].account_basis = 'unknown'
    data.participant_review!.accounts = [{ ...data.participant_review!.accounts[0], name: null, last4: null, approved: null }]
    fetchReview.mockResolvedValue(data)
    mount()
    expect(await screen.findByRole('heading', { name: '137 lines from your statement, Sep 1–30.' })).toBeTruthy()
    expect(screen.getByText('Is this a bank account or a credit card?')).toBeTruthy()
    expect(region().textContent).not.toMatch(/Spreadsheet account|Statement account|Account 501/)
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
    fireEvent.click(screen.getByRole('button', { name: 'Approve these 100' }))
    await waitFor(() => expect(fetchReview).toHaveBeenCalledTimes(2))
    expect(screen.getByRole('table')).toBeTruthy()
    finish(participantReviewFixture())
  })
})
