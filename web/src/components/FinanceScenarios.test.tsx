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
  await waitFor(() => expect(screen.getByText('Savings runway lasts approximately 25 months / 2yr 1mo')).toBeTruthy())
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

test('lift remains independent of spend and stays hidden until requested', async () => {
  render(<CfoScenarios initial={{ ...filter, lifted: filter.before, lift_split: { emergency_fund: 0 } }} />)
  expect(screen.queryByText(/Lift split:/)).toBeNull()
  expect(screen.queryByText(/With this lift:/)).toBeNull()
  api.fetchPrivateJson.mockResolvedValueOnce({ ...filter, lifted: { ...filter.before, emergency_months: 12, emergency_tone: 'green' }, lift_split: { emergency_fund: 50000, debt: 25000, surplus: 25000 } })
  fireEvent.change(screen.getByLabelText(/Monthly income lift/), { target: { value: '1000' } })
  fireEvent.click(screen.getByRole('button', { name: 'Explore this lift' }))
  await waitFor(() => expect(screen.getByText(/Lift split:/).textContent).toContain('$500.00'))
  api.fetchPrivateJson.mockResolvedValueOnce({ ...filter, lifted: filter.before, lift_split: { emergency_fund: 0 } })
  fireEvent.change(screen.getByLabelText(/Purchase amount/), { target: { value: '100' } })
  fireEvent.click(screen.getByRole('button', { name: 'Compare this spend' }))
  await waitFor(() => expect(api.fetchPrivateJson).toHaveBeenCalledTimes(2))
  expect(screen.getByText(/Lift split:/).textContent).toContain('$500.00')
  expect(screen.getByText(/With this lift:/).textContent).toContain('12 months (green)')
})
test('no draw and no savings have plain outcomes without a green runway', () => {
  render(<OptionalityScenario initial={{ ...runway, no_draw: true, months: null, monthly_draw_cents: 0, business_required_annual_cents: 3600000, tone: null }} />)
  expect(screen.getByText('Business must cover $3,000.00/mo from month one')).toBeTruthy()
  expect(screen.queryByText(/after the entered savings draw/)).toBeNull()
})
test('negative baseline and unreachable debt use distinct plain words', () => {
  render(<CfoScenarios initial={{ ...filter, base_surplus_cents: -100, before: { ...filter.before, debt_tone: 'red', debt_timing: 'never' } }} />)
  expect(screen.getByText('The plan already spends more than it brings in.')).toBeTruthy()
  expect(screen.queryByText(/This exceeds/)).toBeNull()
  expect(screen.getByText(/Never pays off at these payments/)).toBeTruthy()
})

test('income lift explains that a shortfall is covered before splitting surplus', () => {
  render(<CfoScenarios initial={filter} />)
  expect(screen.getByText(/income lift first covers any shortfall/).textContent).toContain('remaining positive surplus')
})
test('a known catch-up is named in the spend check and comes before consumer debt in the windfall split', () => {
  render(<CfoScenarios initial={{ ...filter, base_surplus_cents: 40000, after_spend_surplus_cents: 330000, catch_up_cents: 150000,
    windfall: [{ key: 'emergency_fund', cents: 20000, room_known: true }, { key: 'consumer_debt_catch_up', cents: 150000, room_known: true }, { key: 'consumer_debt', cents: 30000, room_known: false }] }} />)
  expect(screen.getByText('That already sets aside $1,500.00 to catch up what you are behind on, before any extra principal.')).toBeTruthy()
  expect(Array.from(screen.getByText('Emergency fund: $200.00').closest('ul')!.children).map(item => item.textContent)).toEqual(['Emergency fund: $200.00', 'Catch up past-due debt: $1,500.00', 'Consumer debt: $300.00 held here until the missing balance is known'])
})
