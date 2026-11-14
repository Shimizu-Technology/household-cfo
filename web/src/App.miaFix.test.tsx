// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { AnnualBudgetPlan, TransactionDraft } from './api'
import { TransactionDraftReviewStack } from './App'

afterEach(() => { cleanup(); vi.resetAllMocks() })
const purchase = (id: number, amount = 25): TransactionDraft => ({ id, merchant: `Shop ${id}`, occurred_on: '2026-10-04', amount, amount_cents: amount * 100, category_id: 7, category_name: 'Groceries', status: 'pending', splits: [], matches: [] })
const drafts = [purchase(1), purchase(2), purchase(3)]
const plan = { year: 2026, months: [{ starts_on: '2026-10-01', ends_on: '2026-10-31' }], rows: [{ id: 7, name: 'Groceries', active: true, months: [{ planned: 100, actual: 10 }] }], pending_transaction_drafts: drafts } as unknown as AnnualBudgetPlan
const props = { drafts, plan, categories: plan.rows, compact: true, collapsed: true, action: null, isRealWorkspace: true, onConfirm: vi.fn(), onIgnore: vi.fn(), onReopen: vi.fn(), onUpdate: vi.fn() }

it('after this counts confirmed spending plus only this purchase', () => {
  render(<TransactionDraftReviewStack {...props} />)
  expect(document.querySelector('.purchase-review-detail')?.textContent).toContain('$65 left in Groceries after this')
})
it('an unknown category allocation never becomes a zero plan', () => {
  const unknown = { ...plan, rows: [{ ...plan.rows[0], months: [{ ...plan.rows[0].months[0], planned: 0, allocation_missing: true }] }] }
  render(<TransactionDraftReviewStack {...props} plan={unknown} />)
  expect(document.querySelector('.purchase-review-detail')?.textContent).not.toMatch(/after this|\$0|over/)
  fireEvent.click(screen.getByText('Purchase details'))
  expect(screen.getByText('The plan for this category is not known yet.')).toBeTruthy()
})
it('an open edit hides the effect and blocks confirming the saved values', () => {
  render(<TransactionDraftReviewStack {...props} />)
  fireEvent.click(screen.getByRole('button', { name: 'Change Shop 1 $25 on Oct 4' }))
  fireEvent.change(screen.getByLabelText('Total', { exact: true }), { target: { value: '80' } })
  expect(document.querySelector('.purchase-review-detail')?.textContent).not.toContain('after this')
  expect((screen.getByRole('button', { name: 'Confirm Shop 1 $25 on Oct 4' }) as HTMLButtonElement).disabled).toBe(true)
  expect(screen.getByText('Save or cancel your edit before confirming this purchase.')).toBeTruthy()
})
it('folding and a newly arriving purchase keep an open second editor mounted', () => {
  const { rerender } = render(<TransactionDraftReviewStack {...props} />)
  fireEvent.click(screen.getByRole('button', { name: '2 more purchases to check' }))
  fireEvent.click(screen.getByRole('button', { name: 'Change Shop 2 $25 on Oct 4' }))
  fireEvent.change(screen.getByLabelText('Merchant'), { target: { value: 'My unsaved shop' } })
  fireEvent.click(screen.getByRole('button', { name: 'Show fewer purchases' }))
  expect((screen.getByLabelText('Merchant') as HTMLInputElement).value).toBe('My unsaved shop')
  rerender(<TransactionDraftReviewStack {...props} drafts={[purchase(4), ...drafts]} />)
  expect((screen.getByLabelText('Merchant') as HTMLInputElement).value).toBe('My unsaved shop')
})
it('an unmatched search keeps an open purchase editor and its unsaved text', () => {
  render(<TransactionDraftReviewStack {...props} drafts={[1, 2, 3, 4, 5, 6].map(id => purchase(id))} collapsed={false} onBulkConfirm={vi.fn()} onBulkIgnore={vi.fn()} />)
  const groupConfirm = () => ['Confirm selected', /^Confirm categorized/].map(name => screen.getByRole('button', { name, hidden: true }) as HTMLButtonElement)
  fireEvent.click(screen.getByLabelText('Select this page'))
  expect(groupConfirm().map(button => button.disabled)).toEqual([false, false])
  fireEvent.click(screen.getByRole('button', { name: 'Change Shop 2 $25 on Oct 4' }))
  fireEvent.change(screen.getByLabelText('Merchant'), { target: { value: 'My unsaved shop' } })
  fireEvent.change(screen.getByLabelText('Search transaction reviews'), { target: { value: 'nothing matches this' } })
  expect(screen.getByText('No transaction reviews match that search.')).toBeTruthy()
  expect((screen.getByLabelText('Merchant') as HTMLInputElement).value).toBe('My unsaved shop')
  expect(screen.queryByRole('button', { name: 'Confirm Shop 1 $25 on Oct 4' })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Clear search' }))
  expect((screen.getByLabelText('Merchant') as HTMLInputElement).value).toBe('My unsaved shop')
  expect(screen.getByRole('button', { name: 'Confirm Shop 1 $25 on Oct 4' })).toBeTruthy()
  // The editor is still open, so confirming a group stays off until it is saved or cancelled.
  expect(groupConfirm().map(button => button.disabled)).toEqual([true, true])
  expect(screen.getByText('Save or cancel your purchase edits before confirming a group.')).toBeTruthy()
})
it('completion focuses its own inert result rather than another money action', () => {
  const { rerender } = render(<TransactionDraftReviewStack {...props} collapsed={false} />)
  screen.getByRole('button', { name: 'Confirm Shop 1 $25 on Oct 4' }).focus()
  rerender(<TransactionDraftReviewStack {...props} collapsed={false} drafts={[{ ...drafts[0], status: 'confirmed' }, ...drafts.slice(1)]} />)
  expect(document.activeElement?.matches('[data-review-confirm], button')).toBe(false)
  expect(document.activeElement?.textContent).toContain('Confirmed')
})
it('finished purchase identifies its amount and date in the result', () => {
  render(<TransactionDraftReviewStack {...props} drafts={[{ ...drafts[0], status: 'confirmed' }]} />)
  expect(document.querySelector('.terminal')?.textContent).toContain('$25')
  expect(document.querySelector('.terminal')?.textContent).toContain('Oct 4')
})
it.each([[65, '$25 left'], [90, '$0 left'], [95, '$5 over']])('uses honest left/zero/over wording for %s', (amount, words) => {
  render(<TransactionDraftReviewStack {...props} drafts={[purchase(1, amount as number)]} />)
  expect(document.querySelector('.purchase-review-detail')?.textContent).toContain(`${words} in Groceries after this`)
})
it('keeps split effects separate and omits uncategorized and outside-year effects', () => {
  const split = { id: 1, budget_category_id: 7, category_name: 'Groceries', amount: 10, amount_cents: 1000, stack_key: null, stack_label: null, notes: null, confidence: null }
  const { rerender } = render(<TransactionDraftReviewStack {...props} drafts={[{ ...purchase(1), splits: [split, { ...split, id: 2, budget_category_id: null, category_name: null, amount: 15 }] }]} />)
  expect(document.querySelector('.purchase-review-detail')?.textContent).toContain('$80 left in Groceries after this')
  expect(document.querySelector('.purchase-review-detail')?.textContent).not.toContain('over')
  rerender(<TransactionDraftReviewStack {...props} drafts={[{ ...purchase(1), occurred_on: '2025-10-04' }]} />)
  expect(document.querySelector('.purchase-review-detail')?.textContent).not.toContain('after this')
})
it('fades a live completion but never a finished purchase restored on mount', () => {
  const { container, rerender, unmount } = render(<TransactionDraftReviewStack {...props} />)
  expect(container.querySelector('.is-live-result')).toBeNull()
  rerender(<TransactionDraftReviewStack {...props} drafts={[{ ...drafts[0], status: 'confirmed' }, ...drafts.slice(1)]} />)
  expect(container.querySelector('[data-review-item="1"].is-live-result')).not.toBeNull()
  unmount()
  const history = render(<TransactionDraftReviewStack {...props} drafts={[{ ...drafts[0], status: 'confirmed' }]} />)
  expect(history.container.querySelector('.is-live-result')).toBeNull()
})

it('bulk confirmation cannot bypass an open purchase edit', () => {
  render(<TransactionDraftReviewStack {...props} collapsed={false} onBulkConfirm={vi.fn()} onBulkIgnore={vi.fn()} />)
  fireEvent.click(screen.getByRole('checkbox', { name: 'Select this page' }))
  fireEvent.click(screen.getByRole('button', { name: 'Change Shop 2 $25 on Oct 4' }))
  expect((screen.getByRole('button', { name: 'Confirm selected' }) as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(screen.getByText('More bulk options'))
  expect((screen.getByRole('button', { name: 'Confirm categorized 3' }) as HTMLButtonElement).disabled).toBe(true)
})

it.each([6, 11, 21])('fix2 folded queue keeps the last of %s purchases reachable after earlier completions', count => {
  const queue = Array.from({ length: count }, (_, index) => purchase(index + 1))
  const { rerender } = render(<TransactionDraftReviewStack {...props} drafts={queue} />)
  for (let done = 1; done < count; done++) {
    fireEvent.click(screen.getByRole('button', { name: `Confirm Shop ${done} $25 on Oct 4` }))
    rerender(<TransactionDraftReviewStack {...props} drafts={queue.slice(done)} completedDrafts={queue.slice(0, done).map(draft => ({ ...draft, status: 'confirmed' }))} />)
    expect(screen.getByRole('button', { name: `Confirm Shop ${done + 1} $25 on Oct 4` })).toBeTruthy()
  }
  for (const action of ['Confirm', 'Change', 'Not now']) expect(screen.getByRole('button', { name: `${action} Shop ${count} $25 on Oct 4` })).toBeTruthy()
})

it('fix2 completed-only mount retains the result and Undo', () => {
  render(<TransactionDraftReviewStack {...props} drafts={[]} completedDrafts={[{ ...purchase(1), status: 'confirmed' }]} />)
  expect(screen.getByText(/Confirmed\. Actuals were updated\./)).toBeTruthy()
  expect(screen.getByRole('button', { name: 'Undo to edit Shop 1 $25 on Oct 4' })).toBeTruthy()
})

it.each(['individual', 'bulk'])('fix2 prunes an editor after %s Ignore so another group can be confirmed', path => {
  const callbacks = { onBulkConfirm: vi.fn(), onBulkIgnore: vi.fn() }
  const { rerender } = render(<TransactionDraftReviewStack {...props} {...callbacks} collapsed={false} />)
  fireEvent.click(screen.getByRole('checkbox', { name: path === 'bulk' ? /Select Shop 1/ : 'Select this page' }))
  fireEvent.click(screen.getByRole('button', { name: 'Change Shop 1 $25 on Oct 4' }))
  if (path === 'individual') fireEvent.click(screen.getByRole('button', { name: 'Not now Shop 1 $25 on Oct 4' }))
  else {
    fireEvent.click(screen.getByRole('button', { name: 'Ignore selected' }))
    expect(callbacks.onBulkIgnore).toHaveBeenCalledWith([drafts[0]])
  }
  rerender(<TransactionDraftReviewStack {...props} {...callbacks} collapsed={false} drafts={drafts.slice(1)} completedDrafts={[{ ...drafts[0], status: 'ignored' }]} />)
  const selectPage = screen.getByRole('checkbox', { name: 'Select this page' }) as HTMLInputElement
  if (!selectPage.checked) fireEvent.click(selectPage)
  expect((screen.getByRole('button', { name: 'Confirm selected' }) as HTMLButtonElement).disabled).toBe(false)
  fireEvent.click(screen.getByText('More bulk options'))
  expect((screen.getByRole('button', { name: 'Confirm categorized 2' }) as HTMLButtonElement).disabled).toBe(false)
})
