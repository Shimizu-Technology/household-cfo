// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { AnnualBudgetPlan, BudgetCategoryRow, SpendingReport, TransactionDraft } from './api'
import { CategoryEditCell, CurrentMonthActivityPanel, ManualTransactionCapture, TransactionDraftReviewStack } from './App'

afterEach(cleanup)

function draft(overrides: Partial<TransactionDraft> = {}): TransactionDraft {
  return {
    id: 220,
    occurred_on: '2026-10-04',
    merchant: "McDonald's",
    amount: 25,
    amount_cents: 2500,
    status: 'pending',
    source_type: 'manual_ui',
    category_id: 7,
    category_name: 'Dining out',
    splits: [],
    matches: [],
    ...overrides,
  }
}

function row(overrides: Partial<BudgetCategoryRow> = {}): BudgetCategoryRow {
  return {
    id: 7,
    name: 'Dining out',
    stack_key: 'discretionary',
    stack_label: 'Discretionary',
    active: true,
    months: Array.from({ length: 12 }, (_, index) => ({ period_id: index + 1, allocation_id: index + 1, planned: 120, actual: index === 9 ? 25 : 0, remaining: 120 })),
    planned_total: 1440,
    actual_total: 25,
    ...overrides,
  }
}

function stackProps(drafts: TransactionDraft[], overrides: Record<string, unknown> = {}) {
  return {
    drafts,
    isRealWorkspace: true,
    action: null,
    onUpdate: vi.fn(),
    onConfirm: vi.fn(),
    onIgnore: vi.fn(),
    onReopen: vi.fn(),
    ...overrides,
  }
}

describe('transaction review cards', () => {
  it('names every repeated card button for its own transaction while keeping the visible text short', () => {
    render(<TransactionDraftReviewStack {...stackProps([draft(), draft({ id: 221, merchant: 'Shell', amount: 40, amount_cents: 4000 })])} />)

    for (const [name, text] of [["Edit McDonald's $25.00 on Oct 4", 'Edit'], ["Confirm McDonald's $25.00 on Oct 4", 'Confirm'], ["Ignore McDonald's $25.00 on Oct 4", 'Ignore'], ['Edit Shell $40.00 on Oct 4', 'Edit'], ['Confirm Shell $40.00 on Oct 4', 'Confirm']]) {
      expect(screen.getByRole('button', { name }).textContent).toBe(text)
    }
    expect(screen.queryByRole('button', { name: 'Edit' })).toBeNull()
  })

  it('names the restore and undo buttons on reviewed cards', () => {
    const onReopen = vi.fn()
    render(<TransactionDraftReviewStack {...stackProps([draft({ status: 'ignored' }), draft({ id: 222, merchant: 'Shell', status: 'confirmed', amount: 40, amount_cents: 4000 })], { onReopen })} />)
    fireEvent.click(screen.getByRole('button', { name: "Restore draft McDonald's $25.00 on Oct 4" }))
    expect(onReopen).toHaveBeenCalledWith(expect.objectContaining({ id: 220, status: 'ignored' }))
    expect(screen.getByRole('button', { name: 'Undo to edit Shell $40.00 on Oct 4' })).toBeTruthy()
  })

  it('does not credit Mia for manual or bank drafts', () => {
    render(<TransactionDraftReviewStack {...stackProps([draft(), draft({ id: 223, source_type: 'plaid', merchant: 'Bank row' })])} />)
    expect(screen.getByRole('heading', { name: 'Transactions to review' })).toBeTruthy()
    expect(screen.queryByText(/Mia drafted/)).toBeNull()
  })

  it('keeps Mia drafted copy when every draft came from Mia chat', () => {
    render(<TransactionDraftReviewStack {...stackProps([draft({ source_type: 'manual_chat' })])} />)
    expect(screen.getByRole('heading', { name: /^\S.* drafted transactions for your approval$/ })).toBeTruthy()
  })

  it('uses a source-neutral category warning on manual and bank rows', () => {
    const uncategorized = { id: 1, budget_category_id: null, category_name: 'Needs category', stack_key: null, stack_label: '', amount: 25, amount_cents: 2500, notes: null, confidence: null, metadata: {} }
    render(<TransactionDraftReviewStack {...stackProps([
      draft({ category_id: null, category_name: null, splits: [uncategorized] }),
      draft({ id: 224, merchant: 'Bank row', source_type: 'plaid', category_id: null, category_name: null, splits: [{ ...uncategorized, id: 2 }] }),
    ])} />)
    expect(screen.queryByText(/could not confidently match/)).toBeNull()
    expect(screen.getAllByText(/^Needs a category\. Choose where it belongs/)).toHaveLength(2)
  })
})

