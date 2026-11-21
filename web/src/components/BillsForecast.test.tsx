// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { AnnualBudgetPlan, ForecastMonth, ScheduledBill, YearForecast } from '../api'
import { markBillPaid, removeBill, saveBill } from '../api'
import { BillsForecast } from './BillsForecast'

vi.mock('../api', async (importOriginal) => ({ ...(await importOriginal<typeof import('../api')>()), saveBill: vi.fn(), removeBill: vi.fn(), markBillPaid: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks() })

const bill = (values: Partial<ScheduledBill>): ScheduledBill => ({ id: 1, name: 'Talun power', amount_cents: 8_000, due_on: '2026-11-28', repeat_months: 1, budget_category_id: 1, must_pay: true, estimate: false, paid_on: null, was_this_paid: false, looks_like_debt: null, ...values })
const month = (values: Partial<ForecastMonth> = {}): ForecastMonth => ({ label: 'November', starts_on: '2026-11-01', from_on: null, opening_cents: 100_000, income_cents: 20_000, income_basis: 'planned', approved_so_far_cents: null, outflow_cents: 10_000, spending_plan_known: true, ending_cents: 110_000, bills: [], reasons: [], includes_estimates: false, higher_costs: false, ...values })
const forecast = (values: Partial<YearForecast> = {}): YearForecast => ({ starting_cash_cents: 100_000, starting_on: '2026-11-14', starting_note: 'Starting from your cash balances on November 14.', months: [month()], first_short_month: null, status: 'no_short_month', missing: [], bills: [bill({}), bill({ id: 2, name: 'Talun repair', amount_cents: 69_000, due_on: '2026-09-22', repeat_months: null, budget_category_id: null, was_this_paid: true })], debt_bills: [{ name: 'Talun card', amount_cents: 4_500 }], ...values })
const plan = (values: Partial<YearForecast> = {}) => ({ year: 2026, rows: [{ id: 1, name: 'Utilities', stack_key: 'non_discretionary', active: true }, { id: 3, name: 'Car registration', stack_key: 'sinking_expected', active: true }], year_forecast: forecast(values) }) as unknown as AnnualBudgetPlan

function open() {
  fireEvent.click(screen.getByText('Bills and due dates'))
}

it('asks her to choose a category, says plainly when a bill is outside every plan, and refetches in place', async () => {
  const changed = vi.fn().mockResolvedValue(undefined)
  vi.mocked(saveBill).mockResolvedValue({})
  const listeners = vi.spyOn(window, 'addEventListener')
  render(<BillsForecast plan={plan()} onChanged={changed} />)
  open()
  fireEvent.click(screen.getByRole('button', { name: 'Add bill' }))
  const form = screen.getByRole('form', { name: 'Add a bill' })
  fireEvent.change(within(form).getByLabelText('Bill name'), { target: { value: 'School fee' } })
  fireEvent.change(within(form).getByLabelText('Bill amount'), { target: { value: '200' } })
  fireEvent.change(within(form).getByLabelText('First due date'), { target: { value: '2027-01-05' } })
  expect((within(form).getByLabelText('Category') as HTMLSelectElement).value).toBe('')
  fireEvent.change(within(form).getByLabelText('Category'), { target: { value: 'none' } })
  expect(within(form).getByText(/isn’t part of any category plan, so it adds to your planned costs/)).toBeTruthy()
  fireEvent.change(within(form).getByLabelText('Category'), { target: { value: '3' } })
  expect(within(form).getByText(/the monthly set-aside stays in your savings and the bill counts when it’s due/)).toBeTruthy()
  fireEvent.submit(form)
  await waitFor(() => expect(changed).toHaveBeenCalledOnce())
  expect(saveBill).toHaveBeenCalledWith(null, expect.objectContaining({ name: 'School fee', amount: '200', due_on: '2027-01-05', budget_category_id: 3, repeat_months: null }))
  expect(screen.getByText('Saved School fee.')).toBeTruthy()
  await waitFor(() => expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Add bill' })))
  expect((screen.getByText('Bills and due dates').closest('details') as HTMLDetailsElement).open).toBe(true)
  expect(listeners.mock.calls.some(([type]) => String(type) === 'beforeunload')).toBe(false)
})

it('keeps what she typed when the save is refused, and warns about a debt payment', async () => {
  vi.mocked(saveBill).mockRejectedValue(new Error('Due on can’t be blank'))
  render(<BillsForecast plan={plan()} onChanged={vi.fn()} />)
  open()
  fireEvent.click(screen.getByRole('button', { name: 'Add bill' }))
  const form = screen.getByRole('form', { name: 'Add a bill' })
  fireEvent.change(within(form).getByLabelText('Bill name'), { target: { value: 'Talun card' } })
  expect(within(form).getByText(/looks like your Talun card payment. Debt payments already count from My Money/)).toBeTruthy()
  fireEvent.change(within(form).getByLabelText('Bill name'), { target: { value: 'Rent' } })
  fireEvent.change(within(form).getByLabelText('Bill amount'), { target: { value: '45' } })
  expect(within(form).getByText(/looks like your Talun card payment/)).toBeTruthy()
  fireEvent.submit(form)
  expect(saveBill).not.toHaveBeenCalled()
  expect(within(form).getByRole('alert').textContent).toContain('Choose the category')
  fireEvent.change(within(form).getByLabelText('Category'), { target: { value: '1' } })
  fireEvent.submit(form)
  await waitFor(() => expect(within(form).getByRole('alert').textContent).toBe('Due on can’t be blank'))
  expect((within(form).getByLabelText('Bill name') as HTMLInputElement).value).toBe('Rent')
  expect((within(form).getByLabelText('Bill amount') as HTMLInputElement).value).toBe('45')
  expect((within(form).getByLabelText('Category') as HTMLSelectElement).value).toBe('1')
})

it('confirms a removal beside its bill without switching the open form', async () => {
  vi.mocked(removeBill).mockResolvedValue({})
  const changed = vi.fn().mockResolvedValue(undefined)
  render(<BillsForecast plan={plan()} onChanged={changed} />)
  open()
  fireEvent.click(screen.getByRole('button', { name: 'Edit Talun power' }))
  expect(screen.getByRole('form', { name: 'Edit Talun power' })).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Remove Talun repair' }))
  const confirm = screen.getByRole('group', { name: 'Remove Talun repair?' })
  expect(confirm.closest('li')?.textContent).toContain('Talun repair')
  await waitFor(() => expect(document.activeElement).toBe(within(confirm).getByRole('button', { name: 'Remove bill' })))
  expect(screen.getByRole('form', { name: 'Edit Talun power' })).toBeTruthy()
  fireEvent.click(within(confirm).getByRole('button', { name: 'Remove bill' }))
  await waitFor(() => expect(changed).toHaveBeenCalledOnce())
  expect(removeBill).toHaveBeenCalledWith(2)
})

it('asks whether a past one-time bill was paid and marks it paid only when she says so', async () => {
  vi.mocked(markBillPaid).mockResolvedValue({})
  const changed = vi.fn().mockResolvedValue(undefined)
  render(<BillsForecast plan={plan()} onChanged={changed} />)
  open()
  expect(screen.getByText('Past its date. Was this paid? It still counts until you mark it paid.')).toBeTruthy()
  expect(screen.getByText('Outside your category plan: adds to planned costs')).toBeTruthy()
  expect(markBillPaid).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Yes, Talun repair was paid' }))
  await waitFor(() => expect(changed).toHaveBeenCalledOnce())
  expect(markBillPaid).toHaveBeenCalledWith(2, true)
  expect(screen.getByText('Marked Talun repair paid. It no longer counts.')).toBeTruthy()
  expect(screen.queryByRole('button', { name: /Mark Talun power paid/ })).toBeNull()
})

it('hides every change from someone who can only read', () => {
  render(<BillsForecast plan={plan()} canEdit={false} />)
  open()
  expect(screen.getByText('Talun power: $80')).toBeTruthy()
  expect(screen.queryByRole('button', { name: /Add bill|Edit|Remove|paid/ })).toBeNull()
})

it('labels every month in plain words that also read on a phone', () => {
  const midmonth = month({ from_on: '2026-11-14', income_basis: 'estimated_after_balance', income_cents: 10_322, bills: [bill({ id: 2, name: 'Talun repair', was_this_paid: true })] })
  const december = month({ label: 'December', starts_on: '2026-12-01', income_basis: 'planned', approved_so_far_cents: 5_000, higher_costs: true, ending_cents: -20_000 })
  render(<BillsForecast plan={plan({ months: [midmonth, december], first_short_month: december, status: 'short' })} />)
  expect(screen.getByText('From November 14')).toBeTruthy()
  expect(screen.getByText('Talun repair (was this paid?)')).toBeTruthy()
  expect(screen.getByText('Estimated after November 14; pay dates aren’t saved')).toBeTruthy()
  expect(screen.getByText('Planned · $50 approved so far')).toBeTruthy()
  expect(screen.getByText('Higher costs than usual')).toBeTruthy()
  expect(screen.getByRole('status').textContent).toContain('December may run short: cash would end about $200 below zero.')
  expect(screen.queryByText(/approved actual|liquid/)).toBeNull()
  expect(Array.from(document.querySelectorAll('.forecast-table td')).every(cell => cell.getAttribute('data-label'))).toBe(true)
})
