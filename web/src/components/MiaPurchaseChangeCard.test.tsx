// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import type { MiaActionDraft, MiaPurchaseChangeData } from '../api'
import { MiaPurchaseChangeCard } from './MiaPurchaseChangeCard'

const base = { id: 7, status: 'pending', draft_type: 'purchase_change', year: 2026, title: 'Change this purchase?', summary: 'Target', rationale: null, source_prompt: null, created_at: null, applied_at: null, canceled_at: null, items: [] }
const confirm: MiaPurchaseChangeData = {
  mode: 'confirm', merchant: 'Target', date_label: 'Tue, Nov 10', amount: '$46', void: false,
  rows: [{ label: 'Amount', before: '$46', after: '$64' }, { label: 'Category', before: 'Shopping', after: 'Groceries' }],
  effects: ['Groceries, November: $228 spent of your $300 plan, $72 left (was $210 spent).'], note: 'The old entry stays in your history.', options: [],
}
const draft = (change: MiaPurchaseChangeData, over: Partial<MiaActionDraft> = {}) => ({ ...base, purchase_change: change, ...over }) as MiaActionDraft
beforeEach(() => vi.resetAllMocks())
afterEach(cleanup)

it('shows what changes and how Budget moves, and changes nothing until Yes', () => {
  const onApply = vi.fn()
  render(<MiaPurchaseChangeCard draft={draft(confirm)} action={null} disabled={false} onApply={onApply} onCancel={vi.fn()} onChoose={vi.fn()} />)
  expect(screen.getByRole('heading', { name: 'Change your Target purchase?' })).toBeTruthy()
  expect(screen.getByText('Amount')).toBeTruthy()
  expect(screen.getByText('$64')).toBeTruthy()
  expect(screen.getByText(/Groceries, November: \$228 spent/)).toBeTruthy()
  expect(screen.getByText(/Nothing changes until you tap Yes\. The old entry stays in your history\./)).toBeTruthy()
  expect(onApply).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Yes, change it' }))
  expect(onApply).toHaveBeenCalledOnce()
})

it('says plainly that a removal leaves spending', () => {
  const onCancel = vi.fn()
  render(<MiaPurchaseChangeCard draft={draft({ ...confirm, void: true, rows: [], effects: [], merchant: 'Starbucks', amount: '$12', note: 'It leaves your spending totals. The entry stays in your history as removed.' })} action={null} disabled={false} onApply={vi.fn()} onCancel={onCancel} onChoose={vi.fn()} />)
  expect(screen.getByRole('heading', { name: 'Take Starbucks out of your spending?' })).toBeTruthy()
  expect(screen.getByText(/entry stays in your history as removed/)).toBeTruthy()
  expect(screen.getByRole('button', { name: 'Yes, take it out' })).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
  expect(onCancel).toHaveBeenCalledOnce()
})

it('offers up to three purchases as choices and reports a failed pick without changing anything', async () => {
  const onChoose = vi.fn().mockResolvedValueOnce(false).mockResolvedValueOnce(true)
  const options = [{ index: 0, label: 'Target · $46 · Mon, Nov 9' }, { index: 1, label: 'Target · $52 · Fri, Nov 6' }]
  render(<MiaPurchaseChangeCard draft={draft({ mode: 'choose', void: false, rows: [], effects: [], options })} action={null} disabled={false} onApply={vi.fn()} onCancel={vi.fn()} onChoose={onChoose} />)
  expect(screen.queryByRole('button', { name: /Yes/ })).toBeNull()
  fireEvent.click(screen.getByRole('button', { name: 'Target · $52 · Fri, Nov 6' }))
  await screen.findByRole('alert')
  expect(onChoose).toHaveBeenCalledWith(expect.objectContaining({ id: 7 }), 1)
  await waitFor(() => expect((screen.getByRole('button', { name: 'Target · $46 · Mon, Nov 9' }) as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByRole('button', { name: 'Target · $46 · Mon, Nov 9' }))
  await waitFor(() => expect(onChoose).toHaveBeenCalledTimes(2))
})

it('cannot be applied once it is out of date, or while another action runs', () => {
  const { rerender } = render(<MiaPurchaseChangeCard draft={draft(confirm, { stale: true })} action={null} disabled={false} onApply={vi.fn()} onCancel={vi.fn()} onChoose={vi.fn()} />)
  expect((screen.getByRole('button', { name: 'Yes, change it' }) as HTMLButtonElement).disabled).toBe(true)
  expect(screen.getByText(/can’t be applied. Nothing was changed/)).toBeTruthy()
  rerender(<MiaPurchaseChangeCard draft={draft(confirm)} action="apply-mia-action:7" disabled={false} onApply={vi.fn()} onCancel={vi.fn()} onChoose={vi.fn()} />)
  expect((screen.getByRole('button', { name: 'Saving…' }) as HTMLButtonElement).disabled).toBe(true)
})

it('a confirm-mode draft with its purchase item is a plain MiaActionDraft, no cast needed', () => {
  const typed: MiaActionDraft = {
    ...base, id: 9, status: 'pending', draft_type: 'purchase_change', purchase_change: confirm,
    items: [{ id: 1, action_type: 'change_purchase', label: 'Change Target', description: 'Amount: $46 → $64', payload: {}, before_snapshot: {}, after_snapshot: {}, operation_key: null, operation_version: null, target_record_type: 'TransactionDraft', target_record_id: 3 }],
  }
  render(<MiaPurchaseChangeCard draft={typed} action={null} disabled={false} onApply={vi.fn()} onCancel={vi.fn()} onChoose={vi.fn()} />)
  expect(screen.getByRole('heading', { name: 'Change your Target purchase?' })).toBeTruthy()
})