describe('budget ledger reversals', () => {
  const plan = {
    year: 2026,
    months: Array.from({ length: 12 }, (_, index) => {
      const month = String(index + 1).padStart(2, '0')
      const end = new Date(Date.UTC(2026, index + 1, 0)).getUTCDate()
      return { id: index + 1, label: month, starts_on: `2026-${month}-01`, ends_on: `2026-${month}-${end}`, status: 'open' }
    }),
    rows: [row()],
    monthly_income: {},
    monthly_debt_minimums: 0,
    income_sources: [],
    annual_outlook: { typical_monthly_outflow: 0, months: [], upcoming_spikes: [], next_irregular_month: null },
    pending_transaction_drafts: [],
    recent_transactions: [],
  } as unknown as AnnualBudgetPlan
  const report: SpendingReport = {
    period_label: 'October 2026',
    start_on: '2026-10-01',
    end_on: '2026-10-31',
    totals: { planned: 120, actual: 25, pending: 0, remaining: 95 },
    categories: [],
    transactions: [{ id: 31, occurred_on: '2026-10-04', merchant: "McDonald's", amount: 25, source_type: 'manual_ui', categories: ['Dining out'], transaction_draft_id: 220 }],
    pending_drafts: [],
    ignored_drafts: [{ id: 221, occurred_on: '2026-10-02', merchant: 'Shell', amount: 40, amount_cents: 4000, status: 'ignored', source_type: 'manual_ui', category_id: null, category_name: null }],
  }

  it('lets a confirmed ledger row be reopened and an ignored draft be restored', () => {
    const onReopen = vi.fn()
    render(<CurrentMonthActivityPanel plan={plan} currentMonthIndex={9} spendingReport={report} loading={false} error={null} reopen={{ action: null, disabled: false, onReopen }} />)
    const ledgerRow = screen.getByText("McDonald's").closest('.recent-transaction-row') as HTMLElement
    fireEvent.click(within(ledgerRow).getByRole('button', { name: "Reopen McDonald's $25.00 on Oct 4" }))
    expect(onReopen).toHaveBeenLastCalledWith(expect.objectContaining({ id: 220, status: 'confirmed' }))
    fireEvent.click(screen.getByRole('button', { name: 'Restore Shell $40.00 on Oct 2' }))
    expect(onReopen).toHaveBeenLastCalledWith(expect.objectContaining({ id: 221, status: 'ignored' }))
  })

  it('renders a Reopen button for every confirmed manual row and tells repeat purchases apart by date', () => {
    const repeated = { ...report, transactions: [
      { id: 31, occurred_on: '2026-10-04', merchant: 'Pay-Less', amount: 25, source_type: 'manual_ui', categories: ['Groceries'], transaction_draft_id: 220 },
      { id: 32, occurred_on: '2026-10-03', merchant: 'Pay-Less', amount: 25, source_type: 'manual_ui', categories: ['Groceries'], transaction_draft_id: 222 },
      { id: 33, occurred_on: '2026-10-02', merchant: 'Bank import', amount: 9, source_type: 'plaid', categories: ['Fees'], transaction_draft_id: null },
    ] }
    render(<CurrentMonthActivityPanel plan={plan} currentMonthIndex={9} spendingReport={repeated} loading={false} error={null} reopen={{ action: null, disabled: false, onReopen: vi.fn() }} />)
    expect(screen.getAllByRole('button', { name: /^Reopen / }).map((button) => button.getAttribute('aria-label'))).toEqual(['Reopen Pay-Less $25.00 on Oct 4', 'Reopen Pay-Less $25.00 on Oct 3'])
  })

  it('keeps the ledger read-only without reopen controls (demo workspaces)', () => {
    render(<CurrentMonthActivityPanel plan={plan} currentMonthIndex={9} spendingReport={report} loading={false} error={null} />)
    expect(screen.queryByRole('button', { name: /Reopen|Restore/ })).toBeNull()
  })
})

describe('budget table and quick capture', () => {
  it('names the category archive button', () => {
    render(<CategoryEditCell row={row()} draft={{ name: 'Dining out', stack_key: 'discretionary' }} hasPendingDrafts={false} action={null} onChange={vi.fn()} onArchive={vi.fn()} />)
    expect(screen.getByRole('button', { name: 'Archive Dining out' }).textContent).toBe('Archive')
  })

  it('closes the Add transaction panel with Escape and returns focus to its toggle', () => {
    render(<ManualTransactionCapture categories={[row()]} busy={false} onCreate={vi.fn()} />)
    const toggle = screen.getByRole('button', { name: 'Add transaction' })
    fireEvent.click(toggle)
    const merchant = screen.getByRole('textbox', { name: 'Merchant' })
    fireEvent.keyDown(merchant, { key: 'Escape' })
    expect(screen.queryByRole('textbox', { name: 'Merchant' })).toBeNull()
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Add transaction' }))
  })
})
