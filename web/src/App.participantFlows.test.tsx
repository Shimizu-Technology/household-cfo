// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { IncomeSourceManager, ManualTransactionCapture, TransactionDraftReviewStack, WorkspaceSetupForm } from './App'
import type { TransactionDraft } from './api'

afterEach(() => { cleanup(); vi.resetAllMocks() })
const draft = (id: number): TransactionDraft => ({ id, merchant: `Market ${id}`, amount: 12.34, amount_cents: 1234, occurred_on: '2026-10-21', status: 'pending', category_id: 1, category_name: 'Groceries', splits: [], matches: [] })
const props = { isRealWorkspace: true, action: null, onUpdate: vi.fn(), onConfirm: vi.fn(), onIgnore: vi.fn(), onReopen: vi.fn(), onBulkConfirm: vi.fn(), onBulkIgnore: vi.fn() }

it('shows only selected bulk actions and collapses per-row detail', () => {
  const { container } = render(<TransactionDraftReviewStack {...props} drafts={[draft(1), draft(2)]} />)
  expect(screen.queryByRole('button', { name: 'Confirm selected' })).toBeNull()
  expect(container.querySelector('details')?.open).toBe(false)
  fireEvent.click(screen.getByRole('checkbox', { name: /Select Market 1/ }))
  fireEvent.click(screen.getByRole('button', { name: 'Confirm selected' }))
  expect(props.onBulkConfirm).toHaveBeenCalledWith([draft(1)])
  fireEvent.click(screen.getByRole('button', { name: 'Clear selection' }))
  expect(screen.queryByRole('button', { name: 'Ignore selected' })).toBeNull()
})

it('moves focus to the next row then All caught up when focused reviews leave', () => {
  const view = render(<TransactionDraftReviewStack {...props} drafts={[draft(1), draft(2)]} />)
  act(() => screen.getByRole('button', { name: /^Confirm Market 1/ }).focus())
  view.rerender(<TransactionDraftReviewStack {...props} drafts={[draft(2)]} />)
  expect(document.activeElement).toBe(screen.getByRole('button', { name: /^Confirm Market 2/ }))
  view.rerender(<TransactionDraftReviewStack {...props} drafts={[]} />)
  expect(document.activeElement).toBe(screen.getByRole('status'))
  expect(document.activeElement?.textContent).toBe('All caught up')
})

it('keeps unrelated user focus when a review resolves in the background', () => {
  const view = render(<><button>Elsewhere</button><TransactionDraftReviewStack {...props} drafts={[draft(1)]} /></>)
  act(() => screen.getByRole('button', { name: /^Confirm Market 1/ }).focus())
  act(() => screen.getByRole('button', { name: 'Elsewhere' }).focus())
  view.rerender(<><button>Elsewhere</button><TransactionDraftReviewStack {...props} drafts={[]} /></>)
  expect(document.activeElement?.textContent).toBe('Elsewhere')
})

it('keeps unknown money blank and removes financial fields in the personal editor', () => {
  const values = { household_name: 'Cruz', primary_goal: 'Save', primary_income: '', fixed_expenses: '', flexible_spend: '', emergency_fund: '', other_assets: '', expected_sinking_fund: '', unexpected_sinking_fund: '', business_income: '', target_runway_months: '', debt_payment: '', credit_card_debt: '' }
  const form = { values, editing: false, saving: false, error: null, firstSession: true, onBeginEdit: vi.fn(), onCancel: vi.fn(), onChange: vi.fn(), onSubmit: vi.fn() }
  const view = render(<WorkspaceSetupForm {...form} />)
  expect((screen.getByLabelText(/^Primary monthly income/) as HTMLInputElement).value).toBe('')
  expect(view.container.textContent).not.toContain('blank amount saves as $0')
  view.rerender(<WorkspaceSetupForm {...form} firstSession={false} personalOnly />)
  expect(screen.getByLabelText(/^Household name/)).toBeTruthy()
  expect(screen.queryAllByRole('spinbutton')).toHaveLength(0)
})

it('opens the income form only on request and uses a plain pay-frequency label', () => {
  render(<IncomeSourceManager sources={[]} action={null} error={null} onSave={vi.fn()} onArchive={vi.fn()} onRestore={vi.fn()} />)
  expect(screen.queryByRole('textbox', { name: 'Name' })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Add income source' }))
  expect(screen.getByLabelText("How often you're paid")).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
  expect(screen.queryByRole('textbox', { name: 'Name' })).toBeNull()
})

it('replaces capture guidance with the saved resolution status', () => {
  render(<ManualTransactionCapture categories={[]} busy={false} onCreate={vi.fn()} resolutionNotice="Confirmed Market for $12.34. October confirmed spending: $42.34." />)
  expect(screen.getByRole('status').textContent).toContain('October confirmed spending: $42.34')
})
