// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { MiaActionDraft, MiaSetupCardRow } from '../api'
import { MiaSetupCard } from './MiaSetupCard'

const row = (key: string, overrides: Partial<MiaSetupCardRow> = {}): MiaSetupCardRow => ({
  key, label: key, kind: 'money', status: 'missing', value_text: null, total_cents: null, parts: [], note: null, ...overrides,
})

function draft(rows: MiaSetupCardRow[], canApply = true): MiaActionDraft {
  return {
    id: 7, status: 'pending', draft_type: 'household_setup', year: 2026, title: 'Your setup so far', summary: 'Your setup so far',
    rationale: null, source_prompt: null, created_at: null, applied_at: null, canceled_at: null, items: [],
    setup_card: { title: 'Your setup so far', rows, can_apply: canApply, revision: 1 },
  }
}

function setup(rows: MiaSetupCardRow[], canApply = true) {
  const onEdit = vi.fn().mockResolvedValue(true)
  const onApply = vi.fn()
  const onCancel = vi.fn()
  render(<MiaSetupCard draft={draft(rows, canApply)} isRealWorkspace action={null} disabled={false} onApply={onApply} onCancel={onCancel} onEdit={onEdit} />)
  return { onEdit, onApply, onCancel }
}

afterEach(cleanup)

