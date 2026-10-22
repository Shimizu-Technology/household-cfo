// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { useState } from 'react'
import type { AnnualBudgetPlan, IncomeTimelineSource, IncomeScheduleEntry } from '../api'
import { AnnualIncomePlanner } from './AnnualIncomePlanner'
import { IncomeSourceManager } from './IncomeSourceManager'
import { IncomeForms } from './IncomeForms'

afterEach(() => { cleanup(); vi.resetAllMocks() })
const source: IncomeTimelineSource = { id: 8, label: 'Ana pay', source_type: 'job', active: true, timeline_status: 'current', starts_on: '2026-01-01', ends_on: null, base_amount: 6200, base_cadence: 'monthly', schedule_entries: [] }
const plan = { year: 2026, months: [], monthly_income: {}, income_sources: [source] } as unknown as AnnualBudgetPlan
function open(onSave = vi.fn().mockResolvedValue(undefined)) {
  render(<AnnualIncomePlanner plan={plan} isRealWorkspace action={null} onSave={onSave} onDelete={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: 'Plan an income change' }))
  return onSave
}
async function click(name: string) {
  await waitFor(() => expect(screen.getByRole('button', { name })).toHaveProperty('disabled', false))
  fireEvent.click(screen.getByRole('button', { name }))
}
async function dateStep(kind = 'New pay amount') {
  fireEvent.click(screen.getByRole('radio', { name: kind }))
  await click('Continue')
  fireEvent.change(screen.getByLabelText('Starting month'), { target: { value: '2026-11' } })
}

it('asks one question at a time, preserves answers on Back, and saves only the reviewed pay amount', async () => {
  const save = open()
  expect(screen.getByRole('heading', { name: 'What changed?' })).toBeTruthy()
  expect(screen.queryByRole('spinbutton')).toBeNull()
  expect(screen.queryByRole('combobox')).toBeNull()
  await dateStep()
  expect(save).not.toHaveBeenCalled()
  expect(screen.queryByRole('spinbutton')).toBeNull()
  await click('Continue')
  fireEvent.change(screen.getByLabelText('Amount', { exact: true }), { target: { value: '3400.25' } })
  fireEvent.change(screen.getByLabelText("How often you're paid"), { target: { value: 'semi_monthly' } })
  expect(document.querySelector<HTMLDetailsElement>('.income-advanced')?.open).toBe(false)
  await click('Back')
  expect(screen.getByLabelText('Starting month')).toHaveProperty('value', '2026-11')
  await click('Continue')
  expect(screen.getByLabelText('Amount', { exact: true })).toHaveProperty('value', '3400.25')
  await click('Schedule income change')
  await waitFor(() => expect(save).toHaveBeenCalledWith({ income_source_id: 8, entry_type: 'recurring_change', amount: '3400.25', cadence: 'semi_monthly', effective_on: '2026-11-01', label: '', retained_after_transition: false }, undefined))
  await waitFor(() => expect(screen.queryByRole('heading', { name: 'How much, and how often?' })).toBeNull())
})

it('turns pay ending into a dated zero-dollar recurring change without asking an amount', async () => {
  const save = open()
  await dateStep('Pay ending')
  await click('Continue')
  expect(screen.queryByRole('spinbutton')).toBeNull()
  expect(screen.getByText('Ana pay will end beginning Nov 2026.')).toBeTruthy()
  expect(save).not.toHaveBeenCalled()
  await click('Schedule income change')
  await waitFor(() => expect(save).toHaveBeenCalledWith(expect.objectContaining({ entry_type: 'recurring_change', amount: '0', effective_on: '2026-11-01', retained_after_transition: false }), undefined))
})

it('counts one-time pay once, allows a label, and never retains job income implicitly', async () => {
  const save = open()
  await dateStep('A one-time payment')
  await click('Continue')
  expect(screen.queryByRole('combobox')).toBeNull()
  fireEvent.change(screen.getByLabelText('Amount', { exact: true }), { target: { value: '500.47' } })
  fireEvent.change(screen.getByLabelText('Label (optional)'), { target: { value: 'Holiday bonus' } })
  expect(screen.getByText('Your regular pay stays the same.')).toBeTruthy()
  await click('Add one-time income')
  await waitFor(() => expect(save).toHaveBeenCalledWith(expect.objectContaining({ entry_type: 'one_time', amount: '500.47', cadence: 'one_time', label: 'Holiday bonus', retained_after_transition: false }), undefined))
})

