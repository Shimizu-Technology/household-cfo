// @vitest-environment jsdom

import { fireEvent, render, screen, waitFor, cleanup } from '@testing-library/react'
import { afterEach, expect, test, vi } from 'vitest'
import { CfoScenarios, OptionalityScenario, type FilterScenario, type RunwayScenario } from './FinanceScenarios'
const api = vi.hoisted(() => ({ fetchPrivateJson: vi.fn() }))
vi.mock('../api', () => api)
afterEach(() => { cleanup(); vi.resetAllMocks() })
const runway: RunwayScenario = { inputs: { savings_cents: 6000000, monthly_costs_cents: 400000, replacement_income_cents: 100000 }, monthly_gap_cents: 300000, monthly_draw_cents: 300000, months: 20, tone: 'yellow', label: 'Workable — move fast' }
const filter: FilterScenario = { base_surplus_cents: null, after_spend_surplus_cents: null, before: { emergency_months: null, emergency_tone: null, surplus_tone: null }, after: { emergency_months: null, emergency_tone: null, surplus_tone: null }, targets: [], windfall: [], cut_choices: [] }
test('draw prefills from computed gap; edits use read-only scenario GET', async () => {
  api.fetchPrivateJson.mockResolvedValue({ ...runway, months: 25 })
  render(<OptionalityScenario initial={runway} />)
  expect((screen.getByLabelText(/Monthly savings draw/) as HTMLInputElement).value).toBe('3000')
  fireEvent.change(screen.getByLabelText(/Savings available/), { target: { value: '70000' } })
  fireEvent.click(screen.getByRole('button', { name: 'Explore this runway' }))
  await waitFor(() => expect(screen.getByText('25 fully funded months')).toBeTruthy())
  expect(api.fetchPrivateJson).toHaveBeenCalledWith('/api/v1/optionality?scenario=1&savings_cents=7000000&monthly_costs_cents=400000&replacement_income_cents=100000')
})
test('unknowns do not render as zero and invalid input never requests', () => {
  render(<CfoScenarios initial={filter} />)
  expect(screen.getAllByText('Unknown').length).toBeGreaterThan(0)
  fireEvent.change(screen.getByLabelText(/Purchase amount/), { target: { value: '-1' } })
  fireEvent.click(screen.getByRole('button', { name: 'Compare this spend' }))
  expect(screen.getByRole('alert').textContent).toMatch(/Enter an amount/)
  expect(api.fetchPrivateJson).not.toHaveBeenCalled()
})
test('request failure preserves inputs and offers recovery', async () => {
  api.fetchPrivateJson.mockRejectedValue(new Error('offline'))
  render(<CfoScenarios initial={filter} />)
  fireEvent.change(screen.getByLabelText(/Windfall amount/), { target: { value: '123.45' } })
  fireEvent.click(screen.getByRole('button', { name: 'Split this windfall' }))
  await waitFor(() => expect(screen.getByRole('alert').textContent).toMatch(/Try again/))
  expect((screen.getByLabelText(/Windfall amount/) as HTMLInputElement).value).toBe('123.45')
})

test('default draw follows edited costs and income while a deliberate zero override stays zero', async () => {
  api.fetchPrivateJson.mockResolvedValue(runway)
  render(<OptionalityScenario initial={{ ...runway, inputs: { ...runway.inputs, monthly_costs_cents: 439000, replacement_income_cents: 0 }, monthly_gap_cents: 439000, monthly_draw_cents: 439000 }} />)
  const draw = screen.getByLabelText(/Monthly savings draw/) as HTMLInputElement
  expect(draw.value).toBe('4390')
  fireEvent.change(screen.getByLabelText(/Monthly household costs/), { target: { value: '4000' } })
  fireEvent.change(screen.getByLabelText(/Monthly replacement income/), { target: { value: '1000' } })
  expect(draw.value).toBe('3000')
  fireEvent.click(screen.getByRole('button', { name: 'Explore this runway' }))
  await waitFor(() => expect(api.fetchPrivateJson).toHaveBeenCalledWith('/api/v1/optionality?scenario=1&savings_cents=6000000&monthly_costs_cents=400000&replacement_income_cents=100000'))
  await waitFor(() => expect(screen.getByRole('button', { name: 'Explore this runway' }).hasAttribute('disabled')).toBe(false))
  fireEvent.change(draw, { target: { value: '0' } })
  fireEvent.change(screen.getByLabelText(/Monthly household costs/), { target: { value: '5000' } })
  expect(draw.value).toBe('0')
  fireEvent.click(screen.getByRole('button', { name: 'Explore this runway' }))
  await waitFor(() => expect(api.fetchPrivateJson).toHaveBeenLastCalledWith('/api/v1/optionality?scenario=1&savings_cents=6000000&monthly_costs_cents=500000&replacement_income_cents=100000&monthly_draw_cents=0'))
})
