// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError, fetchDocumentSourceReview, mutateStatementReview, type FinancialDocumentImport } from '../api'
import { participantReviewFixture } from '../../e2e/sourceReviewFixtures'
import { bindStatementReviewActor, setStatementReviewExpectedUser } from '../lib/statementReviewRecovery'
import type { PlanAttention, StatementPlan } from '../lib/statementReview'
import { MiaStatementCards } from './MiaStatementCards'

vi.mock('../api', async (original) => ({ ...await original<typeof import('../api')>(), fetchDocumentSourceReview: vi.fn(), mutateStatementReview: vi.fn() }))
const fetchReview = vi.mocked(fetchDocumentSourceReview)
const mutate = vi.mocked(mutateStatementReview)

const NOW = new Date().toISOString()
const head = { approved_version_id: null, lock_version: 0 }
const SPENDING = { read_count: 18, read_cents: 224965, counted_count: 0, counted_cents: 0 }
const progress = (done: number, total = 27) => ({ total, done, spending: SPENDING, coverage: { question: null, answer: null } })
function statement(id: number, over: Partial<FinancialDocumentImport> = {}): FinancialDocumentImport {
  return {
    id, household_id: 77, document_kind: 'statement', status: 'needs_review', filename: `statement-${id}.pdf`, content_type: 'application/pdf', byte_size: 10, document_date: null,
    period_start_on: '2026-09-01', period_end_on: '2026-09-30', extracted_summary: null, extraction_error: null, processed_at: NOW, applied_at: null, source_deleted_at: null,
    updated_at: NOW, source_available: true, details_included: true, uploaded_by: null, applied_by: null, source_deleted_by: null,
    metadata: { source_accounting_contract_version: 'source_accounting_v1', source_accounting_revision_id: id + 100 }, statement_review: progress(0), items: [], transaction_drafts: [], attempts: [],
    ...over,
  } as FinancialDocumentImport
}
const question = (id: number, merchant: string, kind: PlanAttention['kind'], over: Partial<PlanAttention> = {}): PlanAttention => ({
  event_id: id, kind, event_type: 'purchase', question: kind === 'no_category' ? 'What was this for?' : 'Did this move between your own accounts?', merchant, posted_on: '2026-09-05', signed_amount_cents: -2500,
  category_id: null, category_name: null, expected_head: head,
  answers: kind === 'no_category' ? [{ id: 'edit', label: 'Choose one' }, { id: 'leave_out', label: 'Leave it out' }] : [{ id: 'as_read', label: 'Yes' }, { id: 'edit', label: 'No' }], ...over,
})
// What the server planned for this statement: two lines that look right, and the questions she is asked.
function planWith(attention: PlanAttention[], over: Partial<StatementPlan> = {}): StatementPlan {
  const ready = [4010, 4011].map((id) => ({ event_id: id, event_type: 'purchase' as const, category_id: 10, category_name: 'Groceries', as_before: false, merchant: `Shop ${id}`, signed_amount_cents: -1000, posted_on: '2026-09-02', expected_head: head }))
  return { total: 2 + attention.length, done: 0, spending: SPENDING, ready_event_ids: ready.map((line) => line.event_id), ready, totals_check: 'matches', first_on: '2026-09-01', last_on: '2026-09-30', attention, coverage: { question: null, answer: null }, ...over }
}
function review(plan: StatementPlan) {
  const data = participantReviewFixture()
  data.participant_review!.plan = plan
  return data
}
// The same plan for whichever statement is asked for: the review only checks that it was read for the right upload and revision.
function serve(data: ReturnType<typeof review>) {
  fetchReview.mockImplementation(async (id, revisionId) => {
    const copy = structuredClone(data)
    copy.document_import_id = id; copy.revision.id = revisionId; copy.revision.financial_document_import_id = id
    copy.events.forEach((event) => { event.financial_extraction_revision_id = revisionId })
    return copy
  })
}
const mount = (imports: FinancialDocumentImport[], extra: Partial<Parameters<typeof MiaStatementCards>[0]> = {}) => {
  const props = { onReview: vi.fn(), onRetry: vi.fn(), onSaved: vi.fn(), onAskPatterns: vi.fn(), ...extra }
  render(<MiaStatementCards imports={imports} assistantName="Mia" challenge={false} {...props} />)
  return props
}

afterEach(() => cleanup())
beforeEach(() => {
  sessionStorage.clear(); setStatementReviewExpectedUser(null); setStatementReviewExpectedUser(901); bindStatementReviewActor({ user_id: 901, household_id: 77 })
  fetchReview.mockReset(); mutate.mockReset(); mutate.mockResolvedValue({ result: { approved: 2, left_out: 0, unchanged: 0, complete: false } })
})

