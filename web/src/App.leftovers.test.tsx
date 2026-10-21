// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { ComponentProps } from 'react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { BudgetCategoryRow, DashboardData, DocumentImportItem, FinancialDocumentImport } from './api'
import { BulkConfirmDialog, DocumentImportItemEditor, ManualTransactionCapture, WorkspaceSetupForm } from './App'
import { selectedApplyItemIds } from './lib/documentReview'
import { HomeScreen } from './components/HomeScreen'

afterEach(cleanup)

describe('bulk confirm dialog', () => {
  it('explains a wrong phrase in the dialog and only confirms on the exact phrase', () => {
    const onConfirm = vi.fn()
    render(<BulkConfirmDialog count={3} total={75} onCancel={vi.fn()} onConfirm={onConfirm} />)
    const dialog = screen.getByRole('dialog', { name: /Confirm 3 transactions/ })
    const input = screen.getByRole('textbox', { name: 'Type CONFIRM 3' })

    fireEvent.change(input, { target: { value: 'confirm' } })
    fireEvent.click(screen.getByRole('button', { name: 'Confirm 3' }))
    expect(screen.getByRole('alert').textContent).toBe('Nothing was confirmed. Type CONFIRM 3 exactly to confirm all 3.')
    expect(input.getAttribute('aria-invalid')).toBe('true')
    expect(onConfirm).not.toHaveBeenCalled()
    expect(dialog).toBeTruthy()

    fireEvent.change(input, { target: { value: 'CONFIRM 3' } })
    expect(screen.queryByRole('alert')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Confirm 3' }))
    expect(onConfirm).toHaveBeenCalledTimes(1)
  })

  it('goes back without confirming', () => {
    const onCancel = vi.fn()
    const onConfirm = vi.fn()
    render(<BulkConfirmDialog count={1} total={5} onCancel={onCancel} onConfirm={onConfirm} />)
    fireEvent.click(screen.getByRole('button', { name: 'Go back' }))
    expect(onCancel).toHaveBeenCalled()
    expect(onConfirm).not.toHaveBeenCalled()
  })
})

describe('quick capture', () => {
  const category = { id: 7, name: 'Dining out', stack_key: 'discretionary', stack_label: 'Discretionary', active: true, months: [], planned_total: 0, actual_total: 0 } as BudgetCategoryRow

  it('closes with Escape pressed on the opening button and keeps focus there', () => {
    render(<ManualTransactionCapture categories={[category]} busy={false} onCreate={vi.fn()} />)
    const toggle = screen.getByRole('button', { name: 'Add transaction' })
    fireEvent.click(toggle)
    expect(screen.getByRole('textbox', { name: 'Merchant' })).toBeTruthy()
    toggle.focus()
    fireEvent.keyDown(toggle, { key: 'Escape' })
    expect(screen.queryByRole('textbox', { name: 'Merchant' })).toBeNull()
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Add transaction' }))
  })

  it('confirms an added transaction in a polite status message', async () => {
    const onCreate = vi.fn().mockResolvedValue(undefined)
    render(<ManualTransactionCapture categories={[category]} busy={false} onCreate={onCreate} />)
    fireEvent.click(screen.getByRole('button', { name: 'Add transaction' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'Merchant' }), { target: { value: 'Pay-Less' } })
    fireEvent.change(screen.getByLabelText('Amount'), { target: { value: '12.5' } })
    fireEvent.click(screen.getByRole('button', { name: 'Add to review' }))
    const status = await screen.findByRole('status')
    expect(status.textContent).toBe('Added Pay-Less for $12.50 to your review. Your actuals stay unchanged until you confirm it.')
  })
})

describe('profile base amounts', () => {
  const values = {
    household_name: 'Cruz', primary_goal: 'Save', primary_income: '3000', business_income: '0', fixed_expenses: '1020', flexible_spend: '500',
    expected_sinking_fund: '0', unexpected_sinking_fund: '0', emergency_fund: '0', other_assets: '0', target_runway_months: '3',
  }
  const props: ComponentProps<typeof WorkspaceSetupForm> = { values: values as never, editing: false, saving: false, error: null, firstSession: false, onBeginEdit: vi.fn(), onCancel: vi.fn(), onChange: vi.fn(), onSubmit: vi.fn() }

  it('says these are base amounts and names the month plan when it differs', () => {
    render(<WorkspaceSetupForm {...props} monthPlan={{ label: 'October', fixed: 1100, flexible: 500 }} />)
    const note = screen.getByRole('note').textContent ?? ''
    expect(note).toContain('base monthly amounts')
    expect(note).toContain('Your October plan in Budget: Fixed essentials $1,100.')
    expect(note).not.toContain('Flexible spending')
  })

  it('keeps the first-run Save after every field', () => {
    render(<WorkspaceSetupForm {...props} editing firstSession monthPlan={null} />)
    const save = screen.getByRole('button', { name: /Save and talk to/ })
    const fields = Array.from(document.querySelectorAll('input, textarea'))
    expect(fields.length).toBeGreaterThan(0)
    for (const field of fields) expect(field.compareDocumentPosition(save) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(screen.queryByRole('note')).toBeNull()
  })
})

describe('debt minimums card', () => {
  it('keeps Home focused on money and one next action when debt minimums need entry', () => {
    const dashboard = {
      summary: { readiness_tone: 'yellow', readiness_label: 'Debt minimums needed', readiness_available: false, next_safe_to_spend_amount: null, monthly_income: 0, debt_payments: 0 },
      action_center: { current_month_label: 'October', current_year: 2026, current_month_index: 9, total_review_count: 0, transaction_review_count: 0, mia_action_review_count: 0 },
      coach_read: { title: 'Finish the debt minimums before making a cash-flow call.', body: 'Add it in My Money, under Debt.', action: 'open_debt' },
      alerts: [{ tone: 'yellow', title: 'Debt minimums needed', body: 'Add every required monthly minimum in My Money, under Debt.', action: 'open_debt' }],
      readiness_path: { available: false },
      next_steps: [], accounts: [],
    } as unknown as DashboardData
    const onOpenDebt = vi.fn()
    render(<HomeScreen dashboard={dashboard} budget={{} as never} onAskMia={vi.fn()} onReviewTransactions={vi.fn()} onReviewMiaActions={vi.fn()} pendingImportCount={0} onReviewImports={vi.fn()} onOpenDebt={onOpenDebt} />)
    expect(screen.queryByRole('button', { name: 'Add debt minimums' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Open My Money > Debt' })).toBeNull()
    expect(screen.getByRole('button', { name: /Tell .+ what changed/ })).toBeTruthy()
  })
})

describe('imported income without a pay frequency', () => {
  const documentImport = { id: 1, status: 'needs_review', metadata: {}, items: [], transaction_drafts: [] } as unknown as FinancialDocumentImport
  const item = {
    id: 5, target_type: 'income_source', label: 'Payroll deposit', amount: 1500, amount_cents: 150000, balance: null, balance_cents: null, payment: null, payment_cents: null,
    interest_rate_percent: null, cadence: null, source_type: 'job', stack_key: null, account_type: null, debt_type: null, confidence: 'medium',
    evidence: 'Pay frequency is not shown.', selected: false, ignored: false, applied_at: null, applied_record_type: null, applied_record_id: null, metadata: {},
  } as DocumentImportItem

  it('leaves it out of Apply selected so the rest of a mixed import still applies', () => {
    const debt = { ...item, id: 6, target_type: 'debt', label: 'Visa', cadence: null, selected: true } as DocumentImportItem
    const account = { ...item, id: 7, target_type: 'account', label: 'Checking', cadence: null, selected: true } as DocumentImportItem
    const mixed = { ...documentImport, items: [{ ...item, selected: true }, debt, account] } as FinancialDocumentImport
    expect(selectedApplyItemIds(mixed)).toEqual([6, 7])
  })

  it('blocks apply, explains why, and does not assume monthly', async () => {
    render(<DocumentImportItemEditor documentImport={documentImport} item={{ ...item, selected: true }} saving={false} onUpdate={vi.fn()} />)
    const box = screen.getByRole('checkbox') as HTMLInputElement
    expect(box.disabled).toBe(true)
    expect(box.checked).toBe(false)
    expect(screen.getByText('Choose how often first')).toBeTruthy()
    expect(screen.getByRole('note').textContent).toContain('does not say how often you are paid')
    fireEvent.click(screen.getByRole('button', { name: 'Edit value' }))
    const cadence = screen.getByLabelText('Cadence') as HTMLSelectElement
    expect(cadence.value).toBe('')
    expect(screen.getByRole('option', { name: 'Choose how often' })).toBeTruthy()
    fireEvent.change(cadence, { target: { value: 'biweekly' } })
    await waitFor(() => expect(cadence.value).toBe('biweekly'))
  })

  it('lets income that states its frequency be applied', () => {
    render(<DocumentImportItemEditor documentImport={documentImport} item={{ ...item, cadence: 'biweekly' }} saving={false} onUpdate={vi.fn()} />)
    expect((screen.getByRole('checkbox') as HTMLInputElement).disabled).toBe(false)
    expect(screen.queryByRole('note')).toBeNull()
  })
})
