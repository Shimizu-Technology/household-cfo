// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { AnnualIncomePlanner, DocumentReviewPanel, IncomeSourceManager, ManualTransactionCapture, TransactionDraftReviewStack, WorkspaceSetupForm } from './App'
import type { AnnualBudgetPlan, FinancialDocumentImport, TransactionDraft } from './api'
import type { ComponentProps } from 'react'

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
  expect(view.container.textContent).toContain('Your household name and the goal your assistant helps you work toward.')
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

it('schedules future pay without treating a future source as archived or admitting an archived source', async () => {
  const future = { id: 6, label: 'Future pay', source_type: 'business', active: false, timeline_status: 'future', starts_on: '2026-11-01', ends_on: null, base_amount: 100.01, base_cadence: 'monthly', schedule_entries: [] }
  const archived = { ...future, id: 7, label: 'Archived pay', timeline_status: 'archived', starts_on: '2026-01-01' }
  const plan = { year: 2026, months: [], monthly_income: {}, income_sources: [future, archived] } as unknown as AnnualBudgetPlan
  const onSave = vi.fn().mockResolvedValue(undefined)
  render(<AnnualIncomePlanner plan={plan} isRealWorkspace action={null} onSave={onSave} onDelete={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: 'Plan an income change' }))
  fireEvent.change(screen.getByLabelText('Starting month'), { target: { value: '2026-12' } })
  expect(screen.getByRole('option', { name: 'Future pay' })).toBeTruthy()
  expect(screen.queryByRole('option', { name: 'Archived pay' })).toBeNull()
  fireEvent.change(screen.getByLabelText('Amount'), { target: { value: '150.03' } })
  fireEvent.click(screen.getByRole('button', { name: 'Schedule income change' }))
  expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ income_source_id: 6, amount: '150.03', effective_on: '2026-12-01' }), undefined)
})

const reviewPanelProps = (documentImport: FinancialDocumentImport): ComponentProps<typeof DocumentReviewPanel> => ({
  documentImport, categories: [], itemSavingIds: new Set(), action: null, draftAction: null, appliedDetailsOpen: false, uploading: false,
  onAppliedDetailsOpenChange: vi.fn(), onUpdateItem: vi.fn(), onUpdateDraft: vi.fn(), onMatchDraft: vi.fn(), onConfirmDraft: vi.fn(),
  onIgnoreDraft: vi.fn(), onReopenDraft: vi.fn(), onBulkConfirmDrafts: vi.fn(), onBulkIgnoreDrafts: vi.fn(), onApply: vi.fn(),
  onReprocess: vi.fn(), onDeleteSource: vi.fn(), onDeleteImport: vi.fn(), onOpenSource: vi.fn(), onUpload: vi.fn(),
})
const statement = (values: Partial<FinancialDocumentImport> = {}) => ({
  id: 1, document_kind: 'statement', status: 'needs_review', filename: 'October.csv', content_type: 'text/csv', byte_size: 140,
  source_available: true, details_included: true, metadata: {}, items: [], transaction_drafts: [draft(1)],
  ...values,
} as FinancialDocumentImport)

it('keeps statement review ahead of file options and omits an empty Apply action', () => {
  const source = statement()
  const actions = reviewPanelProps(source)
  const view = render(<DocumentReviewPanel {...actions} />)
  expect(screen.getByRole('button', { name: /^Confirm Market 1/ })).toBeTruthy()
  expect(screen.queryByRole('button', { name: 'Apply selected' })).toBeNull()
  expect(view.container.querySelector('.document-review-header .document-status')).toBeNull()
  expect(view.container.querySelector('.document-summary-box')).toBeNull()
  const options = view.container.querySelector<HTMLDetailsElement>('.document-file-options')!
  expect(options.open).toBe(false)
  fireEvent.click(screen.getByText('File options'))
  expect(options.open).toBe(true)
  fireEvent.click(screen.getByRole('button', { name: 'Remove original file' }))
  expect(actions.onDeleteSource).toHaveBeenCalledWith(source)
  expect(actions.onDeleteImport).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Delete upload & record' }))
  expect(actions.onDeleteImport).toHaveBeenCalledWith(source)
  expect(actions.onConfirmDraft).not.toHaveBeenCalled()
})

it('keeps approval explicit when a statement includes a selected account value', () => {
  const source = statement({ transaction_drafts: [], items: [{ id: 5, target_type: 'account', label: 'Checking', amount: null, balance: 350.67, balance_cents: 35067, payment: null, interest_rate_percent: null, cadence: 'monthly', source_type: null, account_type: 'checking', debt_type: null, stack_key: null, selected: true, ignored: false, applied_at: null, metadata: {} } as FinancialDocumentImport['items'][number]] })
  const actions = reviewPanelProps(source)
  const view = render(<DocumentReviewPanel {...actions} />)
  expect(actions.onApply).not.toHaveBeenCalled()
  expect(screen.getByRole('button', { name: 'Apply selected' }).hasAttribute('disabled')).toBe(false)
  fireEvent.click(screen.getByRole('button', { name: 'Apply selected' }))
  expect(actions.onApply).toHaveBeenCalledWith(source)
  expect(actions.onDeleteImport).not.toHaveBeenCalled()
  const applied = { ...source, status: 'applied' as const, applied_at: '2026-10-22T00:00:00Z', items: source.items.map(item => ({ ...item, applied_at: '2026-10-22T00:00:00Z' })) }
  view.rerender(<DocumentReviewPanel {...actions} documentImport={applied} />)
  expect(screen.getAllByRole('button', { name: 'Edit saved values' })).toHaveLength(1)
  fireEvent.click(screen.getByText('File options'))
  expect(screen.getByRole('button', { name: 'Delete upload & record' }).hasAttribute('disabled')).toBe(true)
})