describe('Mia’s statement cards in the chat', () => {
  it('shows what was read, the few lines that need her, and approves only the others', async () => {
    serve(review(planWith([
      question(4001, 'Shell', 'no_category'), question(4002, 'Own savings', 'transfer'), question(4003, 'Island Table', 'no_category'),
      question(4004, 'Ross', 'no_category'), question(4005, 'Kmart', 'no_category'),
    ])))
    const props = mount([statement(1)])
    const card = await screen.findByRole('region', { name: /Statement: .*Sep 1–30/ })
    expect(within(card).getByText('I read 18 purchases, $2,249.65.')).toBeTruthy()
    expect(within(card).getByText('2 look right. 5 need a quick look.')).toBeTruthy()
    // Three questions right here; the rest wait on the Statements screen.
    expect(within(card).getAllByRole('listitem')).toHaveLength(3)
    fireEvent.click(within(card).getByRole('button', { name: 'and 2 more — review them' }))
    expect(props.onReview).toHaveBeenCalledWith(1)
    fireEvent.click(within(card).getByRole('button', { name: 'See every line' }))
    expect(props.onReview).toHaveBeenCalledTimes(2)
    fireEvent.click(within(card).getByRole('button', { name: 'Approve the other 2' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledOnce())
    // Exactly the lines that looked right, each with what she was shown, and none of the questions.
    expect(mutate.mock.calls[0][3]).toMatchObject({ expect_ready_ids: [4010, 4011], lines: [{ event_id: 4010, decision: 'as_read', shown: { event_type: 'purchase', category_id: 10 } }, { event_id: 4011 }] })
    expect(JSON.stringify(mutate.mock.calls[0][3])).not.toContain('4001')
  })

  it('answers a question with one tap on the card', async () => {
    serve(review(planWith([question(4002, 'Own savings', 'transfer')])))
    mount([statement(1)])
    fireEvent.click(await screen.findByRole('button', { name: 'Yes: Own savings' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledOnce())
    expect(mutate.mock.calls[0][3]).toMatchObject({ lines: [{ event_id: 4002, decision: 'as_read', shown: { event_type: 'purchase', category_id: null } }] })
  })

  it('moves focus to the next question after one is answered, so a keyboard user does not start over', async () => {
    serve(review(planWith([question(4002, 'Own savings', 'transfer'), question(4003, 'Rent transfer', 'transfer')])))
    mount([statement(1)])
    const answer = await screen.findByRole('button', { name: 'Yes: Own savings' }) as HTMLButtonElement
    await waitFor(() => expect(answer.disabled).toBe(false))
    fireEvent.click(answer)
    serve(review(planWith([question(4003, 'Rent transfer', 'transfer')])))
    await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Yes: Rent transfer' })))
  })

  it('offers her own categories for a suggestion she wants to change, without a sheet', async () => {
    const data = review(planWith([question(4001, 'Island Table', 'suggested_category', { category_id: 10, category_name: 'Groceries', question: 'Was this Groceries?', answers: [{ id: 'keep', label: 'Yes' }, { id: 'edit', label: 'Change' }] })]))
    data.participant_review!.categories = [{ id: 10, name: 'Groceries' }, { id: 11, name: 'Dining out' }]
    serve(data)
    mount([statement(1)])
    fireEvent.click(await screen.findByRole('button', { name: 'Dining out: Island Table' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledOnce())
    expect(mutate.mock.calls[0][3]).toMatchObject({ lines: [{ event_id: 4001, decision: 'edited', edit: { kind: 'spending', merchant: 'Island Table', category_id: 11 } }] })
    expect(screen.queryByRole('dialog')).toBeNull()
  })

  it('asks which kind of account it is first and offers nothing else until she answers', async () => {
    const data = review(planWith([question(4001, 'Shell', 'no_category')]))
    data.accounts = [{ ...data.accounts[0], account_basis: 'unknown' }]
    data.participant_review!.accounts = [{ ...data.participant_review!.accounts[0], approved: null }]
    serve(data)
    mount([statement(1)])
    expect(await screen.findByText(/a bank account or a credit card\?/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: /^Approve/ })).toBeNull()
    expect(screen.queryByRole('list')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Bank account' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledOnce())
    expect(mutate.mock.calls[0][3]).toMatchObject({ accounts: [{ account_basis: 'asset' }] })
  })

  it('saves the missing-lines answer with the approval and keeps the question until it is recorded', async () => {
    const data = review(planWith([], { coverage: { question: 'This file doesn’t show totals, so we couldn’t check it against your statement. Is anything missing?', answer: null, version_id: 9 } }))
    serve(data)
    mount([statement(1)])
    fireEvent.click(await screen.findByRole('button', { name: 'Nothing’s missing' }))
    fireEvent.click(screen.getByRole('button', { name: 'Approve all 2' }))
    await waitFor(() => expect(mutate).toHaveBeenCalledOnce())
    expect(mutate.mock.calls[0][3]).toMatchObject({ coverage_answer: 'nothing_missing', expected_coverage_id: 9 })
  })

  it('tells the participant plainly when the lines changed under her, shows the new count and saves nothing', async () => {
    serve(review(planWith([])))
    mount([statement(1)])
    mutate.mockRejectedValueOnce(new ApiRequestError('This statement changed while you were reviewing it. Nothing was saved. Refresh and try again.', { status: 409 }))
    fireEvent.click(await screen.findByRole('button', { name: 'Approve all 2' }))
    serve(review(planWith([question(4010, 'Shop 4010', 'no_category')], { ready: planWith([]).ready.slice(1) })))
    expect(await screen.findByText('This statement changed, so nothing was approved. This is the latest.')).toBeTruthy()
    expect(await screen.findByRole('button', { name: 'Approve the other one' })).toBeTruthy()
    expect(screen.queryByText(/Refresh and try again/)).toBeNull()
  })

  it('shows a statement she already approved as approved, with what now counts and nothing to do', async () => {
    const done = planWith([], { total: 27, done: 27, ready: [], ready_event_ids: [], spending: { ...SPENDING, counted_count: 16, counted_cents: 209217 } })
    serve(review(done))
    const props = mount([statement(1, { statement_review: progress(27) })], { onAskPatterns: undefined })
    const card = await screen.findByRole('region', { name: /Statement: / })
    expect(within(card).getByText(/^Approved\./)).toBeTruthy()
    expect(within(card).getByText(/16 purchases, \$2,092\.17, now count in your spending\./)).toBeTruthy()
    expect(within(card).queryAllByRole('button')).toHaveLength(0)
    expect(props.onSaved).not.toHaveBeenCalled()
  })

  it('says when patterns will be offered after she answers "Something’s missing"', async () => {
    const done = planWith([], { total: 27, done: 27, ready: [], ready_event_ids: [] })
    serve(review(done))
    const missing = { ...progress(27), coverage: { question: 'Is every line from this statement here?', answer: 'something_missing' as const } }
    const props = mount([statement(1, { statement_review: missing })])
    expect(await screen.findByText('I’ll offer to look for patterns once the missing lines are in.')).toBeTruthy()
    expect(screen.queryByRole('button', { name: /See what Mia notices|Yes, look for patterns/ })).toBeNull()
    expect(props.onAskPatterns).not.toHaveBeenCalled()
  })

  it('does not promise patterns while lines still need her, or when patterns cannot be asked for', async () => {
    serve(review(planWith([question(4010, 'Shop 4010', 'no_category')])))
    mount([statement(1)])
    await screen.findByRole('region', { name: /Statement: / })
    expect(screen.queryByText(/once the missing lines are in/)).toBeNull()
  })

  it('says so when the statement has no lines to approve', async () => {
    serve(review(planWith([], { total: 0, ready: [], ready_event_ids: [] })))
    const props = mount([statement(1)])
    expect(await screen.findByText('I couldn’t find any lines in this statement. Nothing was saved.')).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Open in Statements' }))
    expect(props.onReview).toHaveBeenCalledWith(1)
  })

  it('refreshes the numbers after each answer that is saved, not only when the statement is finished', async () => {
    serve(review(planWith([question(4002, 'Own savings', 'transfer')])))
    const props = mount([statement(1)])
    fireEvent.click(await screen.findByRole('button', { name: 'Yes: Own savings' }))
    await waitFor(() => expect(props.onSaved).toHaveBeenCalledOnce())
  })

  it('says how far the reading is, and what went wrong with a statement that could not be read', async () => {
    const props = mount([
      statement(1, { status: 'processing', statement_review: null, metadata: { extraction_progress: { stage: 'reading', page: 3, page_count: 6 } } }),
      statement(2, { status: 'failed', statement_review: null, extraction_error: 'We could not read pages 4 to 6.' }),
      statement(3, { status: 'failed', statement_review: null, extraction_error: null, source_available: false }),
    ])
    expect(screen.getByText('Reading page 3 of 6…')).toBeTruthy()
    expect(screen.getByText('We could not read pages 4 to 6.')).toBeTruthy()
    const retries = screen.getAllByRole('button', { name: 'Try reading it again' })
    expect(retries).toHaveLength(1)
    fireEvent.click(retries[0])
    expect(props.onRetry).toHaveBeenCalledWith(expect.objectContaining({ id: 2 }))
    expect(screen.getByText('I couldn’t read reliable lines from this file.')).toBeTruthy()
    expect(screen.getByText(/please upload it again/)).toBeTruthy()
    expect(fetchReview).not.toHaveBeenCalled()
  })

  it('waits while Mia is answering, so an approval can never race her reply', async () => {
    serve(review(planWith([question(4001, 'Shell', 'no_category')])))
    mount([statement(1)], { disabled: true })
    const card = await screen.findByRole('region', { name: /Statement: .*Sep 1–30/ })
    expect((within(card).getByRole('button', { name: /Approve the other/ }) as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(within(card).getByRole('button', { name: /Approve the other/ }))
    expect(mutate).not.toHaveBeenCalled()
  })

  it('says so when a file could not be sent for reading again', async () => {
    mount([statement(2, { status: 'failed', statement_review: null, extraction_error: 'We could not read pages 4 to 6.' })], { onRetry: vi.fn().mockResolvedValue(false) })
    fireEvent.click(screen.getByRole('button', { name: 'Try reading it again' }))
    expect(await screen.findByText('I couldn’t start reading it again just now. Try again in a moment, or open it in Statements.')).toBeTruthy()
  })

  it('offers patterns once, after every statement is approved, for the months they cover', async () => {
    const approved = (id: number, start: string, end: string) => statement(id, { period_start_on: start, period_end_on: end, statement_review: progress(27) })
    serve(review(planWith([], { total: 27, done: 27, ready: [], ready_event_ids: [] })))
    const props = mount([approved(1, '2026-08-01', '2026-08-31'), approved(2, '2026-09-01', '2026-09-30'), approved(3, '2026-10-01', '2026-10-31')], { challenge: true } as never)
    expect(await screen.findByText('All 3 statements are approved. Want me to look for patterns in your last 3 months?')).toBeTruthy()
    expect(screen.getAllByText(/^Approved\./)).toHaveLength(3)
    fireEvent.click(screen.getByRole('button', { name: 'Yes, look for patterns' }))
    expect(props.onAskPatterns).toHaveBeenCalledOnce()
    expect(screen.queryByRole('button', { name: 'Yes, look for patterns' })).toBeNull()
  })

  it('does not offer patterns while any statement still needs her, and uses the household wording', async () => {
    serve(review(planWith([question(4001, 'Shell', 'no_category')])))
    mount([statement(1)])
    await screen.findByRole('region', { name: /Statement: / })
    expect(screen.queryByText(/look for patterns/)).toBeNull()
    cleanup()
    serve(review(planWith([], { total: 27, done: 27, ready: [], ready_event_ids: [] })))
    mount([statement(2, { statement_review: progress(27) })])
    expect(await screen.findByText('Want me to look for patterns in this statement?')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'See what Mia notices' })).toBeTruthy()
  })

  it('shows nothing for a participant with no statements', () => {
    mount([])
    expect(screen.queryByRole('region')).toBeNull()
  })
})

it('fix2 final statement answer exposes completion and focuses the inert heading', async () => {
  serve(review(planWith([question(4002, 'Own savings', 'transfer')], { total: 1, ready: [], ready_event_ids: [] })))
  mount([statement(1)])
  const answer = await screen.findByRole('button', { name: 'Yes: Own savings' })
  await waitFor(() => expect((answer as HTMLButtonElement).disabled).toBe(false))
  answer.focus()
  const done = planWith([], { total: 1, done: 1, ready: [], ready_event_ids: [], spending: { read_count: 1, read_cents: 2500, counted_count: 1, counted_cents: 2500 } })
  serve(review(done))
  fireEvent.click(answer)
  await waitFor(() => expect(screen.queryByRole('button', { name: 'Yes: Own savings' })).toBeNull())
  const region = await screen.findByRole('region', { name: /Statement: / })
  const status = within(region).getByRole('status')
  expect(status.textContent).toContain('count')
  expect(status.closest('details')).toBeNull()
  expect(document.activeElement).toBe(within(region).getByRole('heading'))
  expect(document.activeElement?.matches('button, summary')).toBe(false)
})
