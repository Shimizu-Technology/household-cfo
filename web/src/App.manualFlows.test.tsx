// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { AnnualBudgetPlan, BudgetCategoryRow, MiaActionDraft, SpendingReport, TransactionDraft } from './api'
import { CategoryEditCell, CurrentMonthActivityPanel, ManualTransactionCapture, MiaActionDraftReviewStack, TransactionDraftReviewStack } from './App'

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
  it.each([true, false])('uses the compact headline and plain decisions in both review stacks (compact=%s)', (compact) => {
    const props = stackProps([draft({ amount: 25, amount_cents: 2500 })], { compact })
    const { container } = render(<TransactionDraftReviewStack {...props} />)
    expect(container.querySelector('.mia-change-headline .mia-change-figure')?.textContent).toBe('$25')
    expect(container.querySelector('.mia-change-lines')?.textContent).toContain('CategoryDining out')
    expect(container.textContent).not.toMatch(/Actuals do not change|Confirm only if|split, and category/)
    fireEvent.click(screen.getByRole('button', { name: "Confirm McDonald's $25 on Oct 4" }))
    expect(props.onConfirm).toHaveBeenCalledWith(expect.objectContaining({ id: 220 }))
    fireEvent.click(screen.getByRole('button', { name: "Not now McDonald's $25 on Oct 4" }))
    expect(props.onIgnore).toHaveBeenCalledWith(expect.objectContaining({ id: 220 }))
    fireEvent.click(screen.getByRole('button', { name: "Change McDonald's $25 on Oct 4" }))
    expect(screen.getByLabelText('Merchant')).toBeTruthy()
  })

  it('shows a newly drafted purchase even when an earlier queue page and filter were open', async () => {
    const drafts = Array.from({ length: 7 }, (_, index) => draft({ id: index + 1, merchant: `Older shop ${index}` }))
    const props = stackProps(drafts, { compact: true })
    const { rerender } = render(<TransactionDraftReviewStack {...props} />)
    fireEvent.change(screen.getByRole('searchbox'), { target: { value: 'Older shop' } })
    fireEvent.click(screen.getByRole('button', { name: 'Next' }))
    rerender(<TransactionDraftReviewStack {...props} drafts={[draft({ merchant: 'Payless', amount: 18.47, amount_cents: 1847 }), ...drafts]} />)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Confirm Payless $18.47 on Oct 4' })).toBeTruthy())
  })

  it('keeps the search when the first review is resolved', () => {
    const drafts = [draft({ merchant: 'Payless', id: 1 }), draft({ merchant: 'Shell', id: 2 }), ...Array.from({ length: 5 }, (_, index) => draft({ id: index + 3 }))]
    const props = stackProps(drafts, { compact: true })
    const { rerender } = render(<TransactionDraftReviewStack {...props} />)
    fireEvent.change(screen.getByRole('searchbox'), { target: { value: 'Shell' } })
    rerender(<TransactionDraftReviewStack {...props} drafts={drafts.slice(1)} />)
    expect((screen.getByRole('searchbox') as HTMLInputElement).value).toBe('Shell')
  })

  it('names every repeated card button for its own transaction while keeping the visible text short', () => {
    render(<TransactionDraftReviewStack {...stackProps([draft(), draft({ id: 221, merchant: 'Shell', amount: 40, amount_cents: 4000 })])} />)

    for (const [name, text] of [["Change McDonald's $25 on Oct 4", 'Change'], ["Confirm McDonald's $25 on Oct 4", 'Confirm'], ["Not now McDonald's $25 on Oct 4", 'Not now'], ['Change Shell $40 on Oct 4', 'Change'], ['Confirm Shell $40 on Oct 4', 'Confirm']]) {
      expect(screen.getByRole('button', { name }).textContent).toBe(text)
    }
    expect(screen.queryByRole('button', { name: 'Edit' })).toBeNull()
  })

  it('names the restore and undo buttons on reviewed cards', () => {
    const onReopen = vi.fn()
    render(<TransactionDraftReviewStack {...stackProps([draft({ status: 'ignored' }), draft({ id: 222, merchant: 'Shell', status: 'confirmed', amount: 40, amount_cents: 4000 })], { onReopen })} />)
    fireEvent.click(screen.getByRole('button', { name: "Restore draft McDonald's $25 on Oct 4" }))
    expect(onReopen).toHaveBeenCalledWith(expect.objectContaining({ id: 220, status: 'ignored' }))
    expect(screen.getByRole('button', { name: 'Undo to edit Shell $40 on Oct 4' })).toBeTruthy()
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
    fireEvent.click(within(ledgerRow).getByRole('button', { name: "Reopen McDonald's $25 on Oct 4" }))
    expect(onReopen).toHaveBeenLastCalledWith(expect.objectContaining({ id: 220, status: 'confirmed' }))
    fireEvent.click(screen.getByRole('button', { name: 'Restore Shell $40 on Oct 2' }))
    expect(onReopen).toHaveBeenLastCalledWith(expect.objectContaining({ id: 221, status: 'ignored' }))
  })

  it('renders a Reopen button for every confirmed manual row and tells repeat purchases apart by date', () => {
    const repeated = { ...report, transactions: [
      { id: 31, occurred_on: '2026-10-04', merchant: 'Pay-Less', amount: 25, source_type: 'manual_ui', categories: ['Groceries'], transaction_draft_id: 220 },
      { id: 32, occurred_on: '2026-10-03', merchant: 'Pay-Less', amount: 25, source_type: 'manual_ui', categories: ['Groceries'], transaction_draft_id: 222 },
      { id: 33, occurred_on: '2026-10-02', merchant: 'Bank import', amount: 9, source_type: 'plaid', categories: ['Fees'], transaction_draft_id: null },
    ] }
    render(<CurrentMonthActivityPanel plan={plan} currentMonthIndex={9} spendingReport={repeated} loading={false} error={null} reopen={{ action: null, disabled: false, onReopen: vi.fn() }} />)
    expect(screen.getAllByRole('button', { name: /^Reopen / }).map((button) => button.getAttribute('aria-label'))).toEqual(['Reopen Pay-Less $25 on Oct 4', 'Reopen Pay-Less $25 on Oct 3'])
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

describe('out-of-date Mia review cards', () => {
  const miaDraft = (overrides: Partial<MiaActionDraft> = {}): MiaActionDraft => ({
    id: 7,
    status: 'pending',
    draft_type: 'budget_edit',
    year: 2026,
    title: 'Move planned dollars between categories',
    summary: 'I drafted a budget move of $50 from Flexible spending to School Supplies for Oct 2026.',
    rationale: null,
    source_prompt: null,
    created_at: null,
    applied_at: null,
    canceled_at: null,
    items: [{
      id: 1, action_type: 'update_allocation', label: 'Reduce Flexible spending by $50', description: 'Oct: $1,100 to $1,050',
      payload: {}, before_snapshot: {}, after_snapshot: {}, applied_at: null, canceled_at: null, status: 'pending',
      review_fields: [{ label: 'October plan', before: '$1,100', after: '$1,050' }],
    }],
    ...overrides,
  } as MiaActionDraft)
  const props = (drafts: MiaActionDraft[], extra: Record<string, unknown> = {}) => ({ drafts, isRealWorkspace: true, action: null, onApply: vi.fn(), onCancel: vi.fn(), ...extra })

  it('keeps a current card applicable with its before and after values', () => {
    render(<MiaActionDraftReviewStack {...props([miaDraft()])} />)
    expect(screen.getByRole('button', { name: 'Apply change' })).toBeTruthy()
    expect(screen.queryByText(/Budget plan · Pending/)).toBeNull()
    fireEvent.click(screen.getByText('See details'))
    expect(screen.getByText('$1,100')).toBeTruthy()
  })

  it('keeps details collapsed and exposes Change and Not now without applying', () => {
    const onEditManually = vi.fn()
    const onCancel = vi.fn()
    const onApply = vi.fn()
    render(<MiaActionDraftReviewStack {...props([miaDraft()], { onEditManually, onCancel, onApply })} />)
    expect(document.querySelector('details')?.open).toBe(false)
    fireEvent.click(screen.getByRole('button', { name: 'Change' }))
    expect(onEditManually).toHaveBeenCalledOnce()
    fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
    expect(onCancel).toHaveBeenCalledOnce()
    expect(onApply).not.toHaveBeenCalled()
  })

  it('opens the exact manual edit from Change on a single-step plan', () => {
    const onEditManually = vi.fn()
    const draft = miaDraft({ draft_type: 'action_plan' })
    render(<MiaActionDraftReviewStack {...props([draft], { onEditManually })} />)
    fireEvent.click(screen.getByRole('button', { name: 'Change' }))
    expect(onEditManually).toHaveBeenCalledWith(draft, draft.items[0])
    expect(screen.queryByRole('checkbox')).toBeNull()
  })

  it('closes a stale card: out of date, no Apply, no old before values, and a fresh-draft path', () => {
    const onAskFresh = vi.fn()
    const onCancel = vi.fn()
    render(<MiaActionDraftReviewStack {...props([miaDraft({ stale: true, stale_message: 'Budget changed since Mia drafted this.' })], { onAskFresh, onCancel })} />)

    expect(screen.getAllByText('Out of date').length).toBeGreaterThan(0)
    expect(screen.queryByText('Pending')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Apply change' })).toBeNull()
    expect(screen.queryByText('$1,100')).toBeNull()
    expect(screen.getByText(/can’t be applied\. Nothing was changed\./)).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: /for a fresh draft/ }))
    expect(onAskFresh).toHaveBeenCalledWith(expect.objectContaining({ id: 7 }))
    fireEvent.click(screen.getByRole('button', { name: 'Dismiss this draft' }))
    expect(onCancel).toHaveBeenCalledWith(expect.objectContaining({ id: 7 }))
  })

  it('keeps already applied steps visible on an out-of-date partially applied plan', () => {
    const plan = miaDraft({
      status: 'partially_applied', stale: true, draft_type: 'action_plan',
      items: [
        { id: 1, action_type: 'update_allocation', label: 'Raise Groceries', payload: {}, before_snapshot: {}, after_snapshot: {}, applied_at: '2026-10-16T00:00:00Z', canceled_at: null, status: 'applied' },
        { id: 2, action_type: 'update_allocation', label: 'Lower Dining', payload: {}, before_snapshot: {}, after_snapshot: {}, applied_at: null, canceled_at: null, status: 'pending' },
      ] as MiaActionDraft['items'],
    })
    render(<MiaActionDraftReviewStack {...props([plan])} />)
    expect(screen.getByText('Raise Groceries')).toBeTruthy()
    expect(screen.getByText('Applied')).toBeTruthy()
    expect(screen.queryByText('Lower Dining')).toBeNull()
  })

  it('does not treat an already applied card as out of date', () => {
    render(<MiaActionDraftReviewStack {...props([miaDraft({ status: 'applied', stale: true })])} />)
    expect(screen.queryByText('Out of date')).toBeNull()
  })
})

