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
    setup_card: { title: 'Your setup so far', rows, can_apply: canApply },
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

  it('disables Apply with no savable row', () => {
    setup([row('primary_income', {})], false)
    expect((screen.getByRole('button', { name: 'Apply' }) as HTMLButtonElement).disabled).toBe(true)
  })
})
