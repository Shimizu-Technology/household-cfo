// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { TransactionDraftReviewStack } from './App'
import type { TransactionDraft } from './api'

afterEach(cleanup)
beforeEach(() => vi.resetAllMocks())

const draft: TransactionDraft = {
  id: 901, merchant: 'Payless', occurred_on: '2026-11-02', amount: 12, amount_cents: 1200,
  category_id: null, category_name: 'Needs category', status: 'pending', source_type: 'manual_chat',
  splits: [{ id: 902, budget_category_id: null, category_name: 'Needs category', stack_key: null,
    stack_label: '', amount: 12, amount_cents: 1200, notes: null, confidence: null, metadata: {} }],
}

it('keeps a new category attached to its purchase and saves it for confirmation', async () => {
  const onUpdate = vi.fn().mockResolvedValue(undefined)
  render(<TransactionDraftReviewStack drafts={[draft]} isRealWorkspace action={null}
    onUpdate={onUpdate} onConfirm={vi.fn()} onIgnore={vi.fn()} onReopen={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: /^Change Payless/ }))
  fireEvent.change(screen.getByLabelText('Category'), { target: { value: 'new' } })
  fireEvent.change(screen.getByLabelText('New category name'), { target: { value: 'Cigarettes' } })
  expect(screen.getByText(/Added to flexible spending/)).toBeTruthy()
  const save = screen.getByRole('button', { name: 'Save draft' })
  await waitFor(() => expect((save as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(save)
  await waitFor(() => expect(onUpdate).toHaveBeenCalledWith(draft, expect.objectContaining({
    merchant: 'Payless', amount: '12.00', removed_split_ids: [902], splits: [expect.objectContaining({
      id: undefined, budget_category_id: null, category_name: 'Cigarettes', stack_key: 'discretionary', amount: '12.00',
    })],
  })))
})

it('allows confirmation after the named category has been saved without requiring an existing id', () => {
  const onConfirm = vi.fn()
  const named: TransactionDraft = { ...draft, category_name: 'Cigarettes', splits: draft.splits?.map((split) => ({ ...split, category_name: 'Cigarettes', stack_key: 'discretionary' })) }
  render(<TransactionDraftReviewStack drafts={[named]} isRealWorkspace action={null}
    onConfirm={onConfirm} onIgnore={vi.fn()} onReopen={vi.fn()} />)
  const confirm = screen.getByRole('button', { name: /^Confirm Payless/ })
  expect(screen.queryByText('Needs category')).toBeNull()
  expect((confirm as HTMLButtonElement).disabled).toBe(false)
  fireEvent.click(confirm)
  expect(onConfirm).toHaveBeenCalledWith(named)
})

it('keeps an extracted category suggestion in review until someone chooses it', () => {
  const imported: TransactionDraft = { ...draft, source_type: 'statement', category_name: 'Cigarettes',
    splits: draft.splits?.map((split) => ({ ...split, category_name: 'Cigarettes', metadata: { extracted_category_name: 'Cigarettes' } })) }
  render(<TransactionDraftReviewStack drafts={[imported]} isRealWorkspace action={null}
    onConfirm={vi.fn()} onIgnore={vi.fn()} onReopen={vi.fn()} />)
  expect((screen.getByRole('button', { name: /^Confirm Payless/ }) as HTMLButtonElement).disabled).toBe(true)
})

it('asks for a category name before saving a new category', () => {
  const onUpdate = vi.fn()
  render(<TransactionDraftReviewStack drafts={[draft]} isRealWorkspace action={null}
    onUpdate={onUpdate} onConfirm={vi.fn()} onIgnore={vi.fn()} onReopen={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: /^Change Payless/ }))
  fireEvent.change(screen.getByLabelText('Category'), { target: { value: 'new' } })
  fireEvent.click(screen.getByRole('button', { name: 'Save draft' }))
  expect(screen.getByRole('alert').textContent).toContain('Name the new category before saving.')
  expect(onUpdate).not.toHaveBeenCalled()
})

it('requires an existing category for document drafts even after a named replacement was reviewed', () => {
  const imported: TransactionDraft = { ...draft, source_type: 'receipt', financial_document_import_id: 42,
    category_name: 'Cigarettes', splits: draft.splits?.map((split) => ({ ...split, category_name: 'Cigarettes',
      metadata: { new_category: true, human_reviewed_replacement: true } })) }
  render(<TransactionDraftReviewStack drafts={[imported]} isRealWorkspace action={null}
    onUpdate={vi.fn()} onConfirm={vi.fn()} onIgnore={vi.fn()} onReopen={vi.fn()} />)
  expect((screen.getByRole('button', { name: /^Confirm Payless/ }) as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(screen.getByRole('button', { name: /^Change Payless/ }))
  expect(screen.queryByRole('option', { name: 'New category' })).toBeNull()
  expect(screen.queryByLabelText('New category name')).toBeNull()
})