it('uses only the structured headline, shares it across placements, and describes every repeated action', () => {
  const draft = {
    id: 91, status: 'pending', draft_type: 'budget_edit', year: 2026,
    title: 'Move planned money', summary: 'A misleading $190 in prose.', rationale: null, source_prompt: null,
    created_at: null, applied_at: null, canceled_at: null,
    headline: { amount_cents: 6000, label: 'moved to Repairs & surprises' },
    detail_rows: [{ label: 'Dining out', before: '$250', after: '$190' }, { label: 'Repairs & surprises', before: '$40', after: '$100' }],
    detail_note: 'November only. Your actual spending doesn’t change.', items: [],
  } as MiaActionDraft
  render(<><MiaActionDraftReviewStack drafts={[draft]} isRealWorkspace action={null} onApply={vi.fn()} onCancel={vi.fn()} onEditManually={vi.fn()} /><MiaActionDraftReviewStack compact drafts={[{ ...draft, id: 92, summary: 'A different $30 sentence.' }]} isRealWorkspace action={null} onApply={vi.fn()} onCancel={vi.fn()} onEditManually={vi.fn()} /></>)
  expect([...document.querySelectorAll('.mia-change-figure')].map(figure => figure.textContent)).toEqual(['$60', '$60'])
  const ids = [...document.querySelectorAll('.mia-change-sentence')].map(sentence => sentence.id)
  expect(new Set(ids).size).toBe(2)
  document.querySelectorAll('.mia-action-draft-card').forEach((card, index) => {
    card.querySelectorAll('.mia-action-draft-actions button').forEach(button => expect(button.getAttribute('aria-describedby')).toBe(ids[index]))
    expect(card.querySelector('.mia-change-details > summary')?.getAttribute('aria-describedby')).toBe(ids[index])
  })
  expect(screen.queryByText(/Budget plan · Pending/)).toBeNull()
  fireEvent.click(screen.getAllByText('See details')[0])
  expect(screen.getAllByText('Dining out')).toHaveLength(2)
  expect(screen.getAllByText('$250 → $190')).toHaveLength(2)
})