it.each(['0', '-1', '1.001', '10000000'])('keeps invalid one-time amount %s editable without a save', async amount => {
  const save = open()
  await dateStep('A one-time payment')
  await click('Continue')
  fireEvent.change(screen.getByLabelText('Amount', { exact: true }), { target: { value: amount } })
  await click('Add one-time income')
  expect(save).not.toHaveBeenCalled()
  expect(screen.getByRole('alert')).toBeTruthy()
  // Hidden invalid fields cannot trap the participant on an earlier step.
  await click('Back')
  await click('Continue')
  expect(screen.getByRole('heading', { name: 'How much, and how often?' })).toBeTruthy()
})

it('keeps transition retention behind an explicit disclosure and sends consent only for recurring job pay', async () => {
  const save = open()
  await dateStep()
  await click('Continue')
  fireEvent.change(screen.getByLabelText('Amount', { exact: true }), { target: { value: '3100' } })
  expect(document.querySelector<HTMLDetailsElement>('.income-advanced')?.open).toBe(false)
  fireEvent.click(screen.getByText('More income options'))
  const consent = screen.getByRole('checkbox', { name: /This job income will continue/ })
  expect(consent).toHaveProperty('checked', false)
  fireEvent.click(consent)
  await click('Schedule income change')
  await waitFor(() => expect(save).toHaveBeenCalledWith(expect.objectContaining({ retained_after_transition: true }), undefined))
})

it('retains amount and date after a rejected save so duplicate-date guidance can be corrected', async () => {
  const save = open(vi.fn().mockRejectedValue(new Error('Duplicate date')))
  await dateStep()
  await click('Continue')
  fireEvent.change(screen.getByLabelText('Amount', { exact: true }), { target: { value: '7000' } })
  await click('Schedule income change')
  await waitFor(() => expect(save).toHaveBeenCalledTimes(1))
  expect(screen.getByLabelText('Amount', { exact: true })).toHaveProperty('value', '7000')
  await click('Back')
  expect(screen.getByLabelText('Starting month')).toHaveProperty('value', '2026-11')
})

it('does not let a dirty pay change open or restore a sibling source', async () => {
  const restore = vi.fn()
  const ended = { ...source, id: 9, label: 'Other pay', ends_on: '2100-12-01' }
  function Managers() {
    const [dirty, setDirty] = useState(false)
    return <IncomeForms locked={dirty}><IncomeSourceManager sources={[source, ended]} action={null} error={null} onSave={vi.fn()} onArchive={vi.fn()} onRestore={restore} /><AnnualIncomePlanner plan={plan} isRealWorkspace action={null} onSave={vi.fn()} onDelete={vi.fn()} onUnsavedChangesChange={setDirty} /></IncomeForms>
  }
  render(<Managers />)
  await click('Plan an income change')
  await dateStep('Pay ending')
  expect(screen.getByRole('button', { name: 'Add income source' })).toHaveProperty('disabled', true)
  expect(screen.getByRole('button', { name: 'Restore Other pay' })).toHaveProperty('disabled', true)
  expect(restore).not.toHaveBeenCalled()
  await click('Cancel')
  expect(screen.getByRole('button', { name: 'Add income source' })).toHaveProperty('disabled', false)
})

it('preserves an existing mid-month effective date while moving through the guided editor', async () => {
  const entry: IncomeScheduleEntry = { id: 42, entry_type: 'recurring_change', amount: 6500, cadence: 'monthly', effective_on: '2026-11-15', label: null, retained_after_transition: false }
  const datedPlan = { ...plan, income_sources: [{ ...source, schedule_entries: [entry] }] }
  const save = vi.fn().mockResolvedValue(undefined)
  render(<AnnualIncomePlanner plan={datedPlan} isRealWorkspace action={null} onSave={save} onDelete={vi.fn()} />)
  await click('Edit Ana pay income change from Nov 2026')
  await click('Continue')
  expect(screen.getByLabelText('Starting month')).toHaveProperty('value', '2026-11')
  await click('Continue')
  expect(screen.getByRole('heading', { name: 'How much, and how often?' })).toBeTruthy()
  expect(save).not.toHaveBeenCalled()
  await click('Save income change')
  await waitFor(() => expect(save).toHaveBeenCalledWith(expect.objectContaining({ amount: '6500', effective_on: '2026-11-15' }), 42))
})
