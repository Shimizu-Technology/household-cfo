// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { SpendingReport } from '../api'
import { ReviewedTransactionsPanel } from './ReviewedTransactions'

afterEach(cleanup)

function report(overrides: Partial<SpendingReport> = {}): SpendingReport {
  return {
    period_label: 'October 2026',
    start_on: '2026-10-01',
    end_on: '2026-10-31',
    totals: { planned: 500, actual: 65, pending: 0, remaining: 435 },
    categories: [],
    transactions: [
      { id: 31, occurred_on: '2026-10-04', merchant: "McDonald's", amount: 25, source_type: 'manual_ui', categories: ['Dining out'], transaction_draft_id: 220 },
      { id: 32, occurred_on: '2026-10-03', merchant: 'Imported rent', amount: 40, source_type: 'import', categories: ['Rent'], transaction_draft_id: null },
    ],
    pending_drafts: [],
    ignored_drafts: [
      { id: 221, occurred_on: '2026-10-02', merchant: 'Shell', amount: 40, amount_cents: 4000, status: 'ignored', source_type: 'manual_ui', category_id: null, category_name: null },
    ],
    ...overrides,
  }
}

describe('ReviewedTransactionsPanel', () => {
  it('offers Reopen on confirmed rows and Restore on ignored drafts, named for each item', () => {
    const onReopen = vi.fn()
    render(<ReviewedTransactionsPanel report={report()} action={null} onReopen={onReopen} />)

    const confirmed = screen.getByRole('region', { name: 'Confirmed this month' })
    expect(within(confirmed).getAllByRole('button')).toHaveLength(1)
    const reopen = within(confirmed).getByRole('button', { name: "Reopen McDonald's $25.00 on Oct 4" })
    expect(reopen.textContent).toBe('Reopen')
    fireEvent.click(reopen)
    expect(onReopen).toHaveBeenLastCalledWith(expect.objectContaining({ id: 220, status: 'confirmed', merchant: "McDonald's" }))

    const restore = screen.getByRole('button', { name: 'Restore Shell $40.00 on Oct 2' })
    expect(restore.textContent).toBe('Restore')
    fireEvent.click(restore)
    expect(onReopen).toHaveBeenLastCalledWith(expect.objectContaining({ id: 221, status: 'ignored' }))
    expect(screen.getByText(/removes it from this month’s actuals and puts it back in review/)).toBeTruthy()
  })

  it('locks every reversal while another review action is running and shows progress on the active row', () => {
    render(<ReviewedTransactionsPanel report={report()} action="reopen-draft:220" onReopen={vi.fn()} />)
    expect((screen.getByRole('button', { name: "Reopening McDonald's $25.00 on Oct 4" }) as HTMLButtonElement).disabled).toBe(true)
    expect((screen.getByRole('button', { name: 'Restore Shell $40.00 on Oct 2' }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('renders nothing when there is nothing to reverse', () => {
    const { container } = render(<ReviewedTransactionsPanel report={report({ transactions: [], ignored_drafts: [] })} action={null} onReopen={vi.fn()} />)
    expect(container.innerHTML).toBe('')
  })
})