describe('MiaSetupCard', () => {
  it('shows entered, missing, skipped and needs-a-monthly-amount rows without a dollar for unknown', () => {
    setup([
      row('household_name', { kind: 'text', status: 'entered', value_text: 'Cruz Ohana', label: 'Household name' }),
      row('primary_goal', { kind: 'text', status: 'skipped', label: 'Main goal' }),
      row('primary_income', { label: 'Monthly income' }),
      row('fixed_expenses', { label: 'Fixed essentials', status: 'needs_monthly', parts: [{ id: 'a', label: 'Groceries', cents: null, counted: false, note: '$200 a week' }], note: 'Groceries needs a monthly amount.' }),
    ])
    expect(screen.getByText('Cruz Ohana')).toBeTruthy()
    expect(screen.getByText('Skipped for now')).toBeTruthy()
    expect(screen.getByText('Not entered yet')).toBeTruthy()
    expect(screen.getByText('$200 a week')).toBeTruthy()
    expect(screen.queryByText('$0')).toBeNull()
  })

  it('saves a row edit and asks to skip only for a missing row', async () => {
    const { onEdit } = setup([row('primary_income', { label: 'Monthly income' })])
    fireEvent.click(screen.getByRole('button', { name: /Change Monthly income/ }))
    fireEvent.change(screen.getByRole('textbox'), { target: { value: '4200' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(onEdit).toHaveBeenCalledWith(expect.anything(), { field: 'primary_income', action_name: 'set', part_id: undefined, value: '4200' }))
    await waitFor(() => expect(screen.queryByRole('textbox')).toBeNull())
    fireEvent.click(screen.getByRole('button', { name: /Change Monthly income/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Skip for now' }))
    await waitFor(() => expect(onEdit).toHaveBeenCalledWith(expect.anything(), { field: 'primary_income', action_name: 'skip' }))
  })

  it('warns before Not now clears answers, and stays quiet with nothing to lose', () => {
    const { onCancel } = setup([row('household_name', { kind: 'text', status: 'entered', value_text: 'Cruz Ohana', label: 'Household name' })])
    fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
    expect(onCancel).not.toHaveBeenCalled()
    expect(screen.getByText(/This clears what you've told me/)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Keep my card' }))
    expect(screen.getByRole('button', { name: 'Apply' })).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
    fireEvent.click(screen.getByRole('button', { name: 'Clear this card' }))
    expect(onCancel).toHaveBeenCalledTimes(1)
    cleanup()
    const empty = setup([row('primary_income', { label: 'Monthly income' })], false)
    fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
    expect(empty.onCancel).toHaveBeenCalledTimes(1)
  })

  it('warns before Not now drops a typed edit, and moves focus with the confirmation', () => {
    const { onCancel } = setup([row('primary_income', { label: 'Monthly income' })], false)
    fireEvent.click(screen.getByRole('button', { name: /Change Monthly income/ }))
    fireEvent.change(screen.getByRole('textbox'), { target: { value: '4200' } })
    fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
    expect(onCancel).not.toHaveBeenCalled()
    expect(document.activeElement?.textContent).toBe('Keep my card')
    fireEvent.click(screen.getByRole('button', { name: 'Keep my card' }))
    expect(document.activeElement?.textContent).toBe('Not now')
    expect((screen.getByRole('textbox') as HTMLInputElement).value).toBe('4200')
  })

  it('edits and removes one part', async () => {
    const { onEdit } = setup([row('fixed_expenses', { label: 'Fixed essentials', status: 'entered', total_cents: 150000, parts: [{ id: 'p1', label: 'Rent', cents: 150000, counted: true }] })])
    expect(screen.getAllByText('$1,500')).toHaveLength(2)
    fireEvent.click(screen.getByRole('button', { name: /Change Rent/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Remove' }))
    await waitFor(() => expect(onEdit).toHaveBeenCalledWith(expect.anything(), { field: 'fixed_expenses', action_name: 'remove', part_id: 'p1' }))
  })

  it('applies the card and blocks Apply when nothing is ready', () => {
    const { onApply } = setup([row('primary_income', { status: 'entered', total_cents: 100000 })])
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }))
    expect(onApply).toHaveBeenCalledOnce()
  })

  it('keeps Apply off while a typed edit is open and returns focus after saving', async () => {
    setup([row('primary_income', { label: 'Monthly income', status: 'entered', total_cents: 100000 })])
    const apply = screen.getByRole('button', { name: 'Apply' }) as HTMLButtonElement
    expect(apply.disabled).toBe(false)
    fireEvent.click(screen.getByRole('button', { name: /Change Monthly income/ }))
    expect(apply.disabled).toBe(true)
    fireEvent.change(screen.getByRole('textbox'), { target: { value: '1200' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(screen.queryByRole('textbox')).toBeNull())
    await waitFor(() => expect(document.activeElement?.getAttribute('aria-label')).toMatch(/Change Monthly income/))
    expect(apply.disabled).toBe(false)
  })

  it('edits named debts one row at a time, not through their total', () => {
    setup([row('debt_payment', { kind: 'debts', label: 'Debts', status: 'entered', total_cents: 7500, parts: [{ id: 'd1', label: 'Visa', cents: 7500, counted: true }] })])
    expect(screen.queryByRole('button', { name: /Change Debts/ })).toBeNull()
    expect(screen.getByRole('button', { name: /Change Visa/ })).toBeTruthy()
  })

  it('stays usable when an edit rejects', async () => {
    const { onEdit } = setup([row('primary_income', { label: 'Monthly income' })])
    onEdit.mockRejectedValueOnce(new Error('boom'))
    fireEvent.click(screen.getByRole('button', { name: /Change Monthly income/ }))
    fireEvent.change(screen.getByRole('textbox'), { target: { value: '1200' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect((screen.getByRole('button', { name: 'Save' }) as HTMLButtonElement).disabled).toBe(false))
  })

  it('lists what is still to add and what was skipped in one line, not as rows', () => {
    render(<MiaSetupCard draft={{ ...draft([row('primary_income', { label: 'Monthly income', status: 'entered', total_cents: 420000 })]), setup_card: { title: 'Your setup so far', rows: [row('primary_income', { label: 'Monthly income', status: 'entered', total_cents: 420000 })], can_apply: true, revision: 1, still_to_add: ['Main goal', 'Everyday spending'], skipped: ['Household name'] } }}
      isRealWorkspace action={null} disabled={false} onApply={vi.fn()} onCancel={vi.fn()} onEdit={vi.fn()} />)
    expect(screen.getByText('Still to add: main goal and everyday spending. Skipped for now: household name.')).toBeTruthy()
    expect(screen.queryByText('Not entered yet')).toBeNull()
  })

  it('shows a bill being taken off without letting it be edited as an amount', () => {
    setup([row('fixed_expenses', { label: 'Fixed essentials', status: 'entered', total_cents: 183000, note: 'Rent and Power stay as they are.',
      parts: [{ id: 'saved-1', label: 'Insurance', cents: 12000, counted: true, note: 'Taking this off', removable: false, removed: true }] })])
    expect(screen.getByText('Taking off')).toBeTruthy()
    expect(screen.queryByRole('button', { name: /Change Insurance/ })).toBeNull()
    expect(screen.getByText('Rent and Power stay as they are.')).toBeTruthy()
  })

  it('returns focus to the edited row even when the card re-renders from new data', async () => {
    const onEdit = vi.fn().mockResolvedValue(true)
    const rows = [row('primary_income', { label: 'Monthly income', status: 'entered', total_cents: 100000 })]
    const view = render(<MiaSetupCard draft={draft(rows)} isRealWorkspace action={null} disabled={false} onApply={vi.fn()} onCancel={vi.fn()} onEdit={onEdit} />)
    fireEvent.click(screen.getByRole('button', { name: /Change Monthly income/ }))
    fireEvent.change(screen.getByRole('textbox'), { target: { value: '1200' } })
    onEdit.mockImplementationOnce(async () => {
      view.rerender(<MiaSetupCard draft={draft([row('primary_income', { label: 'Monthly income', status: 'entered', total_cents: 120000 })])} isRealWorkspace action="edit-setup-card:7" disabled={false} onApply={vi.fn()} onCancel={vi.fn()} onEdit={onEdit} />)
      return true
    })
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(screen.queryByRole('textbox')).toBeNull())
    view.rerender(<MiaSetupCard draft={draft([row('primary_income', { label: 'Monthly income', status: 'entered', total_cents: 120000 })])} isRealWorkspace action={null} disabled={false} onApply={vi.fn()} onCancel={vi.fn()} onEdit={onEdit} />)
    await waitFor(() => expect(document.activeElement?.getAttribute('aria-label')).toBe('Change Monthly income: $1,200'))
  })

  it('moves focus on when the edited bill becomes a taken-off row, instead of dropping it to the page', async () => {
    const onEdit = vi.fn().mockResolvedValue(true)
    const bills = (removed: boolean) => [row('fixed_expenses', { label: 'Fixed essentials', status: 'entered', total_cents: 183000,
      parts: [
        { id: 'saved-1', label: 'Insurance', cents: 12000, counted: true, ...(removed ? { removed: true, removable: false, note: 'Taking this off' } : {}) },
        { id: 'saved-2', label: 'Rent', cents: 165000, counted: true },
      ] })]
    const view = render(<MiaSetupCard draft={draft(bills(false))} isRealWorkspace action={null} disabled={false} onApply={vi.fn()} onCancel={vi.fn()} onEdit={onEdit} />)
    fireEvent.click(screen.getByRole('button', { name: /Change Insurance/ }))
    onEdit.mockImplementationOnce(async () => {
      view.rerender(<MiaSetupCard draft={draft(bills(true))} isRealWorkspace action={null} disabled={false} onApply={vi.fn()} onCancel={vi.fn()} onEdit={onEdit} />)
      return true
    })
    fireEvent.click(screen.getByRole('button', { name: 'Remove' }))
    await waitFor(() => expect(screen.getByText('Taking off')).toBeTruthy())
    await waitFor(() => expect(document.activeElement?.getAttribute('aria-label')).toMatch(/Change Rent/))
  })

  it('falls back to Apply when the edited row is gone from the card', async () => {
    const onEdit = vi.fn().mockResolvedValue(true)
    const withPart = [row('fixed_expenses', { label: 'Fixed essentials', status: 'entered', total_cents: 6000, parts: [{ id: 'p1', label: 'Phone', cents: 6000, counted: true }] })]
    const view = render(<MiaSetupCard draft={draft(withPart)} isRealWorkspace action={null} disabled={false} onApply={vi.fn()} onCancel={vi.fn()} onEdit={onEdit} />)
    fireEvent.click(screen.getByRole('button', { name: /Change Phone/ }))
    onEdit.mockImplementationOnce(async () => {
      view.rerender(<MiaSetupCard draft={draft([row('primary_income', { label: 'Monthly income', status: 'entered', total_cents: 100000 })])} isRealWorkspace action={null} disabled={false} onApply={vi.fn()} onCancel={vi.fn()} onEdit={onEdit} />)
      return true
    })
    fireEvent.click(screen.getByRole('button', { name: 'Remove' }))
    await waitFor(() => expect(document.activeElement?.tagName).not.toBe('BODY'), { timeout: 2000 })
  })

  it('disables Apply with no savable row', () => {
    setup([row('primary_income', {})], false)
    expect((screen.getByRole('button', { name: 'Apply' }) as HTMLButtonElement).disabled).toBe(true)
  })
})