it.each([[1200, '$12'], [1250, '$12.50'], [1201, '$12.01'], [0, '$0'], [-1250, '-$12.50'], [123450, '$1,234.50']])('keeps review money at zero or two decimals for %s cents', (cents, expected) => {
  const draft = { id: 95, status: 'pending', draft_type: 'budget_edit', year: 2026, title: 'Set planned amount', summary: 'Review this change',
    headline: { amount_cents: cents, label: 'new planned amount' }, detail_rows: [{ label: 'Dining out', before: 'Not entered', after: 'Legacy money', before_cents: null, after_cents: cents }], items: [], rationale: null, source_prompt: null, created_at: null, applied_at: null, canceled_at: null } as MiaActionDraft
  render(<MiaActionDraftReviewStack drafts={[draft]} isRealWorkspace action={null} onApply={vi.fn()} onCancel={vi.fn()} />)
  expect(document.querySelector('.mia-change-figure')?.textContent).toBe(expected)
  expect(document.querySelector('.mia-change-lines')?.textContent).toContain(`Not entered → ${expected}`)
})

it('does not derive a figure from prose when the server supplies no headline', () => {
  const draft = { id: 93, status: 'pending', draft_type: 'budget_edit', year: 2026, title: 'Rename', summary: 'Rename the $500 fund', items: [], rationale: null } as unknown as MiaActionDraft
  render(<MiaActionDraftReviewStack drafts={[draft]} isRealWorkspace action={null} onApply={vi.fn()} onCancel={vi.fn()} />)
  expect(document.querySelector('.mia-change-figure')).toBeNull()
})

it('lets a suggested selection disclosure close and reopen while preserving selected changes', async () => {
  const draft = {
    id: 94, status: 'pending', draft_type: 'action_plan', year: 2026, title: 'Two changes', summary: 'Two household changes', rationale: null,
    suggested_selected_item_ids: [1], items: [1, 2].map(id => ({ id, position: id - 1, action_type: 'update_account', label: `Change ${id}`, payload: {}, before_snapshot: {}, after_snapshot: {}, dependencies: [] })),
  } as unknown as MiaActionDraft
  render(<MiaActionDraftReviewStack drafts={[draft]} isRealWorkspace action={null} onApply={vi.fn()} onCancel={vi.fn()} />)
  const details = document.querySelector('details')!
  expect(details.open).toBe(true)
  details.open = false
  fireEvent(details, new Event('toggle'))
  expect(details.open).toBe(false)
  details.open = true
  fireEvent(details, new Event('toggle'))
  expect((screen.getByRole('checkbox', { name: 'Include Change 1' }) as HTMLInputElement).checked).toBe(true)
  expect((screen.getByRole('checkbox', { name: 'Include Change 2' }) as HTMLInputElement).checked).toBe(false)
})
