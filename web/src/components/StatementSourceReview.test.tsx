// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fetchDocumentSourceReview, type TransactionDraft } from '../api'
import { sourceReviewFixture } from '../../e2e/sourceReviewFixtures'
import type { SourceReview } from '../lib/sourceReview'
import { StatementSourceReview } from './StatementSourceReview'
vi.mock('../api', () => ({ fetchDocumentSourceReview: vi.fn() }))
const fetchReview = vi.mocked(fetchDocumentSourceReview)
function mount() { return render(<StatementSourceReview importId={1203} revisionId={88} refreshKey="first" renderExpenseDraft={(draft) => <p>Expense editor {draft.id}</p>} />) }
afterEach(() => cleanup())
beforeEach(() => { fetchReview.mockReset(); fetchReview.mockImplementation(async (_id, _revision, page, filter) => sourceReviewFixture(page, filter)) })

describe('bounded source accounting review', () => {
  it('renders PDF coverage when spreadsheet details are unknown', async () => {
    const data = sourceReviewFixture()
    data.revision.reconciliation.sheet_coverage = { processed: null, expected: null }
    fetchReview.mockResolvedValueOnce(data)
    mount()
    await screen.findByText(/137 source rows/)
    fireEvent.click(screen.getByText('Account balances, period & extraction coverage'))
    expect(screen.getByText(/0 processed \/ unknown expected/)).toBeTruthy()
  })

  it('shows server-wide coverage independently of the bounded row page and filter', async () => {
    mount()
    await screen.findByText(/137 source rows/)
    expect(screen.getAllByRole('listitem')).toHaveLength(50)
    expect(screen.queryByText('Fictional entry 51')).toBeNull()
    fireEvent.click(screen.getByText('Account balances, period & extraction coverage'))
    expect(screen.getByText(/Incomplete page coverage/)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Next rows' }))
    await screen.findByText('Fictional entry 51')
    expect(screen.queryByText('Fictional entry 1')).toBeNull()
    fireEvent.change(screen.getByRole('combobox', { name: 'Filter statement rows' }), { target: { value: 'unresolved' } })
    await screen.findByText('Fictional entry 131')
    expect(screen.getAllByRole('listitem')).toHaveLength(7)
    expect(screen.getByText(/137 source rows/)).toBeTruthy()
    expect(fetchReview).toHaveBeenLastCalledWith(1203, 88, 1, 'unresolved', expect.any(AbortSignal))
  })
  it('keeps unknown totals during loading and prevents late page responses from replacing a newer filter', async () => {
    let finish!: (data: SourceReview) => void
    fetchReview.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve }))
    mount()
    expect(screen.getByText(/Totals are unavailable/)).toBeTruthy()
    fireEvent.change(screen.getByRole('combobox', { name: 'Filter statement rows' }), { target: { value: 'unresolved' } })
    await screen.findByText('Fictional entry 131')
    finish(sourceReviewFixture())
    await waitFor(() => expect(screen.queryByText('Fictional entry 1')).toBeNull())
    expect(screen.getAllByRole('listitem')).toHaveLength(7)
  })
  it('fails closed on revision mismatch and retries without showing stale rows', async () => {
    const wrong = sourceReviewFixture(); wrong.revision.id = 99
    fetchReview.mockResolvedValueOnce(wrong)
    mount()
    await screen.findByRole('alert')
    expect(screen.queryAllByRole('listitem')).toHaveLength(0)
    fireEvent.click(screen.getByRole('button', { name: 'Retry statement page' }))
    await screen.findByText('Fictional entry 1')
    fetchReview.mockRejectedValueOnce(new Error('Revision changed. Refresh the import.'))
    fireEvent.click(screen.getByRole('button', { name: 'Next rows' }))
    await screen.findByText('Revision changed. Refresh the import.')
    expect(screen.queryAllByRole('listitem')).toHaveLength(0)
  })
  it('opens only one row detail and only eligible linked expenses get an editor', async () => {
    const data = sourceReviewFixture()
    const draft = { id: 777 } as TransactionDraft
    data.events[0].transaction_draft = draft
    data.events[3].transaction_draft = draft
    fetchReview.mockResolvedValue(data)
    mount()
    await screen.findByText('Fictional entry 1')
    fireEvent.click(screen.getByRole('button', { name: 'Inspect source row 1' }))
    expect(screen.queryByText('Expense editor 777')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Inspect source row 4 & expense review' }))
    expect(screen.getByText('Expense editor 777')).toBeTruthy()
    expect(screen.queryByText('Synthetic source description 1')).toBeNull()
    expect(screen.getAllByText(/Original source review: unreviewed/)).toHaveLength(1)
  })
})

it('renders real PDF nullable sheet coverage without treating it as an error', async () => {
  const data = sourceReviewFixture(); data.revision.reconciliation.sheet_coverage = { expected: null, processed: null }; fetchReview.mockResolvedValue(data)
  mount(); await screen.findByText(/137 source rows/); fireEvent.click(screen.getByText('Account balances, period & extraction coverage'))
  expect(screen.getByText(/0 processed \/ unknown expected/)).toBeTruthy()
})


it('omits paging actions when all matching rows fit on one page', async () => {
  const data = sourceReviewFixture()
  data.events = data.events.slice(0, 1)
  data.counts.all = 1
  data.pagination = { ...data.pagination, total_count: 1, total_pages: 1, has_next: false }
  fetchReview.mockResolvedValue(data)
  mount()
  await screen.findByText('Fictional entry 1')
  expect(screen.queryByRole('navigation', { name: 'Statement row pagination' })).toBeNull()
  expect(screen.getByRole('combobox', { name: 'Filter statement rows' })).toBeTruthy()
})
